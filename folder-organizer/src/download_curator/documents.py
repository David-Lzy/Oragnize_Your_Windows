from __future__ import annotations

import hashlib
import html
import json
import logging
import re
import tomllib
import zipfile
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from .core import (
    PLAN_SCHEMA_VERSION,
    Action,
    Config,
    FileRecord,
    human_bytes,
    settled,
    unique_destination,
)


DOCUMENT_SUFFIXES = {
    ".pdf",
    ".doc",
    ".docx",
    ".ppt",
    ".pptx",
    ".xls",
    ".xlsx",
    ".xlsm",
    ".csv",
    ".ods",
    ".txt",
    ".md",
    ".rtf",
    ".html",
    ".htm",
    ".mht",
    ".mhtml",
    ".epub",
    ".xmind",
}


@dataclass(frozen=True)
class DocumentRule:
    category: str
    keywords: tuple[str, ...]
    local_only: bool


@dataclass(frozen=True)
class DocumentSettings:
    source_dir: Path
    preview_chars: int
    max_extract_bytes: int
    pdf_pages: int
    min_score: int
    min_margin: int
    llm_min_confidence: float
    allowed_categories: tuple[str, ...]
    rules: tuple[DocumentRule, ...]


@dataclass(frozen=True)
class Extraction:
    text: str
    status: str
    metadata: dict[str, object]


@dataclass(frozen=True)
class DocumentCandidate:
    record: FileRecord
    file_id: str
    extraction: Extraction
    scores: dict[str, int]
    sensitive_signal: bool
    local_category: str | None
    local_confidence: float
    matched_keywords: tuple[str, ...]


def load_document_settings(config: Config) -> DocumentSettings:
    with config.config_path.open("rb") as handle:
        raw = tomllib.load(handle)
    settings = raw.get("document_settings", {})
    categories = raw.get("document_categories", {})
    allowed = tuple(str(item) for item in settings.get("allowed_categories", []))
    rules: list[DocumentRule] = []
    for category, rule in categories.items():
        if category not in allowed:
            raise ValueError(f"Document category is not allowlisted: {category}")
        rules.append(
            DocumentRule(
                category=category,
                keywords=tuple(str(item).casefold() for item in rule.get("keywords", [])),
                local_only=bool(rule.get("local_only", False)),
            )
        )
    return DocumentSettings(
        source_dir=(config.organized / Path(settings.get("source_dir", "Documents/General"))).resolve(),
        preview_chars=int(settings.get("preview_chars", 800)),
        max_extract_bytes=int(settings.get("max_extract_mb", 100)) * 1024 * 1024,
        pdf_pages=int(settings.get("pdf_pages", 3)),
        min_score=int(settings.get("min_score", 4)),
        min_margin=int(settings.get("min_margin", 2)),
        llm_min_confidence=float(settings.get("llm_min_confidence", 0.9)),
        allowed_categories=allowed,
        rules=tuple(rules),
    )


def _normalise_text(value: str, limit: int = 12000) -> str:
    value = html.unescape(value)
    value = re.sub(r"<[^>]+>", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit]


def _decode_bytes(data: bytes) -> str:
    for encoding in ("utf-8-sig", "utf-16", "gb18030", "cp1252"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def _extract_plain(path: Path, byte_limit: int = 1024 * 1024) -> Extraction:
    with path.open("rb") as handle:
        data = handle.read(byte_limit)
    text = _decode_bytes(data)
    if path.suffix.casefold() == ".rtf":
        text = re.sub(r"\\[a-z]+-?\d* ?", " ", text, flags=re.I)
        text = text.replace("{", " ").replace("}", " ")
    return Extraction(_normalise_text(text), "text", {})


def _zip_members_for(suffix: str, names: Iterable[str]) -> list[str]:
    names = list(names)
    if suffix == ".docx":
        return [name for name in names if name == "word/document.xml" or name.startswith("word/header")]
    if suffix == ".pptx":
        return sorted(name for name in names if name.startswith("ppt/slides/slide") and name.endswith(".xml"))[:12]
    if suffix in {".xlsx", ".xlsm"}:
        preferred = [name for name in names if name in {"xl/workbook.xml", "xl/sharedStrings.xml"}]
        preferred.extend(sorted(name for name in names if name.startswith("xl/worksheets/sheet") and name.endswith(".xml"))[:3])
        return preferred
    if suffix == ".ods":
        return [name for name in names if name == "content.xml"]
    if suffix == ".xmind":
        return [name for name in names if name in {"content.xml", "content.json", "metadata.json"}]
    if suffix == ".epub":
        return sorted(name for name in names if name.casefold().endswith((".xhtml", ".html", ".htm")))[:8]
    return []


def _extract_zip_document(path: Path) -> Extraction:
    suffix = path.suffix.casefold()
    chunks: list[str] = []
    total_bytes = 0
    byte_limit = 2 * 1024 * 1024
    with zipfile.ZipFile(path) as archive:
        members = _zip_members_for(suffix, archive.namelist())
        for member in members:
            remaining = byte_limit - total_bytes
            if remaining <= 0:
                break
            with archive.open(member) as handle:
                data = handle.read(min(remaining, 512 * 1024))
            total_bytes += len(data)
            chunks.append(_decode_bytes(data))
    text = _normalise_text(" ".join(chunks))
    return Extraction(text, "office_xml" if text else "no_text", {"members_read": len(chunks)})


def _extract_pdf(path: Path, pages: int) -> Extraction:
    try:
        from pypdf import PdfReader
    except ImportError:
        return Extraction("", "missing_pypdf", {})
    pypdf_logger = logging.getLogger("pypdf")
    pypdf_logger.handlers = [logging.NullHandler()]
    pypdf_logger.propagate = False
    pypdf_logger.setLevel(logging.CRITICAL + 1)
    reader = PdfReader(str(path), strict=False)
    if reader.is_encrypted:
        try:
            if reader.decrypt("") == 0:
                return Extraction("", "encrypted", {"pages": len(reader.pages)})
        except Exception:
            return Extraction("", "encrypted", {})
    chunks: list[str] = []
    page_count = len(reader.pages)
    for page in reader.pages[:pages]:
        try:
            chunks.append(page.extract_text() or "")
        except Exception:
            continue
    metadata: dict[str, object] = {"pages": page_count, "pages_sampled": min(page_count, pages)}
    try:
        title = str((reader.metadata or {}).get("/Title", "")).strip()
        if title:
            metadata["title"] = title[:300]
            chunks.insert(0, title)
    except Exception:
        pass
    text = _normalise_text(" ".join(chunks))
    return Extraction(text, "pdf_text" if text else "needs_ocr", metadata)


def extract_document(path: Path, settings: DocumentSettings) -> Extraction:
    if path.stat().st_size > settings.max_extract_bytes:
        return Extraction("", "too_large", {"limit_bytes": settings.max_extract_bytes})
    suffix = path.suffix.casefold()
    try:
        if suffix == ".pdf":
            return _extract_pdf(path, settings.pdf_pages)
        if suffix in {".docx", ".pptx", ".xlsx", ".xlsm", ".ods", ".epub", ".xmind"}:
            return _extract_zip_document(path)
        if suffix in {".txt", ".md", ".csv", ".rtf", ".html", ".htm", ".mht", ".mhtml"}:
            return _extract_plain(path)
        if suffix in {".doc", ".ppt", ".xls"}:
            return Extraction("", "unsupported_legacy_binary", {})
        return Extraction("", "unsupported", {})
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        return Extraction("", "extract_error", {"error": str(exc)[:300]})
    except Exception as exc:
        return Extraction("", "extract_error", {"error": f"{type(exc).__name__}: {str(exc)[:240]}"})


def _keyword_count(text: str, keyword: str) -> int:
    if not text or not keyword:
        return 0
    folded = text.casefold()
    if keyword.isascii() and keyword.replace(" ", "").isalnum() and len(keyword) <= 3:
        return min(3, len(re.findall(rf"(?<![a-z0-9]){re.escape(keyword)}(?![a-z0-9])", folded)))
    return min(3, folded.count(keyword))


def _redact_preview(text: str, limit: int) -> str:
    text = re.sub(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", "[EMAIL]", text, flags=re.I)
    text = re.sub(r"(?<!\d)(?:\+?\d[\d ()-]{7,}\d)(?!\d)", "[PHONE_OR_ID]", text)
    text = re.sub(r"\b(?:sk-|pk-|ghp_|github_pat_)[A-Za-z0-9_-]{12,}\b", "[TOKEN]", text)
    text = re.sub(r"\b[A-Za-z0-9+/=_-]{28,}\b", "[LONG_TOKEN]", text)
    return text[:limit]


def _file_record(path: Path, source_dir: Path) -> FileRecord:
    stat = path.stat()
    return FileRecord(
        path=path.resolve(),
        relative=str(path.resolve().relative_to(source_dir)),
        size=stat.st_size,
        mtime_ns=stat.st_mtime_ns,
        mtime=stat.st_mtime,
    )


def inspect_candidate(record: FileRecord, settings: DocumentSettings) -> DocumentCandidate:
    extraction = extract_document(record.path, settings)
    filename_text = record.path.stem.replace("_", " ").replace("-", " ")
    combined_text = f"{filename_text} {extraction.text}"
    scores: dict[str, int] = {}
    matches_by_category: dict[str, list[str]] = {}
    name_matches_by_category: dict[str, list[str]] = {}
    sensitive_signal = False
    for rule in settings.rules:
        score = 0
        matched: list[str] = []
        name_matched: list[str] = []
        for keyword in rule.keywords:
            name_count = _keyword_count(filename_text, keyword)
            text_count = _keyword_count(extraction.text, keyword)
            if name_count or text_count:
                matched.append(keyword)
            if name_count:
                name_matched.append(keyword)
            score += name_count * 4 + text_count
            if rule.local_only and (name_count or text_count):
                sensitive_signal = True
        scores[rule.category] = score
        matches_by_category[rule.category] = matched
        name_matches_by_category[rule.category] = name_matched
    ranked = sorted(scores.items(), key=lambda item: (-item[1], item[0]))
    local_category: str | None = None
    confidence = 0.0
    matched_keywords: tuple[str, ...] = ()
    if ranked:
        top_category, top_score = ranked[0]
        second_score = ranked[1][1] if len(ranked) > 1 else 0
        if top_score >= settings.min_score and top_score - second_score >= settings.min_margin:
            top_rule = next(rule for rule in settings.rules if rule.category == top_category)
            # Content may discuss passwords, passports, or keys without itself
            # being a credential/identity document. Sensitive categories require
            # direct filename evidence for an automatic suggestion.
            if not top_rule.local_only or name_matches_by_category[top_category]:
                local_category = top_category
                confidence = min(0.99, 0.80 + min(top_score, 12) * 0.015 + min(top_score - second_score, 5) * 0.01)
                matched_keywords = tuple(matches_by_category[top_category])
    suffix = record.path.suffix.casefold()
    if local_category is None and suffix in {".html", ".htm", ".mht", ".mhtml"}:
        local_category = "Personal/Web_Exports"
        confidence = 0.96
        matched_keywords = ("file type",)
    file_id_source = f"{record.relative}\0{record.size}\0{record.mtime_ns}"
    file_id = hashlib.sha256(file_id_source.encode("utf-8")).hexdigest()[:20]
    return DocumentCandidate(
        record=record,
        file_id=file_id,
        extraction=extraction,
        scores=scores,
        sensitive_signal=sensitive_signal,
        local_category=local_category,
        local_confidence=confidence,
        matched_keywords=matched_keywords,
    )


def _load_decisions(path: Path | None) -> dict[str, dict[str, object]]:
    if path is None:
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    entries = raw.get("decisions", raw if isinstance(raw, list) else [])
    if not isinstance(entries, list):
        raise ValueError("Document decisions must be a list or contain a decisions list")
    return {str(item.get("id")): item for item in entries if isinstance(item, dict) and item.get("id")}


def build_document_plan(config: Config, decisions_path: Path | None = None) -> dict[str, object]:
    settings = load_document_settings(config)
    if not settings.source_dir.is_dir():
        raise FileNotFoundError(f"Document source directory does not exist: {settings.source_dir}")
    now = datetime.now(timezone.utc).timestamp()
    run_id = "documents-" + datetime.now().strftime("%Y%m%d-%H%M%S")
    decisions = _load_decisions(decisions_path)
    actions: list[Action] = []
    review: list[dict[str, object]] = []
    warnings: list[str] = []
    occupied: set[str] = set()
    status_counts: Counter[str] = Counter()
    files = [
        path
        for path in settings.source_dir.iterdir()
        if (
            path.is_file()
            and not path.name.startswith("~$")
            and path.suffix.casefold() in DOCUMENT_SUFFIXES
        )
    ]
    candidates: list[DocumentCandidate] = []
    print(f"文档二次分类扫描: {settings.source_dir}", flush=True)
    print(f"找到 {len(files)} 个支持的文档文件", flush=True)
    for index, path in enumerate(files, start=1):
        try:
            record = _file_record(path, settings.source_dir)
            if not settled(record, config, now):
                status_counts["not_settled"] += 1
                continue
            candidate = inspect_candidate(record, settings)
            candidates.append(candidate)
            status_counts[candidate.extraction.status] += 1
        except Exception as exc:
            warnings.append(f"文档检查失败: {path.name}: {type(exc).__name__}: {str(exc)[:240]}")
        if index % 50 == 0:
            print(f"  文档进度: {index}/{len(files)}", flush=True)
    for candidate in candidates:
        category = candidate.local_category
        decision_source = "local_rules"
        confidence = candidate.local_confidence
        reason = ", ".join(candidate.matched_keywords)
        decision = decisions.get(candidate.file_id)
        if category is None and decision and not candidate.sensitive_signal:
            proposed = str(decision.get("category", ""))
            proposed_confidence = float(decision.get("confidence", 0))
            if proposed in settings.allowed_categories and proposed_confidence >= settings.llm_min_confidence:
                category = proposed
                confidence = proposed_confidence
                reason = str(decision.get("reason", "LLM decision"))[:300]
                requested_source = str(decision.get("decision_source", "llm_decision"))
                decision_source = (
                    requested_source
                    if requested_source in {"llm_decision", "manual_review_queue"}
                    else "llm_decision"
                )
        if category and category != "Documents/General":
            destination = unique_destination(config.organized / Path(category) / candidate.record.path.name, occupied)
            actions.append(
                Action(
                    kind="classify_document",
                    source=str(candidate.record.path),
                    destination=str(destination),
                    size=candidate.record.size,
                    mtime_ns=candidate.record.mtime_ns,
                    reason=f"文档二次分类到 {category}",
                    evidence={
                        "category": category,
                        "confidence": round(confidence, 4),
                        "decision_source": decision_source,
                        "matched": reason,
                        "extraction_status": candidate.extraction.status,
                    },
                )
            )
            continue
        ranked_scores = sorted(candidate.scores.items(), key=lambda item: (-item[1], item[0]))[:4]
        preview = None if candidate.sensitive_signal else _redact_preview(candidate.extraction.text, settings.preview_chars)
        review.append(
            {
                "id": candidate.file_id,
                "filename": candidate.record.path.name,
                "suffix": candidate.record.path.suffix.casefold(),
                "size": candidate.record.size,
                "extraction_status": candidate.extraction.status,
                "metadata": candidate.extraction.metadata,
                "redacted_preview": preview,
                "privacy": "local_only_sensitive_signal" if candidate.sensitive_signal else "redacted_preview",
                "top_local_scores": [{"category": category, "score": score} for category, score in ranked_scores if score],
                "allowed_categories": list(settings.allowed_categories),
                "required_confidence": settings.llm_min_confidence,
            }
        )
    counts_by_category = Counter(str(action.evidence["category"]) for action in actions)
    bytes_by_category: Counter[str] = Counter()
    for action in actions:
        bytes_by_category[str(action.evidence["category"])] += action.size
    return {
        "schema_version": PLAN_SCHEMA_VERSION,
        "safety_policy": {
            "delete_supported": False,
            "dedupe_move_scope": config.dedupe_move_scope,
            "document_source": str(settings.source_dir),
            "llm_may_move_files": False,
            "document_policy_version": 2,
            "sensitive_filename_required": True,
        },
        "plan_type": "document_semantic",
        "run_id": run_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "root": str(config.root),
        "actions": [asdict(action) for action in actions],
        "llm_review": review,
        "warnings": warnings,
        "summary": {
            "scanned_documents": len(candidates),
            "scanned_bytes": sum(candidate.record.size for candidate in candidates),
            "actions": len(actions),
            "action_bytes": sum(action.size for action in actions),
            "review": len(review),
            "warnings": len(warnings),
            "counts_by_category": dict(counts_by_category),
            "bytes_by_category": dict(bytes_by_category),
            "extraction_status": dict(status_counts),
        },
    }


def write_document_plan(config: Config, payload: dict[str, object]) -> Path:
    report_dir = config.reports_dir / str(payload["run_id"])
    report_dir.mkdir(parents=True, exist_ok=False)
    (report_dir / "plan.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    review_payload = {
        "run_id": payload["run_id"],
        "instruction": (
            "为每个非敏感项目建议一个 allowlisted category、0-1 confidence 和简短 reason。"
            "不得建议删除，不得对 privacy=local_only_sensitive_signal 的项目使用或推断正文。"
        ),
        "items": payload["llm_review"],
    }
    (report_dir / "document-review.json").write_text(
        json.dumps(review_payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    summary = payload["summary"]
    lines = [
        f"# Document semantic dry-run {payload['run_id']}",
        "",
        "> 本报告没有移动或删除任何文件。",
        "",
        f"- 扫描文档：{summary['scanned_documents']} 个 / {human_bytes(summary['scanned_bytes'])}",
        f"- 本地高置信度分类：{summary['actions']} 个 / {human_bytes(summary['action_bytes'])}",
        f"- 需要 LLM/人工确认：{summary['review']} 个",
        f"- 警告：{summary['warnings']}",
        "",
        "## 高置信度类别",
        "",
    ]
    for category, count in sorted(summary["counts_by_category"].items()):
        lines.append(
            f"- `{category}`：{count} 个 / {human_bytes(summary['bytes_by_category'].get(category, 0))}"
        )
    lines.extend(["", "## 文本提取状态", ""])
    for status, count in sorted(summary["extraction_status"].items()):
        lines.append(f"- `{status}`：{count}")
    if payload["warnings"]:
        lines.extend(["", "## 警告", ""])
        lines.extend(f"- {warning}" for warning in payload["warnings"][:100])
    (report_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (config.reports_dir / "latest-documents.json").write_text(
        json.dumps({"run_id": payload["run_id"], "report_dir": str(report_dir)}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return report_dir
