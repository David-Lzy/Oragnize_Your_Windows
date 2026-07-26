#!/usr/bin/env python3
"""Copy one Codex task between Linux CODEX_HOME directories.

This tool deliberately treats Codex's rollout and SQLite layout as an
internal, version-sensitive format. It defaults to a read-only plan and
requires both --apply and --confirm-codex-stopped before writing anything.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import sys
import uuid
from collections.abc import Iterable
from contextlib import closing
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote

DEFAULT_STATE_DATABASE = "state_5.sqlite"
SESSION_INDEX = "session_index.jsonl"
LOCK_FILE = ".linux-session-migration.lock"


class MigrationError(RuntimeError):
    """Raised when a migration precondition or verification fails."""


@dataclass(frozen=True)
class ActiveProcess:
    pid: int
    command: str
    codex_home: str


@dataclass(frozen=True)
class RolloutStats:
    lines: int
    session_meta_records: int
    turn_context_records: int
    rewritten_cwd_records: int
    rewritten_model_provider_records: int
    source_sha256: str
    target_sha256: str
    source_bytes: int
    target_bytes: int


@dataclass
class MigrationPlan:
    source_home: Path
    target_home: Path
    source_database: Path
    target_database: Path
    thread_id: str
    source_row: dict[str, Any]
    source_rollout: Path
    target_rollout: Path
    target_rollout_physical: Path
    backup_root: Path
    destination_cwd: str | None
    destination_model_provider: str | None
    source_index_record: dict[str, Any] | None
    target_row_exists: bool
    target_rollout_exists: bool
    target_home_mode: int
    archive_rename_cross_device: bool | None
    active_processes: list[ActiveProcess]


def absolute_logical_path(value: str | Path) -> Path:
    """Expand a path without resolving symlinks.

    The logical target path is intentional: Codex should see a rollout path
    rooted below the selected CODEX_HOME even when sessions is a symlink.
    """

    return Path(os.path.abspath(os.path.expanduser(os.fspath(value))))


def canonical_path(value: str | Path) -> Path:
    return absolute_logical_path(value).resolve(strict=False)


def path_is_within(path: Path, root: Path) -> bool:
    try:
        canonical_path(path).relative_to(canonical_path(root))
        return True
    except ValueError:
        return False


def nearest_existing_path(path: Path) -> Path:
    candidate = path
    while not candidate.exists():
        if candidate.parent == candidate:
            raise MigrationError(f"no existing ancestor for path: {path}")
        candidate = candidate.parent
    return candidate


def sqlite_read_only_uri(path: Path) -> str:
    return f"file:{quote(str(path), safe='/')}?mode=ro"


def connect_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(sqlite_read_only_uri(path), uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    connection.execute("PRAGMA busy_timeout = 5000")
    return connection


def connect_writable(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout = 5000")
    return connection


def check_database(connection: sqlite3.Connection, label: str) -> None:
    result = connection.execute("PRAGMA quick_check").fetchone()
    if result is None or result[0] != "ok":
        detail = "no result" if result is None else str(result[0])
        raise MigrationError(f"{label} SQLite quick_check failed: {detail}")


def table_columns(connection: sqlite3.Connection, table: str) -> list[dict[str, Any]]:
    rows = connection.execute(
        f"PRAGMA table_info({quote_identifier(table)})"
    ).fetchall()
    if not rows:
        raise MigrationError(f"SQLite table {table!r} is missing")
    return [dict(row) for row in rows]


def quote_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def load_thread_row(database: Path, thread_id: str) -> dict[str, Any]:
    with closing(connect_read_only(database)) as connection:
        check_database(connection, f"source database {database}")
        columns = {row["name"] for row in table_columns(connection, "threads")}
        required = {"id", "rollout_path", "cwd", "archived"}
        missing = sorted(required - columns)
        if missing:
            raise MigrationError(
                "source threads schema is incompatible; missing columns: "
                + ", ".join(missing)
            )
        row = connection.execute(
            "SELECT * FROM threads WHERE id = ?", (thread_id,)
        ).fetchone()
    if row is None:
        raise MigrationError(
            f"thread {thread_id} is not indexed in source database {database}"
        )
    return dict(row)


def target_thread_exists(database: Path, thread_id: str) -> bool:
    with closing(connect_read_only(database)) as connection:
        check_database(connection, f"target database {database}")
        table_columns(connection, "threads")
        return (
            connection.execute(
                "SELECT 1 FROM threads WHERE id = ?", (thread_id,)
            ).fetchone()
            is not None
        )


def read_index(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []

    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise MigrationError(
                    f"invalid JSON in {path} at line {line_number}: {exc}"
                ) from exc
            if not isinstance(value, dict):
                raise MigrationError(
                    f"invalid non-object record in {path} at line {line_number}"
                )
            records.append(value)
    return records


def source_index_record(home: Path, thread_id: str) -> dict[str, Any] | None:
    matches = [
        record
        for record in read_index(home / SESSION_INDEX)
        if record.get("id") == thread_id
    ]
    return dict(matches[-1]) if matches else None


def locate_rollout(home: Path, row: dict[str, Any], thread_id: str) -> Path:
    recorded_value = Path(os.path.expanduser(str(row["rollout_path"])))
    recorded = (
        absolute_logical_path(recorded_value)
        if recorded_value.is_absolute()
        else absolute_logical_path(home / recorded_value)
    )
    if recorded.is_file():
        return recorded

    candidates: list[Path] = []
    pattern = f"*{thread_id}*.jsonl"
    for root_name in ("sessions", "archived_sessions"):
        root = home / root_name
        if root.is_dir():
            candidates.extend(path for path in root.rglob(pattern) if path.is_file())

    unique = sorted({canonical_path(path) for path in candidates})
    if len(unique) == 1:
        return candidates[0]
    if not unique:
        raise MigrationError(
            "the source rollout_path does not exist and no matching rollout was "
            f"found below {home}/sessions or {home}/archived_sessions"
        )
    raise MigrationError(
        f"more than one source rollout matches {thread_id}; repair the source index first"
    )


def rollout_date_from_filename(filename: str, thread_id: str) -> tuple[str, str, str]:
    expression = re.compile(
        rf"^rollout-(\d{{4}})-(\d{{2}})-(\d{{2}})T.+-{re.escape(thread_id)}\.jsonl$"
    )
    match = expression.fullmatch(filename)
    if not match:
        raise MigrationError(
            "unexpected rollout filename; the internal Codex layout may have changed: "
            f"{filename}"
        )
    return match.group(1), match.group(2), match.group(3)


def target_rollout_path(
    target_home: Path,
    source_rollout: Path,
    thread_id: str,
    archived: bool,
) -> Path:
    year, month, day = rollout_date_from_filename(source_rollout.name, thread_id)
    if archived:
        return target_home / "archived_sessions" / source_rollout.name
    return target_home / "sessions" / year / month / day / source_rollout.name


def reject_nested_symlinks(root: Path, target_parent: Path) -> None:
    if root.is_symlink() and not root.exists():
        raise MigrationError(f"storage root is a broken symlink: {root}")
    if root.exists() and not root.is_dir():
        raise MigrationError(f"storage root is not a directory: {root}")
    try:
        relative = target_parent.relative_to(root)
    except ValueError as exc:
        raise MigrationError(
            f"target rollout parent escapes its storage root: {target_parent}"
        ) from exc

    current = root
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            raise MigrationError(
                "only the sessions/archived_sessions root may be a symlink; "
                f"nested symlink found: {current}"
            )


def read_first_session_meta(path: Path, thread_id: str) -> dict[str, Any]:
    with path.open("rb") as handle:
        first_line = handle.readline()
    if not first_line:
        raise MigrationError(f"rollout is empty: {path}")
    try:
        record = json.loads(first_line)
    except json.JSONDecodeError as exc:
        raise MigrationError(f"first rollout record is invalid JSON: {exc}") from exc
    if (
        not isinstance(record, dict)
        or record.get("type") != "session_meta"
        or not isinstance(record.get("payload"), dict)
    ):
        raise MigrationError("first rollout record is not a session_meta object")
    if record["payload"].get("id") != thread_id:
        raise MigrationError(
            "rollout session_meta ID does not match the requested thread ID"
        )
    return record


def process_codex_home(environ: bytes) -> Path:
    values: dict[bytes, bytes] = {}
    for item in environ.split(b"\0"):
        if b"=" in item:
            key, value = item.split(b"=", 1)
            values[key] = value
    raw = values.get(b"CODEX_HOME")
    if raw:
        return canonical_path(os.fsdecode(raw))
    process_home = values.get(b"HOME")
    if process_home:
        return canonical_path(Path(os.fsdecode(process_home)) / ".codex")
    return canonical_path(Path.home() / ".codex")


def active_codex_processes(homes: Iterable[Path]) -> list[ActiveProcess]:
    proc = Path("/proc")
    if not proc.is_dir():
        return []

    wanted = {canonical_path(path) for path in homes}
    current_pid = os.getpid()
    current_uid = os.getuid()
    matches: list[ActiveProcess] = []

    for entry in proc.iterdir():
        if not entry.name.isdigit() or int(entry.name) == current_pid:
            continue
        try:
            if entry.stat().st_uid != current_uid:
                continue
            comm = (
                (entry / "comm").read_text(encoding="utf-8", errors="replace").strip()
            )
            raw_cmdline = (entry / "cmdline").read_bytes()
            cmdline = os.fsdecode(raw_cmdline.replace(b"\0", b" ")).strip()
            lower_comm = comm.lower()
            lower_command = cmdline.lower()
            looks_like_codex = "codex" in lower_comm or (
                "app-server" in lower_command and "codex" in lower_command
            )
            if not looks_like_codex:
                continue
            environ = (entry / "environ").read_bytes()
            home = process_codex_home(environ)
        except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
            continue

        if home in wanted:
            matches.append(
                ActiveProcess(
                    pid=int(entry.name),
                    command=comm,
                    codex_home=str(home),
                )
            )

    return sorted(matches, key=lambda process: process.pid)


def build_plan(args: argparse.Namespace) -> MigrationPlan:
    source_home = absolute_logical_path(args.source_home)
    target_home = absolute_logical_path(args.target_home)
    if not source_home.is_dir():
        raise MigrationError(f"source CODEX_HOME does not exist: {source_home}")
    if not target_home.is_dir():
        raise MigrationError(f"target CODEX_HOME must already exist: {target_home}")
    if canonical_path(source_home) == canonical_path(target_home):
        raise MigrationError(
            "source and target CODEX_HOME resolve to the same directory"
        )

    source_database = absolute_logical_path(
        args.source_database or source_home / DEFAULT_STATE_DATABASE
    )
    target_database = absolute_logical_path(
        args.target_database or target_home / DEFAULT_STATE_DATABASE
    )
    if not source_database.is_file():
        raise MigrationError(f"source SQLite database is missing: {source_database}")
    if not target_database.is_file():
        raise MigrationError(f"target SQLite database is missing: {target_database}")

    if args.backup_root:
        backup_value = Path(os.path.expanduser(args.backup_root))
        if not backup_value.is_absolute():
            raise MigrationError("backup root must be an absolute path")
        backup_root = absolute_logical_path(backup_value)
    else:
        backup_root = target_home / "migration-backups"
    for storage_name in ("sessions", "archived_sessions"):
        storage_root = target_home / storage_name
        if path_is_within(backup_root, storage_root):
            raise MigrationError(
                "backup root must be outside sessions and archived_sessions: "
                f"{backup_root}"
            )

    thread_id = str(uuid.UUID(args.thread_id))
    if thread_id.lower() != args.thread_id.lower():
        raise MigrationError("thread ID must use canonical UUID spelling")

    destination_cwd: str | None = None
    if args.destination_cwd:
        destination_value = Path(os.path.expanduser(args.destination_cwd))
        if not destination_value.is_absolute():
            raise MigrationError("destination cwd must be an absolute path")
        destination_path = absolute_logical_path(destination_value)
        destination_cwd = str(destination_path)

    destination_model_provider: str | None = None
    if args.destination_model_provider is not None:
        destination_model_provider = args.destination_model_provider.strip()
        if not destination_model_provider:
            raise MigrationError("destination model provider must not be empty")
        if any(character in destination_model_provider for character in "\0\r\n"):
            raise MigrationError(
                "destination model provider must not contain control characters"
            )

    row = load_thread_row(source_database, thread_id)
    rollout = locate_rollout(source_home, row, thread_id)
    if rollout.is_symlink():
        raise MigrationError("the rollout file itself must not be a symlink")
    read_first_session_meta(rollout, thread_id)

    target_rollout = target_rollout_path(
        target_home,
        rollout,
        thread_id,
        archived=bool(int(row["archived"])),
    )
    target_storage_root = (
        target_home / "archived_sessions"
        if bool(int(row["archived"]))
        else target_home / "sessions"
    )
    reject_nested_symlinks(target_storage_root, target_rollout.parent)
    if target_rollout.exists() and os.path.samefile(rollout, target_rollout):
        raise MigrationError(
            "source and target rollout are the same physical file; isolated "
            "CODEX_HOME directories must not share this task's sessions path"
        )
    physical_parent = target_rollout.parent.resolve(strict=False)
    target_physical = physical_parent / target_rollout.name

    target_mode = stat.S_IMODE(target_home.stat().st_mode)
    sessions_root = target_home / "sessions"
    archived_root = target_home / "archived_sessions"
    archive_rename_cross_device: bool | None = None
    if sessions_root.exists() and archived_root.exists():
        archive_rename_cross_device = (
            sessions_root.stat().st_dev != archived_root.stat().st_dev
        )
    return MigrationPlan(
        source_home=source_home,
        target_home=target_home,
        source_database=source_database,
        target_database=target_database,
        thread_id=thread_id,
        source_row=row,
        source_rollout=rollout,
        target_rollout=target_rollout,
        target_rollout_physical=target_physical,
        backup_root=backup_root,
        destination_cwd=destination_cwd,
        destination_model_provider=destination_model_provider,
        source_index_record=source_index_record(source_home, thread_id),
        target_row_exists=target_thread_exists(target_database, thread_id),
        target_rollout_exists=target_rollout.exists(),
        target_home_mode=target_mode,
        archive_rename_cross_device=archive_rename_cross_device,
        active_processes=active_codex_processes((source_home, target_home)),
    )


def print_plan(plan: MigrationPlan, replace_existing: bool) -> None:
    source_size = plan.source_rollout.stat().st_size
    print("Codex Linux task migration plan")
    print(f"  thread ID:              {plan.thread_id}")
    print(f"  source CODEX_HOME:      {plan.source_home}")
    print(f"  target CODEX_HOME:      {plan.target_home}")
    print(f"  source SQLite:          {plan.source_database}")
    print(f"  target SQLite:          {plan.target_database}")
    print(f"  source rollout:         {plan.source_rollout}")
    print(f"  source rollout bytes:   {source_size}")
    print(f"  target logical rollout: {plan.target_rollout}")
    print(f"  target physical rollout: {plan.target_rollout_physical}")
    print(f"  backup root:            {plan.backup_root}")
    print(
        "  destination cwd:        "
        + (plan.destination_cwd or f"(preserve {plan.source_row['cwd']})")
    )
    print(
        "  destination provider:   "
        + (
            plan.destination_model_provider
            or f"(preserve {plan.source_row.get('model_provider')})"
        )
    )
    print(f"  target row exists:      {plan.target_row_exists}")
    print(f"  target file exists:     {plan.target_rollout_exists}")
    print(f"  replace existing:       {replace_existing}")
    print(f"  target home mode:       {plan.target_home_mode:04o}")
    if plan.archive_rename_cross_device is None:
        print("  archive rename device:  not checked (one root is missing)")
    elif plan.archive_rename_cross_device:
        print("  archive rename device:  DIFFERENT FILESYSTEMS")
    else:
        print("  archive rename device:  same filesystem")
    if plan.active_processes:
        print("  active Codex processes:")
        for process in plan.active_processes:
            print(
                f"    PID {process.pid} CODEX_HOME={process.codex_home} "
                f"command={process.command}"
            )
    else:
        print("  active Codex processes: none detected for either CODEX_HOME")
    print("  estimated free-space requirements:")
    for estimate in space_estimates(plan, replace_existing):
        print(
            f"    device {estimate['device']}: "
            f"need~{estimate['required_bytes']} bytes; "
            f"free={estimate['free_bytes']} bytes; "
            f"via {estimate['probe_path']}"
        )


def utc_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def space_estimates(
    plan: MigrationPlan, replace_existing: bool
) -> list[dict[str, Any]]:
    requirements: dict[int, dict[str, Any]] = {}

    def add(path: Path, required_bytes: int) -> None:
        probe = nearest_existing_path(path)
        device = probe.stat().st_dev
        entry = requirements.setdefault(
            device,
            {
                "device": device,
                "probe_path": str(probe),
                "required_bytes": 0,
                "free_bytes": shutil.disk_usage(probe).free,
            },
        )
        entry["required_bytes"] += max(0, required_bytes)

    add(plan.target_rollout.parent, plan.source_rollout.stat().st_size)
    backup_bytes = plan.target_database.stat().st_size
    target_index = plan.target_home / SESSION_INDEX
    if target_index.exists():
        backup_bytes += target_index.stat().st_size
    if replace_existing and plan.target_rollout.exists():
        backup_bytes += plan.target_rollout.stat().st_size
    add(plan.backup_root, backup_bytes)

    for entry in requirements.values():
        payload = int(entry["required_bytes"])
        entry["required_bytes"] = payload + max(16 * 1024 * 1024, payload // 50)
    return sorted(requirements.values(), key=lambda entry: int(entry["device"]))


def verify_free_space(plan: MigrationPlan, replace_existing: bool) -> None:
    failures = [
        estimate
        for estimate in space_estimates(plan, replace_existing)
        if int(estimate["free_bytes"]) < int(estimate["required_bytes"])
    ]
    if failures:
        details = "; ".join(
            "device {device} needs about {required_bytes} bytes but has "
            "{free_bytes} bytes free via {probe_path}".format(**estimate)
            for estimate in failures
        )
        raise MigrationError(f"insufficient free space: {details}")


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_json_atomic(path: Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), mode)
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def backup_database(source: Path, destination: Path) -> None:
    with closing(connect_read_only(source)) as source_connection:
        check_database(source_connection, f"database {source}")
        with closing(sqlite3.connect(destination)) as destination_connection:
            source_connection.backup(destination_connection)
            destination_connection.commit()
    os.chmod(destination, 0o600)


def restore_database(backup: Path, destination: Path) -> None:
    with closing(connect_read_only(backup)) as source_connection:
        check_database(source_connection, f"backup database {backup}")
        with closing(connect_writable(destination)) as destination_connection:
            source_connection.backup(destination_connection)
            destination_connection.commit()


def copy_and_validate_rollout(
    source: Path,
    temporary_target: Path,
    thread_id: str,
    destination_cwd: str | None,
    destination_model_provider: str | None,
) -> RolloutStats:
    source_hash = hashlib.sha256()
    target_hash = hashlib.sha256()
    lines = 0
    meta_records = 0
    context_records = 0
    rewritten_cwd = 0
    rewritten_model_provider = 0
    source_bytes = 0
    target_bytes = 0

    with source.open("rb") as reader, temporary_target.open("xb") as writer:
        os.fchmod(writer.fileno(), 0o600)
        for line_number, raw_line in enumerate(reader, start=1):
            lines += 1
            source_bytes += len(raw_line)
            source_hash.update(raw_line)
            if not raw_line.strip():
                raise MigrationError(
                    f"blank JSONL record in source rollout at line {line_number}"
                )
            try:
                record = json.loads(raw_line)
            except json.JSONDecodeError as exc:
                raise MigrationError(
                    f"invalid rollout JSON at line {line_number}: {exc}"
                ) from exc
            if not isinstance(record, dict):
                raise MigrationError(f"non-object rollout record at line {line_number}")

            record_type = record.get("type")
            payload = record.get("payload")
            output_line = raw_line
            record_changed = False
            if record_type == "session_meta":
                meta_records += 1
                if not isinstance(payload, dict) or payload.get("id") != thread_id:
                    raise MigrationError(
                        f"session_meta mismatch at rollout line {line_number}"
                    )
            elif record_type == "turn_context":
                context_records += 1

            if (
                destination_cwd is not None
                and record_type in {"session_meta", "turn_context"}
                and isinstance(payload, dict)
                and payload.get("cwd") != destination_cwd
            ):
                payload["cwd"] = destination_cwd
                rewritten_cwd += 1
                record_changed = True

            if (
                destination_model_provider is not None
                and record_type == "session_meta"
                and isinstance(payload, dict)
                and payload.get("model_provider") != destination_model_provider
            ):
                payload["model_provider"] = destination_model_provider
                rewritten_model_provider += 1
                record_changed = True

            if record_changed:
                had_newline = raw_line.endswith(b"\n")
                output_line = json.dumps(
                    record,
                    ensure_ascii=False,
                    separators=(",", ":"),
                ).encode("utf-8")
                if had_newline:
                    output_line += b"\n"

            writer.write(output_line)
            target_hash.update(output_line)
            target_bytes += len(output_line)

        writer.flush()
        os.fsync(writer.fileno())

    if lines == 0 or meta_records == 0:
        raise MigrationError(
            f"expected at least one session_meta record; found {meta_records}"
        )
    if (
        rewritten_cwd == 0
        and rewritten_model_provider == 0
        and source_hash.digest() != target_hash.digest()
    ):
        raise MigrationError("unchanged rollout copy failed SHA-256 verification")

    return RolloutStats(
        lines=lines,
        session_meta_records=meta_records,
        turn_context_records=context_records,
        rewritten_cwd_records=rewritten_cwd,
        rewritten_model_provider_records=rewritten_model_provider,
        source_sha256=source_hash.hexdigest(),
        target_sha256=target_hash.hexdigest(),
        source_bytes=source_bytes,
        target_bytes=target_bytes,
    )


def copy_thread_row(
    source_database: Path,
    target_database: Path,
    thread_id: str,
    target_rollout: Path,
    destination_cwd: str | None,
    destination_model_provider: str | None,
    replace_existing: bool,
) -> list[str]:
    with closing(connect_read_only(source_database)) as source_connection:
        table_columns(source_connection, "threads")
        source_row_value = source_connection.execute(
            "SELECT * FROM threads WHERE id = ?", (thread_id,)
        ).fetchone()
        if source_row_value is None:
            raise MigrationError("source thread row disappeared during migration")
        source_row = dict(source_row_value)

    with closing(connect_writable(target_database)) as target_connection:
        check_database(target_connection, f"target database {target_database}")
        target_columns = table_columns(target_connection, "threads")
        target_names = [str(column["name"]) for column in target_columns]
        shared_names = [name for name in target_names if name in source_row]
        missing_core = sorted({"id", "rollout_path", "cwd"} - set(shared_names))
        if missing_core:
            raise MigrationError(
                "target threads schema is incompatible; missing shared columns: "
                + ", ".join(missing_core)
            )

        missing_required = [
            str(column["name"])
            for column in target_columns
            if column["name"] not in source_row
            and int(column["notnull"])
            and column["dflt_value"] is None
            and not int(column["pk"])
        ]
        if missing_required:
            raise MigrationError(
                "target threads schema has required columns absent from the source: "
                + ", ".join(missing_required)
            )

        copied = {name: source_row[name] for name in shared_names}
        copied["rollout_path"] = str(target_rollout)
        if destination_cwd is not None:
            copied["cwd"] = destination_cwd
        if destination_model_provider is not None:
            if "model_provider" not in shared_names:
                raise MigrationError(
                    "cannot set destination model provider because model_provider "
                    "is not shared by the source and target threads schemas"
                )
            copied["model_provider"] = destination_model_provider

        existing = target_connection.execute(
            "SELECT 1 FROM threads WHERE id = ?", (thread_id,)
        ).fetchone()
        if existing is not None and not replace_existing:
            raise MigrationError(
                "target database already contains this thread; use "
                "--replace-existing only after inspecting the conflict"
            )

        columns_sql = ", ".join(quote_identifier(name) for name in shared_names)
        placeholders = ", ".join("?" for _ in shared_names)
        values = [copied[name] for name in shared_names]
        if existing is None:
            statement = f"INSERT INTO threads ({columns_sql}) VALUES ({placeholders})"
        else:
            assignments = ", ".join(
                f"{quote_identifier(name)} = excluded.{quote_identifier(name)}"
                for name in shared_names
                if name != "id"
            )
            statement = (
                f"INSERT INTO threads ({columns_sql}) VALUES ({placeholders}) "
                f"ON CONFLICT(id) DO UPDATE SET {assignments}"
            )

        try:
            target_connection.execute("BEGIN IMMEDIATE")
            target_connection.execute(statement, values)
            target_connection.commit()
        except Exception:
            target_connection.rollback()
            raise

        check_database(target_connection, f"updated target database {target_database}")
        verification_names = ["rollout_path", "cwd"]
        if destination_model_provider is not None:
            verification_names.append("model_provider")
        verification = target_connection.execute(
            "SELECT "
            + ", ".join(quote_identifier(name) for name in verification_names)
            + " FROM threads WHERE id = ?",
            (thread_id,),
        ).fetchone()
        if verification is None:
            raise MigrationError("target thread row is missing after SQLite commit")
        if verification["rollout_path"] != str(target_rollout):
            raise MigrationError(
                "target SQLite rollout_path did not retain the logical CODEX_HOME path"
            )
        if destination_cwd is not None and verification["cwd"] != destination_cwd:
            raise MigrationError("target SQLite cwd verification failed")
        if (
            destination_model_provider is not None
            and verification["model_provider"] != destination_model_provider
        ):
            raise MigrationError("target SQLite model_provider verification failed")

    return sorted(set(source_row) - set(shared_names))


def fallback_index_record(source_row: dict[str, Any], thread_id: str) -> dict[str, Any]:
    updated_at = int(source_row.get("updated_at", 0))
    timestamp = dt.datetime.fromtimestamp(updated_at, tz=dt.timezone.utc)
    return {
        "id": thread_id,
        "thread_name": str(source_row.get("title") or thread_id),
        "updated_at": timestamp.isoformat().replace("+00:00", "Z"),
    }


def update_target_index(
    path: Path,
    thread_id: str,
    source_record: dict[str, Any] | None,
    source_row: dict[str, Any],
) -> None:
    replacement = dict(source_record or fallback_index_record(source_row, thread_id))
    replacement["id"] = thread_id

    records = read_index(path)
    updated: list[dict[str, Any]] = []
    replaced = False
    for record in records:
        if record.get("id") == thread_id:
            if not replaced:
                updated.append(replacement)
                replaced = True
            continue
        updated.append(record)
    if not replaced:
        updated.append(replacement)

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    original_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), original_mode)
            for record in updated:
                handle.write(
                    json.dumps(record, ensure_ascii=False, separators=(",", ":"))
                )
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def verify_target(plan: MigrationPlan) -> None:
    if not plan.target_rollout.is_file():
        raise MigrationError("target rollout is missing after migration")
    first_meta = read_first_session_meta(plan.target_rollout, plan.thread_id)
    if (
        plan.destination_model_provider is not None
        and first_meta["payload"].get("model_provider")
        != plan.destination_model_provider
    ):
        raise MigrationError(
            "target rollout model_provider does not match destination provider"
        )

    with closing(connect_read_only(plan.target_database)) as connection:
        check_database(connection, f"target database {plan.target_database}")
        verification_names = ["rollout_path", "cwd"]
        if plan.destination_model_provider is not None:
            verification_names.append("model_provider")
        row = connection.execute(
            "SELECT "
            + ", ".join(quote_identifier(name) for name in verification_names)
            + " FROM threads WHERE id = ?",
            (plan.thread_id,),
        ).fetchone()
        if row is None:
            raise MigrationError("target SQLite thread row is missing")
        if row["rollout_path"] != str(plan.target_rollout):
            raise MigrationError(
                "target SQLite rollout_path is not the logical CODEX_HOME path"
            )
        if plan.destination_cwd is not None and row["cwd"] != plan.destination_cwd:
            raise MigrationError("target SQLite cwd does not match destination cwd")
        if (
            plan.destination_model_provider is not None
            and row["model_provider"] != plan.destination_model_provider
        ):
            raise MigrationError(
                "target SQLite model_provider does not match destination provider"
            )

    index_matches = [
        record
        for record in read_index(plan.target_home / SESSION_INDEX)
        if record.get("id") == plan.thread_id
    ]
    if len(index_matches) != 1:
        raise MigrationError(
            f"target session index contains {len(index_matches)} matching records"
        )


def acquire_lock(target_home: Path):
    lock_path = target_home / LOCK_FILE
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(descriptor)
        raise MigrationError(
            f"another migration holds the target lock: {lock_path}"
        ) from exc
    return descriptor


def apply_plan(
    plan: MigrationPlan,
    *,
    confirm_stopped: bool,
    replace_existing: bool,
) -> Path:
    if not confirm_stopped:
        raise MigrationError("--apply also requires --confirm-codex-stopped")
    current_processes = active_codex_processes((plan.source_home, plan.target_home))
    if current_processes:
        pids = ", ".join(str(process.pid) for process in current_processes)
        raise MigrationError(
            "Codex is still running for the source or target CODEX_HOME "
            f"(PID(s): {pids}); stop it and build the plan again"
        )
    current_target_row = target_thread_exists(plan.target_database, plan.thread_id)
    current_target_rollout = plan.target_rollout.exists()
    if (current_target_row or current_target_rollout) and not replace_existing:
        raise MigrationError(
            "the target already contains this thread or rollout; rerun the dry plan, "
            "inspect both copies, then use --replace-existing only if intentional"
        )
    if plan.target_rollout.exists() and plan.target_rollout.is_symlink():
        raise MigrationError("refusing to replace a symlinked target rollout")
    target_index = plan.target_home / SESSION_INDEX
    if target_index.is_symlink():
        raise MigrationError("refusing to replace a symlinked target session index")
    verify_free_space(plan, replace_existing)

    lock_descriptor = acquire_lock(plan.target_home)
    timestamp = utc_stamp()
    backup_dir = plan.backup_root / f"{timestamp}-{plan.thread_id}"
    database_backup = backup_dir / plan.target_database.name
    index_backup = backup_dir / SESSION_INDEX
    rollout_backup = backup_dir / plan.target_rollout.name
    manifest_path = backup_dir / "migration-manifest.json"

    target_had_index = target_index.exists()
    target_had_rollout = plan.target_rollout.exists()
    installed_rollout = False
    database_may_have_changed = False
    index_may_have_changed = False
    temporary_rollout: Path | None = None

    try:
        backup_dir.mkdir(parents=True, mode=0o700)
        os.chmod(backup_dir, 0o700)
        backup_database(plan.target_database, database_backup)
        if target_had_index:
            shutil.copy2(target_index, index_backup)
            os.chmod(index_backup, 0o600)
        if target_had_rollout:
            shutil.copy2(plan.target_rollout, rollout_backup)
            os.chmod(rollout_backup, 0o600)

        write_json_atomic(
            manifest_path,
            {
                "schema_version": 1,
                "status": "staging",
                "created_at": timestamp,
                "thread_id": plan.thread_id,
                "source_home": str(plan.source_home),
                "target_home": str(plan.target_home),
                "source_database": str(plan.source_database),
                "target_database": str(plan.target_database),
                "source_rollout": str(plan.source_rollout),
                "target_rollout_logical": str(plan.target_rollout),
                "target_rollout_physical": str(plan.target_rollout_physical),
                "backup_root": str(plan.backup_root),
                "destination_cwd": plan.destination_cwd,
                "destination_model_provider": plan.destination_model_provider,
                "archive_rename_cross_device": plan.archive_rename_cross_device,
                "source_retained": True,
            },
        )

        plan.target_rollout.parent.mkdir(parents=True, exist_ok=True)
        temporary_rollout = plan.target_rollout.with_name(
            f".{plan.target_rollout.name}.migrating-{os.getpid()}"
        )
        stats = copy_and_validate_rollout(
            plan.source_rollout,
            temporary_rollout,
            plan.thread_id,
            plan.destination_cwd,
            plan.destination_model_provider,
        )
        os.replace(temporary_rollout, plan.target_rollout)
        installed_rollout = True
        fsync_directory(plan.target_rollout.parent)

        database_may_have_changed = True
        dropped_columns = copy_thread_row(
            plan.source_database,
            plan.target_database,
            plan.thread_id,
            plan.target_rollout,
            plan.destination_cwd,
            plan.destination_model_provider,
            replace_existing,
        )

        index_may_have_changed = True
        update_target_index(
            target_index,
            plan.thread_id,
            plan.source_index_record,
            plan.source_row,
        )
        verify_target(plan)

        write_json_atomic(
            manifest_path,
            {
                "schema_version": 1,
                "status": "success",
                "created_at": timestamp,
                "completed_at": utc_stamp(),
                "thread_id": plan.thread_id,
                "source_home": str(plan.source_home),
                "target_home": str(plan.target_home),
                "source_database": str(plan.source_database),
                "target_database": str(plan.target_database),
                "source_rollout": str(plan.source_rollout),
                "target_rollout_logical": str(plan.target_rollout),
                "target_rollout_physical": str(plan.target_rollout_physical),
                "backup_root": str(plan.backup_root),
                "destination_cwd": plan.destination_cwd,
                "destination_model_provider": plan.destination_model_provider,
                "archive_rename_cross_device": plan.archive_rename_cross_device,
                "source_retained": True,
                "target_database_backup": str(database_backup),
                "target_index_backup": str(index_backup) if target_had_index else None,
                "replaced_rollout_backup": (
                    str(rollout_backup) if target_had_rollout else None
                ),
                "source_only_sqlite_columns": dropped_columns,
                "rollout": asdict(stats),
            },
        )
        return manifest_path
    except Exception as exc:
        rollback_errors: list[str] = []
        if temporary_rollout is not None and temporary_rollout.exists():
            try:
                temporary_rollout.unlink()
            except OSError as rollback_exc:
                rollback_errors.append(f"remove temporary rollout: {rollback_exc}")

        if database_may_have_changed and database_backup.exists():
            try:
                restore_database(database_backup, plan.target_database)
            except Exception as rollback_exc:  # noqa: BLE001
                rollback_errors.append(f"restore SQLite: {rollback_exc}")

        if index_may_have_changed:
            try:
                if target_had_index and index_backup.exists():
                    shutil.copy2(index_backup, target_index)
                elif target_index.exists():
                    target_index.unlink()
            except OSError as rollback_exc:
                rollback_errors.append(f"restore session index: {rollback_exc}")

        if installed_rollout:
            try:
                if target_had_rollout and rollout_backup.exists():
                    shutil.copy2(rollout_backup, plan.target_rollout)
                elif plan.target_rollout.exists():
                    plan.target_rollout.unlink()
            except OSError as rollback_exc:
                rollback_errors.append(f"restore rollout: {rollback_exc}")

        if backup_dir.exists():
            try:
                write_json_atomic(
                    manifest_path,
                    {
                        "schema_version": 1,
                        "status": (
                            "failed_rolled_back"
                            if not rollback_errors
                            else "failed_rollback_incomplete"
                        ),
                        "created_at": timestamp,
                        "failed_at": utc_stamp(),
                        "thread_id": plan.thread_id,
                        "error": str(exc),
                        "rollback_errors": rollback_errors,
                    },
                )
            except Exception as manifest_exc:  # noqa: BLE001
                rollback_errors.append(f"write failure manifest: {manifest_exc}")

        detail = str(exc)
        if rollback_errors:
            detail += "; rollback issues: " + "; ".join(rollback_errors)
        raise MigrationError(detail) from exc
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Safely copy one Codex task between Linux CODEX_HOME directories. "
            "Without --apply, only a read-only plan is printed."
        )
    )
    parser.add_argument("--source-home", required=True, help="source CODEX_HOME")
    parser.add_argument("--target-home", required=True, help="target CODEX_HOME")
    parser.add_argument("--thread-id", required=True, help="Codex task UUID")
    parser.add_argument(
        "--source-database",
        help=f"source SQLite path (default: SOURCE_HOME/{DEFAULT_STATE_DATABASE})",
    )
    parser.add_argument(
        "--target-database",
        help=f"target SQLite path (default: TARGET_HOME/{DEFAULT_STATE_DATABASE})",
    )
    parser.add_argument(
        "--destination-cwd",
        help=(
            "new absolute project path; updates SQLite cwd plus structural "
            "session_meta/turn_context cwd fields"
        ),
    )
    parser.add_argument(
        "--destination-model-provider",
        help=(
            "exact target provider name; updates SQLite model_provider plus every "
            "structural session_meta model_provider field"
        ),
    )
    parser.add_argument(
        "--backup-root",
        help=(
            "absolute directory for SQLite/index/conflict backups "
            "(default: TARGET_HOME/migration-backups)"
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform the migration after validation and backup",
    )
    parser.add_argument(
        "--confirm-codex-stopped",
        action="store_true",
        help="confirm Codex is stopped for both homes (required with --apply)",
    )
    parser.add_argument(
        "--replace-existing",
        action="store_true",
        help="replace an existing target row/rollout after backing it up",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        plan = build_plan(args)
        print_plan(plan, args.replace_existing)
        if not args.apply:
            print()
            print("DRY RUN: no files or databases were changed.")
            print(
                "After stopping Codex for both homes, rerun with "
                "--apply --confirm-codex-stopped."
            )
            if plan.target_row_exists or plan.target_rollout_exists:
                print(
                    "CONFLICT: the target already contains this task; apply will "
                    "refuse unless --replace-existing is supplied."
                )
            if plan.target_home_mode & 0o077:
                print(
                    "WARNING: target CODEX_HOME is accessible by group/other users; "
                    "consider chmod 700 before storing credentials."
                )
            if plan.archive_rename_cross_device:
                print(
                    "WARNING: sessions and archived_sessions are on different "
                    "filesystems; Codex archive/unarchive may fail with EXDEV."
                )
            return 0

        manifest = apply_plan(
            plan,
            confirm_stopped=args.confirm_codex_stopped,
            replace_existing=args.replace_existing,
        )
        print()
        print("Migration completed and verified.")
        print(f"Backup and manifest: {manifest}")
        print("The source rollout and source SQLite row were retained.")
        print("Restart the target remote app-server before opening the task.")
        return 0
    except (MigrationError, ValueError, sqlite3.Error, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
