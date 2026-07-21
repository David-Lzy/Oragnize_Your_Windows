from __future__ import annotations

import json
import os
import re
import sqlite3
import tomllib
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from .core import Config, human_bytes
from .documents import DOCUMENT_SUFFIXES, extract_document, load_document_settings


SCHEMA_VERSION = 1
EXTRACTOR_VERSION = 1
DEFAULT_EXCLUDES = {"$recycle.bin", "system volume information"}
QUERY_STOP_PHRASES = (
    "帮我",
    "找一下",
    "查一下",
    "搜索",
    "上次",
    "之前",
    "那个",
    "这个",
    "文件",
    "东西",
    "在哪里",
    "在哪儿",
    "在哪",
    "路径",
    "please",
    "find",
    "file",
    "where",
)


def _load_index_settings(config: Config) -> tuple[Path, set[str]]:
    with config.config_path.open("rb") as handle:
        raw = tomllib.load(handle)
    settings = raw.get("index_settings", {})
    database = Path(str(settings.get("database", ".state/download-index.sqlite3")))
    if not database.is_absolute():
        database = config.project_dir / database
    excludes = DEFAULT_EXCLUDES | {
        str(item).casefold() for item in settings.get("exclude_directories", [])
    }
    return database.resolve(), excludes


def _connect(database: Path) -> sqlite3.Connection:
    database.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    connection.execute("PRAGMA synchronous = NORMAL")
    connection.execute("PRAGMA busy_timeout = 5000")
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            rel_path TEXT NOT NULL,
            name TEXT NOT NULL,
            stem TEXT NOT NULL,
            extension TEXT NOT NULL,
            parent TEXT NOT NULL,
            zone TEXT NOT NULL,
            category TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            modified_at TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            content_status TEXT NOT NULL DEFAULT 'not_document',
            metadata_json TEXT NOT NULL DEFAULT '{}',
            seen_run_id TEXT NOT NULL,
            indexed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS files_rel_path_idx ON files(rel_path);
        CREATE INDEX IF NOT EXISTS files_name_idx ON files(name);
        CREATE INDEX IF NOT EXISTS files_extension_idx ON files(extension);
        CREATE INDEX IF NOT EXISTS files_category_idx ON files(category);
        CREATE INDEX IF NOT EXISTS files_seen_run_idx ON files(seen_run_id);
        """
    )
    try:
        connection.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS file_search USING fts5("
            "name, rel_path, category, content, tokenize='unicode61')"
        )
        connection.execute(
            "INSERT INTO meta(key, value) VALUES('fts5', 'true') "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        )
    except sqlite3.OperationalError:
        connection.execute(
            "INSERT INTO meta(key, value) VALUES('fts5', 'false') "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        )
    return connection


def _iter_files(root: Path, excludes: set[str]) -> Iterable[Path]:
    def on_error(_: OSError) -> None:
        return None

    for directory, directory_names, file_names in os.walk(root, topdown=True, followlinks=False, onerror=on_error):
        directory_names[:] = [name for name in directory_names if name.casefold() not in excludes]
        base = Path(directory)
        for name in file_names:
            yield base / name


def _filesystem_path(path: Path) -> Path:
    value = str(path)
    if os.name != "nt" or value.startswith("\\\\?\\") or len(value) < 240:
        return path
    if value.startswith("\\\\"):
        return Path("\\\\?\\UNC\\" + value.lstrip("\\"))
    return Path("\\\\?\\" + value)


def _location(root: Path, organized: Path, archive: Path, path: Path) -> tuple[str, str]:
    relative = path.relative_to(root)
    parts = relative.parts
    if path.is_relative_to(organized):
        organized_parts = path.relative_to(organized).parts
        if not organized_parts:
            return "organized", "分类整理"
        if organized_parts[0] == "人工审核":
            depth = min(3, max(1, len(organized_parts) - 1))
            category = "/".join(organized_parts[:depth])
        else:
            depth = min(2, max(1, len(organized_parts) - 1))
            category = "/".join(organized_parts[:depth])
        return "organized", category
    if path.is_relative_to(archive):
        return "archive", "Archive"
    return "root", parts[0] if len(parts) > 1 else "Root"


def _replace_fts(
    connection: sqlite3.Connection,
    file_id: int,
    name: str,
    rel_path: str,
    category: str,
    content: str,
) -> None:
    enabled = connection.execute("SELECT value FROM meta WHERE key='fts5'").fetchone()
    if not enabled or enabled[0] != "true":
        return
    connection.execute("DELETE FROM file_search WHERE rowid = ?", (file_id,))
    connection.execute(
        "INSERT INTO file_search(rowid, name, rel_path, category, content) VALUES(?, ?, ?, ?, ?)",
        (file_id, name, rel_path, category, content),
    )


def build_index(config: Config) -> dict[str, object]:
    database, excludes = _load_index_settings(config)
    settings = load_document_settings(config)
    connection = _connect(database)
    run_id = "index-" + uuid.uuid4().hex
    now = datetime.now(timezone.utc).isoformat()
    previous_extractor = connection.execute(
        "SELECT value FROM meta WHERE key='extractor_version'"
    ).fetchone()
    force_extract = previous_extractor is None or int(previous_extractor[0]) != EXTRACTOR_VERSION
    counts = {
        "scanned": 0,
        "added": 0,
        "updated": 0,
        "unchanged": 0,
        "removed": 0,
        "content_extracted": 0,
        "content_without_text": 0,
        "errors": 0,
    }
    status_counts: dict[str, int] = {}
    error_samples: list[dict[str, str]] = []
    try:
        with connection:
            for path in _iter_files(config.root, excludes):
                try:
                    filesystem_path = _filesystem_path(path)
                    stat = filesystem_path.stat()
                    if not filesystem_path.is_file():
                        continue
                    relative = str(path.relative_to(config.root))
                    zone, category = _location(config.root, config.organized, config.archive, path)
                    existing = connection.execute(
                        "SELECT id, size, mtime_ns, content, content_status, metadata_json "
                        "FROM files WHERE path = ?",
                        (str(path),),
                    ).fetchone()
                    unchanged = (
                        existing is not None
                        and int(existing["size"]) == stat.st_size
                        and int(existing["mtime_ns"]) == stat.st_mtime_ns
                        and not force_extract
                    )
                    if unchanged:
                        content = str(existing["content"])
                        content_status = str(existing["content_status"])
                        metadata_json = str(existing["metadata_json"])
                        counts["unchanged"] += 1
                    elif path.suffix.casefold() in DOCUMENT_SUFFIXES:
                        extraction = extract_document(filesystem_path, settings)
                        content = extraction.text
                        content_status = extraction.status
                        metadata_json = json.dumps(extraction.metadata, ensure_ascii=False)
                        if content:
                            counts["content_extracted"] += 1
                        else:
                            counts["content_without_text"] += 1
                    else:
                        content = ""
                        content_status = "not_document"
                        metadata_json = "{}"
                    modified_at = datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat()
                    values = (
                        relative,
                        path.name,
                        path.stem,
                        path.suffix.casefold(),
                        str(path.parent.relative_to(config.root)),
                        zone,
                        category,
                        stat.st_size,
                        stat.st_mtime_ns,
                        modified_at,
                        content,
                        content_status,
                        metadata_json,
                        run_id,
                        now,
                        str(path),
                    )
                    if existing is None:
                        cursor = connection.execute(
                            """
                            INSERT INTO files(
                                rel_path, name, stem, extension, parent, zone, category,
                                size, mtime_ns, modified_at, content, content_status,
                                metadata_json, seen_run_id, indexed_at, path
                            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            values,
                        )
                        file_id = int(cursor.lastrowid)
                        counts["added"] += 1
                    else:
                        file_id = int(existing["id"])
                        connection.execute(
                            """
                            UPDATE files SET
                                rel_path=?, name=?, stem=?, extension=?, parent=?, zone=?, category=?,
                                size=?, mtime_ns=?, modified_at=?, content=?, content_status=?,
                                metadata_json=?, seen_run_id=?, indexed_at=?
                            WHERE path=?
                            """,
                            values,
                        )
                        if not unchanged:
                            counts["updated"] += 1
                    if existing is None or not unchanged:
                        _replace_fts(connection, file_id, path.name, relative, category, content)
                    counts["scanned"] += 1
                    status_counts[content_status] = status_counts.get(content_status, 0) + 1
                except (OSError, ValueError, sqlite3.Error) as exc:
                    counts["errors"] += 1
                    if len(error_samples) < 20:
                        error_samples.append(
                            {
                                "path": str(path),
                                "error": f"{type(exc).__name__}: {str(exc)[:300]}",
                            }
                        )
            stale_ids = [
                int(row[0])
                for row in connection.execute(
                    "SELECT id FROM files WHERE seen_run_id != ?", (run_id,)
                ).fetchall()
            ]
            if stale_ids:
                fts_enabled = connection.execute("SELECT value FROM meta WHERE key='fts5'").fetchone()
                if fts_enabled and fts_enabled[0] == "true":
                    connection.executemany("DELETE FROM file_search WHERE rowid = ?", ((item,) for item in stale_ids))
                connection.executemany("DELETE FROM files WHERE id = ?", ((item,) for item in stale_ids))
            counts["removed"] = len(stale_ids)
            meta_values = {
                "schema_version": str(SCHEMA_VERSION),
                "extractor_version": str(EXTRACTOR_VERSION),
                "last_run_id": run_id,
                "last_indexed_at": now,
                "root": str(config.root),
            }
            connection.executemany(
                "INSERT INTO meta(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                meta_values.items(),
            )
        database_bytes = database.stat().st_size if database.exists() else 0
        return {
            **counts,
            "database": str(database),
            "database_bytes": database_bytes,
            "database_human": human_bytes(database_bytes),
            "content_status": status_counts,
            "error_samples": error_samples,
            "run_id": run_id,
        }
    finally:
        connection.close()


def _query_terms(query: str) -> list[str]:
    folded = query.casefold().strip()
    cleaned = folded
    for phrase in QUERY_STOP_PHRASES:
        cleaned = cleaned.replace(phrase, " ")
    candidates = [folded]
    candidates.extend(re.findall(r"[\w\u3400-\u9fff.-]+", cleaned, flags=re.UNICODE))
    result: list[str] = []
    for candidate in candidates:
        candidate = candidate.strip(" .-_/")
        if len(candidate) < 2 or candidate in result:
            continue
        result.append(candidate)
    return result[:8]


def _snippet(content: str, terms: list[str], limit: int = 240) -> str:
    if not content:
        return ""
    folded = content.casefold()
    positions = [folded.find(term) for term in terms if folded.find(term) >= 0]
    start = max(0, min(positions) - 70) if positions else 0
    value = re.sub(r"\s+", " ", content[start : start + limit]).strip()
    if start:
        value = "…" + value
    if start + limit < len(content):
        value += "…"
    return value


def search_index(config: Config, query: str, limit: int = 10) -> dict[str, object]:
    database, _ = _load_index_settings(config)
    if not database.exists():
        raise ValueError("Index database does not exist; run the index command first")
    terms = _query_terms(query)
    if not terms:
        raise ValueError("Search query has no usable terms")
    connection = _connect(database)
    try:
        clauses: list[str] = []
        parameters: list[str] = []
        for term in terms:
            clauses.append(
                "(lower(name) LIKE ? OR lower(rel_path) LIKE ? OR lower(category) LIKE ? OR lower(content) LIKE ?)"
            )
            like = f"%{term}%"
            parameters.extend((like, like, like, like))
        rows = connection.execute(
            "SELECT * FROM files WHERE " + " OR ".join(clauses) + " LIMIT 1000",
            parameters,
        ).fetchall()
        ranked: list[tuple[int, int, sqlite3.Row]] = []
        for row in rows:
            name = str(row["name"]).casefold()
            rel_path = str(row["rel_path"]).casefold()
            category = str(row["category"]).casefold()
            content = str(row["content"]).casefold()
            score = 0
            for term in terms:
                if name == term:
                    score += 140
                elif term in name:
                    score += 70
                if term in rel_path:
                    score += 40
                if term in category:
                    score += 25
                if term in content:
                    score += 10
            ranked.append((score, int(row["mtime_ns"]), row))
        ranked.sort(key=lambda item: (item[0], item[1]), reverse=True)
        results = []
        for score, _, row in ranked[: max(1, min(limit, 100))]:
            results.append(
                {
                    "path": str(row["path"]),
                    "relative_path": str(row["rel_path"]),
                    "name": str(row["name"]),
                    "category": str(row["category"]),
                    "zone": str(row["zone"]),
                    "size": int(row["size"]),
                    "size_human": human_bytes(int(row["size"])),
                    "modified_at": str(row["modified_at"]),
                    "content_status": str(row["content_status"]),
                    "score": score,
                    "snippet": _snippet(str(row["content"]), terms),
                }
            )
        return {
            "query": query,
            "terms": terms,
            "database": str(database),
            "matches": len(ranked),
            "results": results,
        }
    finally:
        connection.close()


def index_stats(config: Config) -> dict[str, object]:
    database, _ = _load_index_settings(config)
    if not database.exists():
        raise ValueError("Index database does not exist; run the index command first")
    connection = _connect(database)
    try:
        total = int(connection.execute("SELECT COUNT(*) FROM files").fetchone()[0])
        content = int(connection.execute("SELECT COUNT(*) FROM files WHERE content != ''").fetchone()[0])
        bytes_total = int(connection.execute("SELECT COALESCE(SUM(size), 0) FROM files").fetchone()[0])
        categories = {
            str(row[0]): int(row[1])
            for row in connection.execute(
                "SELECT category, COUNT(*) FROM files GROUP BY category ORDER BY COUNT(*) DESC, category"
            ).fetchall()
        }
        meta = {str(row[0]): str(row[1]) for row in connection.execute("SELECT key, value FROM meta")}
        return {
            "database": str(database),
            "database_bytes": database.stat().st_size,
            "files": total,
            "file_bytes": bytes_total,
            "file_bytes_human": human_bytes(bytes_total),
            "content_indexed_files": content,
            "categories": categories,
            "last_indexed_at": meta.get("last_indexed_at"),
            "fts5": meta.get("fts5") == "true",
        }
    finally:
        connection.close()
