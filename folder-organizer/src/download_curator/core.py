from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import sqlite3
import struct
import sys
import tomllib
from collections import defaultdict
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence


INCOMPLETE_SUFFIXES = {".crdownload", ".partial", ".part", ".download", ".tmp"}
VIDEO_SUFFIXES = {".mp4", ".mkv", ".avi", ".mov", ".wmv", ".m4v", ".webm", ".ts", ".m2ts"}
ARCH_NAMES = {0x014C: "x86", 0x8664: "x64", 0xAA64: "arm64"}
PLAN_SCHEMA_VERSION = 2


@dataclass(frozen=True)
class Config:
    config_path: Path
    root: Path
    archive: Path
    organized: Path
    settle_hours: float
    quick_hash_bytes: int
    dedupe_move_scope: str
    exe_dirs: tuple[Path, ...]
    category_rules: tuple[tuple[str, frozenset[str]], ...]
    project_dir: Path
    state_db: Path
    reports_dir: Path


@dataclass(frozen=True)
class FileRecord:
    path: Path
    relative: str
    size: int
    mtime_ns: int
    mtime: float


@dataclass
class Action:
    kind: str
    source: str
    destination: str
    size: int
    mtime_ns: int
    reason: str
    evidence: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class ExeInfo:
    record: FileRecord
    product_name: str
    company_name: str
    file_description: str
    product_version: str
    file_version: str
    original_filename: str
    architecture: str
    parsed_version: tuple[int, ...] | None
    identity_source: str


@dataclass
class Plan:
    schema_version: int
    safety_policy: dict[str, object]
    run_id: str
    created_at: str
    root: str
    actions: list[Action]
    archive_files: int
    archive_bytes: int
    scanned_files: int
    scanned_bytes: int
    duplicate_groups: int
    exe_groups: int
    llm_review: list[dict[str, object]]
    warnings: list[str]


def load_config(path: Path) -> Config:
    config_path = path.resolve()
    with config_path.open("rb") as handle:
        raw = tomllib.load(handle)
    root = Path(raw["root"]).resolve()
    archive = (root / raw.get("archive_dir", "Archive")).resolve()
    organized = (root / raw.get("organized_dir", "分类整理")).resolve()
    rules: list[tuple[str, frozenset[str]]] = []
    for destination, suffixes in raw.get("category_rules", {}).items():
        rules.append((destination, frozenset(str(s).lower() for s in suffixes)))
    project_dir = config_path.parent
    return Config(
        config_path=config_path,
        root=root,
        archive=archive,
        organized=organized,
        settle_hours=float(raw.get("settle_hours", 48)),
        quick_hash_bytes=int(raw.get("quick_hash_bytes", 1024 * 1024)),
        dedupe_move_scope=str(raw.get("dedupe_move_scope", "root_files")),
        exe_dirs=tuple((organized / Path(item)).resolve() for item in raw.get("exe_dirs", [])),
        category_rules=tuple(rules),
        project_dir=project_dir,
        state_db=project_dir / ".state" / "curator.db",
        reports_dir=project_dir / "reports",
    )


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def scan_files(config: Config) -> list[FileRecord]:
    if not config.root.is_dir():
        raise FileNotFoundError(f"Download root does not exist: {config.root}")
    records: list[FileRecord] = []
    excluded_roots = {config.archive.resolve()}
    for current, dirs, files in os.walk(config.root, topdown=True):
        current_path = Path(current)
        kept_dirs = []
        for name in dirs:
            candidate = (current_path / name).resolve()
            if candidate in excluded_roots or name in {"$RECYCLE.BIN", "System Volume Information"}:
                continue
            if (current_path / name).is_symlink():
                continue
            kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in files:
            path = current_path / name
            try:
                if path.is_symlink():
                    continue
                stat = path.stat()
            except (FileNotFoundError, PermissionError, OSError):
                continue
            try:
                relative = str(path.resolve().relative_to(config.root))
            except ValueError:
                continue
            records.append(
                FileRecord(
                    path=path.resolve(),
                    relative=relative,
                    size=stat.st_size,
                    mtime_ns=stat.st_mtime_ns,
                    mtime=stat.st_mtime,
                )
            )
    return records


class HashCache:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.execute(
            """
            CREATE TABLE IF NOT EXISTS hash_cache (
                path TEXT PRIMARY KEY,
                size INTEGER NOT NULL,
                mtime_ns INTEGER NOT NULL,
                quick_sha256 TEXT,
                sha256 TEXT,
                updated_at TEXT NOT NULL
            )
            """
        )
        self.connection.commit()

    def get(self, record: FileRecord) -> tuple[str | None, str | None]:
        row = self.connection.execute(
            "SELECT quick_sha256, sha256, size, mtime_ns FROM hash_cache WHERE path = ?",
            (str(record.path),),
        ).fetchone()
        if row and row[2] == record.size and row[3] == record.mtime_ns:
            return row[0], row[1]
        return None, None

    def put(self, record: FileRecord, quick: str | None, full: str | None) -> None:
        self.connection.execute(
            """
            INSERT INTO hash_cache(path, size, mtime_ns, quick_sha256, sha256, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                size=excluded.size,
                mtime_ns=excluded.mtime_ns,
                quick_sha256=COALESCE(excluded.quick_sha256, hash_cache.quick_sha256),
                sha256=COALESCE(excluded.sha256, hash_cache.sha256),
                updated_at=excluded.updated_at
            """,
            (
                str(record.path),
                record.size,
                record.mtime_ns,
                quick,
                full,
                datetime.now(timezone.utc).isoformat(),
            ),
        )

    def commit(self) -> None:
        self.connection.commit()

    def close(self) -> None:
        self.connection.commit()
        self.connection.close()


def hash_quick(record: FileRecord, byte_count: int) -> str:
    digest = hashlib.sha256()
    with record.path.open("rb") as handle:
        first = handle.read(byte_count)
        digest.update(first)
        if record.size > byte_count * 2:
            handle.seek(-byte_count, os.SEEK_END)
            digest.update(handle.read(byte_count))
    return digest.hexdigest()


def hash_full(record: FileRecord) -> str:
    digest = hashlib.sha256()
    with record.path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def files_equal(first: Path, second: Path) -> bool:
    with first.open("rb") as a, second.open("rb") as b:
        while True:
            chunk_a = a.read(4 * 1024 * 1024)
            chunk_b = b.read(4 * 1024 * 1024)
            if chunk_a != chunk_b:
                return False
            if not chunk_a:
                return True


def settled(record: FileRecord, config: Config, now: float) -> bool:
    return record.mtime <= now - config.settle_hours * 3600


def canonical_key(record: FileRecord, config: Config) -> tuple[int, int, str]:
    in_organized = is_within(record.path, config.organized)
    root_file = record.path.parent == config.root
    priority = 0 if in_organized else (2 if root_file else 1)
    return priority, record.mtime_ns, record.relative.casefold()


def unique_destination(candidate: Path, occupied: set[str]) -> Path:
    key = str(candidate).casefold()
    if key not in occupied and not candidate.exists():
        occupied.add(key)
        return candidate
    index = 2
    while True:
        renamed = candidate.with_name(f"{candidate.stem} ({index}){candidate.suffix}")
        key = str(renamed).casefold()
        if key not in occupied and not renamed.exists():
            occupied.add(key)
            return renamed
        index += 1


def plan_duplicates(
    records: Sequence[FileRecord], config: Config, cache: HashCache, run_id: str, now: float
) -> tuple[list[Action], int, list[str]]:
    warnings: list[str] = []
    by_size: dict[int, list[FileRecord]] = defaultdict(list)
    for record in records:
        if record.size > 0:
            by_size[record.size].append(record)
    candidates = [group for group in by_size.values() if len(group) > 1]
    actions: list[Action] = []
    groups_found = 0
    occupied: set[str] = set()
    hashed = 0
    for size_group in candidates:
        by_quick: dict[str, list[FileRecord]] = defaultdict(list)
        for record in size_group:
            try:
                cached_quick, _ = cache.get(record)
                quick = cached_quick or hash_quick(record, config.quick_hash_bytes)
                cache.put(record, quick, None)
                by_quick[quick].append(record)
                hashed += 1
                if hashed % 100 == 0:
                    print(f"  快速哈希进度: {hashed}", flush=True)
            except (PermissionError, OSError) as exc:
                warnings.append(f"无法读取文件进行快速哈希: {record.relative}: {exc}")
        for quick_group in by_quick.values():
            if len(quick_group) < 2:
                continue
            by_full: dict[str, list[FileRecord]] = defaultdict(list)
            for record in quick_group:
                try:
                    _, cached_full = cache.get(record)
                    full = cached_full or hash_full(record)
                    cache.put(record, None, full)
                    by_full[full].append(record)
                except (PermissionError, OSError) as exc:
                    warnings.append(f"无法读取文件进行完整哈希: {record.relative}: {exc}")
            for digest, full_group in by_full.items():
                if len(full_group) < 2:
                    continue
                verified: list[list[FileRecord]] = []
                for record in sorted(full_group, key=lambda item: canonical_key(item, config)):
                    placed = False
                    for subgroup in verified:
                        try:
                            if files_equal(subgroup[0].path, record.path):
                                subgroup.append(record)
                                placed = True
                                break
                        except (PermissionError, OSError) as exc:
                            warnings.append(f"无法逐字节确认重复文件: {record.relative}: {exc}")
                            placed = True
                            break
                    if not placed:
                        verified.append([record])
                for duplicate_group in verified:
                    if len(duplicate_group) < 2:
                        continue
                    groups_found += 1
                    canonical = min(duplicate_group, key=lambda item: canonical_key(item, config))
                    for duplicate in duplicate_group:
                        if duplicate.path == canonical.path or not settled(duplicate, config, now):
                            continue
                        if config.dedupe_move_scope == "root_files" and duplicate.path.parent != config.root:
                            continue
                        relative = Path(duplicate.relative)
                        destination = unique_destination(
                            config.archive / "Duplicates" / run_id / relative, occupied
                        )
                        actions.append(
                            Action(
                                kind="archive_duplicate",
                                source=str(duplicate.path),
                                destination=str(destination),
                                size=duplicate.size,
                                mtime_ns=duplicate.mtime_ns,
                                reason="与保留文件逐字节相同",
                                evidence={
                                    "sha256": digest,
                                    "canonical": str(canonical.path),
                                },
                            )
                        )
    cache.commit()
    return actions, groups_found, warnings


def parse_version(value: str) -> tuple[int, ...] | None:
    if not value:
        return None
    match = re.search(r"(?<!\d)[vV]?(\d+(?:\.\d+){1,4})(?!\d)", value)
    if not match:
        return None
    parts = tuple(int(part) for part in match.group(1).split("."))
    return parts + (0,) * (4 - len(parts))


def pe_architecture(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            if handle.read(2) != b"MZ":
                return "unknown"
            handle.seek(0x3C)
            offset_data = handle.read(4)
            if len(offset_data) != 4:
                return "unknown"
            pe_offset = struct.unpack("<I", offset_data)[0]
            handle.seek(pe_offset)
            if handle.read(4) != b"PE\x00\x00":
                return "unknown"
            machine_data = handle.read(2)
            if len(machine_data) != 2:
                return "unknown"
            return ARCH_NAMES.get(struct.unpack("<H", machine_data)[0], "other")
    except (OSError, PermissionError):
        return "unknown"


class VS_FIXEDFILEINFO(ctypes.Structure):
    _fields_ = [
        ("dwSignature", ctypes.c_uint32),
        ("dwStrucVersion", ctypes.c_uint32),
        ("dwFileVersionMS", ctypes.c_uint32),
        ("dwFileVersionLS", ctypes.c_uint32),
        ("dwProductVersionMS", ctypes.c_uint32),
        ("dwProductVersionLS", ctypes.c_uint32),
        ("dwFileFlagsMask", ctypes.c_uint32),
        ("dwFileFlags", ctypes.c_uint32),
        ("dwFileOS", ctypes.c_uint32),
        ("dwFileType", ctypes.c_uint32),
        ("dwFileSubtype", ctypes.c_uint32),
        ("dwFileDateMS", ctypes.c_uint32),
        ("dwFileDateLS", ctypes.c_uint32),
    ]


def windows_version_strings(path: Path) -> dict[str, str]:
    if os.name != "nt":
        return {}
    version = ctypes.windll.version
    size = version.GetFileVersionInfoSizeW(str(path), None)
    if not size:
        return {}
    buffer = ctypes.create_string_buffer(size)
    if not version.GetFileVersionInfoW(str(path), 0, size, buffer):
        return {}
    translations: list[tuple[int, int]] = []
    pointer = ctypes.c_void_p()
    length = ctypes.c_uint()
    if version.VerQueryValueW(buffer, r"\VarFileInfo\Translation", ctypes.byref(pointer), ctypes.byref(length)):
        count = length.value // 4
        values = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_ushort))
        translations.extend((values[i * 2], values[i * 2 + 1]) for i in range(count))
    translations.extend([(0x0409, 0x04B0), (0x0409, 0x04E4)])
    result: dict[str, str] = {}
    keys = (
        "ProductName",
        "CompanyName",
        "FileDescription",
        "ProductVersion",
        "FileVersion",
        "OriginalFilename",
    )
    for language, codepage in dict.fromkeys(translations):
        for key in keys:
            if key in result:
                continue
            query = f"\\StringFileInfo\\{language:04x}{codepage:04x}\\{key}"
            value_pointer = ctypes.c_void_p()
            value_length = ctypes.c_uint()
            if version.VerQueryValueW(buffer, query, ctypes.byref(value_pointer), ctypes.byref(value_length)):
                # Vendor resources sometimes report a length that spans adjacent fields.
                # Stop at the first NUL instead of trusting that length for display data.
                value = ctypes.wstring_at(value_pointer).strip()
                if value:
                    result[key] = value
    fixed_pointer = ctypes.c_void_p()
    fixed_length = ctypes.c_uint()
    if version.VerQueryValueW(buffer, "\\", ctypes.byref(fixed_pointer), ctypes.byref(fixed_length)):
        fixed = ctypes.cast(fixed_pointer, ctypes.POINTER(VS_FIXEDFILEINFO)).contents
        file_version = (
            fixed.dwFileVersionMS >> 16,
            fixed.dwFileVersionMS & 0xFFFF,
            fixed.dwFileVersionLS >> 16,
            fixed.dwFileVersionLS & 0xFFFF,
        )
        product_version = (
            fixed.dwProductVersionMS >> 16,
            fixed.dwProductVersionMS & 0xFFFF,
            fixed.dwProductVersionLS >> 16,
            fixed.dwProductVersionLS & 0xFFFF,
        )
        if any(file_version):
            result.setdefault("FileVersion", ".".join(map(str, file_version)))
        if any(product_version):
            result.setdefault("ProductVersion", ".".join(map(str, product_version)))
    return result


def normalize_identity(value: str) -> str:
    value = re.sub(r"(?<!\d)[vV]?\d+(?:\.\d+){1,4}(?!\d)", " ", value)
    value = re.sub(r"\b(x64|x86|amd64|arm64|win32|win64|setup|installer|portable)\b", " ", value, flags=re.I)
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def normalize_filename_family(value: str) -> str:
    value = re.sub(r"(?<!\d)[vV]?\d+(?:\.\d+){1,4}(?!\d)", " ", value)
    value = re.sub(r"(?<!\d)\d{6,}(?!\d)", " ", value)
    value = re.sub(
        r"\b(x64|x86|amd64|arm64|win32|win64|setup|installer|portable|offline|online|release|stable)\b",
        " ",
        value,
        flags=re.I,
    )
    return "".join(character for character in value.casefold() if character.isalnum())


def inspect_exe(record: FileRecord) -> ExeInfo:
    strings = windows_version_strings(record.path)
    product = strings.get("ProductName", "").strip()
    description = strings.get("FileDescription", "").strip()
    company = strings.get("CompanyName", "").strip()
    product_version = strings.get("ProductVersion", "").strip()
    file_version = strings.get("FileVersion", "").strip()
    original_filename = strings.get("OriginalFilename", "").strip()
    parsed = parse_version(product_version) or parse_version(file_version) or parse_version(record.path.stem)
    identity_source = "metadata" if product or description else "filename"
    return ExeInfo(
        record=record,
        product_name=product,
        company_name=company,
        file_description=description,
        product_version=product_version,
        file_version=file_version,
        original_filename=original_filename,
        architecture=pe_architecture(record.path),
        parsed_version=parsed,
        identity_source=identity_source,
    )


def safe_component(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]+', "_", value).strip(" ._")
    return cleaned[:80] or "Unknown"


def plan_old_exes(
    records: Sequence[FileRecord], config: Config, run_id: str, now: float, blocked: set[str]
) -> tuple[list[Action], int, list[dict[str, object]], list[str]]:
    warnings: list[str] = []
    review: list[dict[str, object]] = []
    confident: dict[tuple[str, str, str, str], list[ExeInfo]] = defaultdict(list)
    for record in records:
        if record.path.suffix.casefold() != ".exe" or str(record.path).casefold() in blocked:
            continue
        if not settled(record, config, now):
            continue
        if record.path.parent != config.root and record.path.parent not in config.exe_dirs:
            continue
        try:
            info = inspect_exe(record)
        except Exception as exc:  # metadata readers must not stop the whole scan
            warnings.append(f"EXE 元数据读取失败: {record.relative}: {exc}")
            continue
        identity = normalize_identity(info.product_name or info.file_description)
        company = normalize_identity(info.company_name)
        # Metadata such as "Store Installer" or "NVIDIA Package Launcher" is
        # shared by unrelated downloads. Require the normalized download name to
        # match as a second, independent product-family signal.
        variant = normalize_filename_family(record.path.stem)
        if (
            info.identity_source == "metadata"
            and identity
            and len(variant) >= 4
            and variant not in {"setup", "installer", "storeinstaller", "package"}
            and info.parsed_version
            and (company or info.original_filename)
        ):
            confident[(company, identity, variant, info.architecture)].append(info)
        else:
            review.append(
                {
                    "id": hashlib.sha256(record.relative.encode("utf-8")).hexdigest()[:16],
                    "kind": "exe_identity_or_version",
                    "relative_path": record.relative,
                    "size": record.size,
                    "product_name": info.product_name,
                    "company_name": info.company_name,
                    "file_description": info.file_description,
                    "product_version": info.product_version,
                    "file_version": info.file_version,
                    "original_filename": info.original_filename,
                    "architecture": info.architecture,
                    "filename_version": list(info.parsed_version) if info.parsed_version else None,
                    "reason": "产品身份或版本证据不足，禁止自动归档",
                }
            )
    actions: list[Action] = []
    groups = 0
    occupied: set[str] = set()
    for (_, _, variant, architecture), group in confident.items():
        versions = {item.parsed_version for item in group}
        if len(group) < 2 or len(versions) < 2:
            continue
        groups += 1
        newest = max(item.parsed_version for item in group if item.parsed_version is not None)
        product_label = next((item.product_name for item in group if item.product_name), "Unknown")
        for item in group:
            if item.parsed_version is None or item.parsed_version >= newest:
                continue
            destination = unique_destination(
                config.archive / "OldEXE" / safe_component(product_label) / architecture / run_id / item.record.path.name,
                occupied,
            )
            actions.append(
                Action(
                    kind="archive_old_exe",
                    source=str(item.record.path),
                    destination=str(destination),
                    size=item.record.size,
                    mtime_ns=item.record.mtime_ns,
                    reason="同一产品、公司和架构下存在更高版本",
                    evidence={
                        "product": product_label,
                        "company": item.company_name,
                        "architecture": architecture,
                        "variant": variant,
                        "version": list(item.parsed_version),
                        "newest_version": list(newest),
                    },
                )
            )
    return actions, groups, review, warnings


def category_for(record: FileRecord, config: Config) -> str | None:
    suffix = record.path.suffix.casefold()
    if suffix in VIDEO_SUFFIXES:
        return "Media/Movies" if record.size >= 700 * 1024 * 1024 else "Media/Video_Fragments"
    for destination, suffixes in config.category_rules:
        if suffix in suffixes:
            return destination
    return None


def plan_categories(
    records: Sequence[FileRecord], config: Config, now: float, blocked: set[str]
) -> tuple[list[Action], list[dict[str, object]]]:
    actions: list[Action] = []
    review: list[dict[str, object]] = []
    occupied: set[str] = set()
    allowed = [destination for destination, _ in config.category_rules]
    allowed.extend(["Media/Movies", "Media/Video_Fragments", "Personal/Misc"])
    for record in records:
        source_key = str(record.path).casefold()
        if record.path.parent != config.root or source_key in blocked:
            continue
        if not settled(record, config, now):
            continue
        suffix = record.path.suffix.casefold()
        if suffix in INCOMPLETE_SUFFIXES:
            review.append(
                {
                    "id": hashlib.sha256(record.relative.encode("utf-8")).hexdigest()[:16],
                    "kind": "incomplete_download",
                    "relative_path": record.relative,
                    "size": record.size,
                    "reason": "疑似未完成或临时文件，禁止自动移动",
                }
            )
            continue
        category = category_for(record, config)
        if category is None:
            review.append(
                {
                    "id": hashlib.sha256(record.relative.encode("utf-8")).hexdigest()[:16],
                    "kind": "unknown_category",
                    "relative_path": record.relative,
                    "size": record.size,
                    "allowed_categories": sorted(set(allowed)),
                    "suggested_fallback": "Personal/Misc",
                    "reason": "扩展名规则无法确定类别",
                }
            )
            continue
        destination = unique_destination(config.organized / Path(category) / record.path.name, occupied)
        actions.append(
            Action(
                kind="categorize",
                source=str(record.path),
                destination=str(destination),
                size=record.size,
                mtime_ns=record.mtime_ns,
                reason=f"按文件类型归入 {category}",
                evidence={"category": category, "suffix": suffix},
            )
        )
    return actions, review


def archive_stats(config: Config) -> tuple[int, int]:
    if not config.archive.exists():
        return 0, 0
    count = 0
    total = 0
    for current, _, files in os.walk(config.archive):
        for name in files:
            try:
                stat = (Path(current) / name).stat()
            except (FileNotFoundError, PermissionError, OSError):
                continue
            count += 1
            total += stat.st_size
    return count, total


def build_plan(config: Config) -> Plan:
    now = datetime.now(timezone.utc).timestamp()
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    print(f"扫描: {config.root}", flush=True)
    records = scan_files(config)
    print(f"找到 {len(records)} 个文件，开始精确去重检查...", flush=True)
    cache = HashCache(config.state_db)
    try:
        duplicate_actions, duplicate_groups, duplicate_warnings = plan_duplicates(
            records, config, cache, run_id, now
        )
    finally:
        cache.close()
    blocked = {action.source.casefold() for action in duplicate_actions}
    print("检查 EXE 版本...", flush=True)
    exe_actions, exe_groups, exe_review, exe_warnings = plan_old_exes(
        records, config, run_id, now, blocked
    )
    blocked.update(action.source.casefold() for action in exe_actions)
    print("生成根目录分类计划...", flush=True)
    category_actions, category_review = plan_categories(records, config, now, blocked)
    archive_files, archive_bytes = archive_stats(config)
    actions = duplicate_actions + exe_actions + category_actions
    return Plan(
        schema_version=PLAN_SCHEMA_VERSION,
        safety_policy={
            "delete_supported": False,
            "dedupe_move_scope": config.dedupe_move_scope,
            "archive_excluded_from_scan": True,
            "exe_dirs": [str(path) for path in config.exe_dirs],
        },
        run_id=run_id,
        created_at=datetime.now(timezone.utc).isoformat(),
        root=str(config.root),
        actions=actions,
        archive_files=archive_files,
        archive_bytes=archive_bytes,
        scanned_files=len(records),
        scanned_bytes=sum(record.size for record in records),
        duplicate_groups=duplicate_groups,
        exe_groups=exe_groups,
        llm_review=exe_review + category_review,
        warnings=duplicate_warnings + exe_warnings,
    )


def human_bytes(value: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} TB"


def plan_summary(plan: Plan) -> dict[str, object]:
    counts: dict[str, int] = defaultdict(int)
    bytes_by_kind: dict[str, int] = defaultdict(int)
    for action in plan.actions:
        counts[action.kind] += 1
        bytes_by_kind[action.kind] += action.size
    return {
        "actions": len(plan.actions),
        "counts": dict(counts),
        "bytes_by_kind": dict(bytes_by_kind),
        "archive_files": plan.archive_files,
        "archive_bytes": plan.archive_bytes,
        "llm_review": len(plan.llm_review),
        "warnings": len(plan.warnings),
    }


def write_plan(config: Config, plan: Plan) -> Path:
    report_dir = config.reports_dir / plan.run_id
    report_dir.mkdir(parents=True, exist_ok=False)
    payload = asdict(plan)
    payload["summary"] = plan_summary(plan)
    plan_path = report_dir / "plan.json"
    plan_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    review_payload = {
        "run_id": plan.run_id,
        "instruction": "仅提出建议；不得删除、移动或执行任何文件。",
        "items": plan.llm_review,
    }
    (report_dir / "llm-review.json").write_text(
        json.dumps(review_payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    summary = plan_summary(plan)
    counts = summary["counts"]
    bytes_by_kind = summary["bytes_by_kind"]
    lines = [
        f"# Download Curator dry-run {plan.run_id}",
        "",
        "> 本报告没有移动或删除任何下载文件。",
        "",
        f"- 扫描：{plan.scanned_files} 个文件 / {human_bytes(plan.scanned_bytes)}",
        f"- 重复组：{plan.duplicate_groups}",
        f"- 可归档重复副本：{counts.get('archive_duplicate', 0)} 个 / {human_bytes(bytes_by_kind.get('archive_duplicate', 0))}",
        f"- 可归档旧版 EXE：{counts.get('archive_old_exe', 0)} 个 / {human_bytes(bytes_by_kind.get('archive_old_exe', 0))}",
        f"- 可按类型分类：{counts.get('categorize', 0)} 个 / {human_bytes(bytes_by_kind.get('categorize', 0))}",
        f"- 需要 LLM/人工确认：{len(plan.llm_review)} 个",
        f"- Archive 当前：{plan.archive_files} 个文件 / {human_bytes(plan.archive_bytes)}",
        f"- 警告：{len(plan.warnings)}",
        "",
        "## 计划动作预览",
        "",
    ]
    for action in plan.actions[:100]:
        lines.append(f"- `{action.kind}`：`{action.source}` → `{action.destination}`")
    if len(plan.actions) > 100:
        lines.append(f"- ……其余 {len(plan.actions) - 100} 项见 `plan.json`。")
    if plan.warnings:
        lines.extend(["", "## 警告", ""])
        lines.extend(f"- {warning}" for warning in plan.warnings[:100])
    (report_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    latest = config.reports_dir / "latest.json"
    latest.write_text(
        json.dumps({"run_id": plan.run_id, "report_dir": str(report_dir)}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return report_dir


def load_plan(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_action(config: Config, raw: dict[str, object]) -> tuple[Path, Path]:
    source = Path(str(raw["source"])).resolve()
    destination = Path(str(raw["destination"])).resolve()
    if not is_within(source, config.root) or is_within(source, config.archive):
        raise ValueError(f"Unsafe source: {source}")
    if not is_within(destination, config.root):
        raise ValueError(f"Unsafe destination: {destination}")
    kind = str(raw.get("kind", ""))
    if kind.startswith("archive_") and not is_within(destination, config.archive):
        raise ValueError(f"Archive action leaves Archive: {destination}")
    if kind in {"categorize", "classify_document", "categorize_directory"} and not is_within(destination, config.organized):
        raise ValueError(f"Categorize action leaves organized directory: {destination}")
    if kind == "categorize_directory" and source.parent != config.root:
        raise ValueError(f"Directory action source is not a root directory: {source}")
    return source, destination


def directory_snapshot(path: Path) -> dict[str, int]:
    root_stat = path.stat()
    file_count = 0
    directory_count = 0
    total_bytes = 0
    latest_mtime_ns = root_stat.st_mtime_ns
    for directory, directory_names, file_names in os.walk(path, followlinks=False):
        directory_path = Path(directory)
        directory_count += len(directory_names)
        for name in directory_names:
            latest_mtime_ns = max(latest_mtime_ns, (directory_path / name).lstat().st_mtime_ns)
        for name in file_names:
            stat = (directory_path / name).lstat()
            file_count += 1
            total_bytes += stat.st_size
            latest_mtime_ns = max(latest_mtime_ns, stat.st_mtime_ns)
    return {
        "file_count": file_count,
        "directory_count": directory_count,
        "size": total_bytes,
        "mtime_ns": latest_mtime_ns,
    }


def apply_plan(config: Config, plan_path: Path, confirm: str) -> Path:
    if confirm != "APPLY":
        raise ValueError("Applying requires --confirm APPLY")
    payload = load_plan(plan_path.resolve())
    if payload.get("schema_version") != PLAN_SCHEMA_VERSION:
        raise ValueError("Plan schema is obsolete or unknown; generate a new dry-run plan")
    if Path(str(payload.get("root", ""))).resolve() != config.root:
        raise ValueError("Plan root does not match the active configuration")
    policy = payload.get("safety_policy", {})
    if not isinstance(policy, dict) or policy.get("delete_supported") is not False:
        raise ValueError("Plan does not assert the no-delete safety policy")
    if policy.get("dedupe_move_scope") != config.dedupe_move_scope:
        raise ValueError("Plan dedupe policy does not match the active configuration")
    document_source: Path | None = None
    if payload.get("plan_type") == "document_semantic":
        if policy.get("document_policy_version") != 2:
            raise ValueError("Document plan policy is obsolete; generate a new document dry-run")
        if policy.get("sensitive_filename_required") is not True:
            raise ValueError("Document plan does not enforce conservative sensitive classification")
        if policy.get("llm_may_move_files") is not False:
            raise ValueError("Document plan grants unsafe file authority to an LLM")
        document_source = Path(str(policy.get("document_source", ""))).resolve()
        if not is_within(document_source, config.organized):
            raise ValueError("Document source is outside the organized directory")
    run_id = str(payload["run_id"])
    applied: list[dict[str, object]] = []
    skipped: list[dict[str, object]] = []
    for raw in payload.get("actions", []):
        source, destination = validate_action(config, raw)
        kind = str(raw.get("kind", ""))
        if document_source is not None and source.parent != document_source:
            raise ValueError(f"Document action source leaves the configured source directory: {source}")
        if kind == "categorize_directory":
            if not source.is_dir():
                skipped.append({"source": str(source), "reason": "source_missing"})
                continue
            snapshot = directory_snapshot(source)
            expected = {
                "file_count": int(raw["file_count"]),
                "directory_count": int(raw["directory_count"]),
                "size": int(raw["size"]),
                "mtime_ns": int(raw["mtime_ns"]),
            }
            if snapshot != expected:
                skipped.append({"source": str(source), "reason": "source_changed"})
                continue
        elif not source.is_file():
            skipped.append({"source": str(source), "reason": "source_missing"})
            continue
        else:
            stat = source.stat()
            if stat.st_size != int(raw["size"]) or stat.st_mtime_ns != int(raw["mtime_ns"]):
                skipped.append({"source": str(source), "reason": "source_changed"})
                continue
        if destination.exists():
            skipped.append({"source": str(source), "reason": "destination_exists"})
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(destination))
        applied.append({"source": str(source), "destination": str(destination), "kind": raw["kind"]})
    rollback = {
        "run_id": run_id,
        "applied_at": datetime.now(timezone.utc).isoformat(),
        "moves": applied,
        "skipped": skipped,
    }
    rollback_path = plan_path.parent / "rollback.json"
    rollback_path.write_text(json.dumps(rollback, ensure_ascii=False, indent=2), encoding="utf-8")
    return rollback_path


def undo_moves(config: Config, rollback_path: Path, confirm: str) -> Path:
    if confirm != "UNDO":
        raise ValueError("Undo requires --confirm UNDO")
    payload = json.loads(rollback_path.read_text(encoding="utf-8"))
    undone: list[dict[str, str]] = []
    skipped: list[dict[str, str]] = []
    for move in reversed(payload.get("moves", [])):
        source = Path(move["source"]).resolve()
        destination = Path(move["destination"]).resolve()
        if not is_within(source, config.root) or not is_within(destination, config.root):
            skipped.append({"destination": str(destination), "reason": "unsafe_path"})
            continue
        kind = str(move.get("kind", ""))
        destination_exists = destination.is_dir() if kind == "categorize_directory" else destination.is_file()
        if not destination_exists or source.exists():
            skipped.append({"destination": str(destination), "reason": "missing_or_conflict"})
            continue
        source.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(destination), str(source))
        undone.append({"source": str(source), "destination": str(destination)})
    result_path = rollback_path.parent / "undo-result.json"
    result_path.write_text(
        json.dumps({"undone": undone, "skipped": skipped}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return result_path


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Safety-first organizer for a configured Windows folder")
    parser.add_argument("--config", type=Path, default=Path("config.toml"))
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("plan", help="Create a dry-run plan; never moves download files")
    document_parser = subparsers.add_parser(
        "document-plan", help="Create a semantic second-layer document dry-run plan"
    )
    document_parser.add_argument(
        "--decisions", type=Path, help="Optional validated LLM decision JSON"
    )
    apply_parser = subparsers.add_parser("apply", help="Apply a previously reviewed plan")
    apply_parser.add_argument("--plan", type=Path, required=True)
    apply_parser.add_argument("--confirm", required=True)
    undo_parser = subparsers.add_parser("undo", help="Undo moves from a rollback manifest")
    undo_parser.add_argument("--rollback", type=Path, required=True)
    undo_parser.add_argument("--confirm", required=True)
    subparsers.add_parser("archive-stats", help="Show current Archive file count and bytes")
    subparsers.add_parser("index", help="Build or incrementally refresh the local file search database")
    search_parser = subparsers.add_parser("search", help="Search the local file database")
    search_parser.add_argument("query")
    search_parser.add_argument("--limit", type=int, default=10)
    subparsers.add_parser("index-stats", help="Show local file search database statistics")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    try:
        config = load_config(args.config)
        if args.command == "plan":
            plan = build_plan(config)
            report_dir = write_plan(config, plan)
            print(f"DRY_RUN_REPORT={report_dir / 'summary.md'}")
            print(json.dumps(plan_summary(plan), ensure_ascii=False))
            return 0
        if args.command == "document-plan":
            from .documents import build_document_plan, write_document_plan

            payload = build_document_plan(config, args.decisions)
            report_dir = write_document_plan(config, payload)
            print(f"DOCUMENT_DRY_RUN_REPORT={report_dir / 'summary.md'}")
            print(json.dumps(payload["summary"], ensure_ascii=False))
            return 0
        if args.command == "apply":
            rollback_path = apply_plan(config, args.plan, args.confirm)
            print(f"ROLLBACK_MANIFEST={rollback_path}")
            return 0
        if args.command == "undo":
            result_path = undo_moves(config, args.rollback, args.confirm)
            print(f"UNDO_RESULT={result_path}")
            return 0
        if args.command == "archive-stats":
            files, size = archive_stats(config)
            print(json.dumps({"files": files, "bytes": size, "human": human_bytes(size)}, ensure_ascii=False))
            return 0
        if args.command in {"index", "search", "index-stats"}:
            from .indexer import build_index, index_stats, search_index

            if args.command == "index":
                print(json.dumps(build_index(config), ensure_ascii=False))
            elif args.command == "search":
                print(json.dumps(search_index(config, args.query, args.limit), ensure_ascii=False))
            else:
                print(json.dumps(index_stats(config), ensure_ascii=False))
            return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 2
