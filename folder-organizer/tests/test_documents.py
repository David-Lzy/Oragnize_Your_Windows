from __future__ import annotations

import os
import tempfile
import time
import unittest
from pathlib import Path

from download_curator.core import apply_plan, load_config, undo_moves
from download_curator.documents import build_document_plan, write_document_plan


class DocumentLayerTests(unittest.TestCase):
    def make_config(self, base: Path) -> Path:
        root = base / "Download"
        source = root / "分类整理" / "Documents" / "General"
        source.mkdir(parents=True)
        project = base / "project"
        project.mkdir()
        config = project / "config.toml"
        root_text = str(root).replace("\\", "\\\\")
        config.write_text(
            f'''root = "{root_text}"
archive_dir = "Archive"
organized_dir = "分类整理"
settle_hours = 0
quick_hash_bytes = 16
dedupe_move_scope = "root_files"

[category_rules]
"Documents/General" = [".txt", ".html"]

[document_settings]
source_dir = "Documents/General"
preview_chars = 200
max_extract_mb = 2
pdf_pages = 1
min_score = 4
min_margin = 2
llm_min_confidence = 0.90
allowed_categories = ["Work/Finance_Invoices", "Study/Papers_Courses", "Personal/Web_Exports", "Sensitive/Keys"]

[document_categories."Sensitive/Keys"]
local_only = true
keywords = ["password", "private key"]

[document_categories."Work/Finance_Invoices"]
keywords = ["invoice", "receipt"]

[document_categories."Study/Papers_Courses"]
keywords = ["lecture", "course"]

[document_categories."Personal/Web_Exports"]
keywords = ["web archive"]
''',
            encoding="utf-8",
        )
        return config

    def test_document_plan_privacy_apply_and_undo(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            config_path = self.make_config(base)
            config = load_config(config_path)
            source = config.organized / "Documents" / "General"
            files = {
                "invoice-2026.txt": "Tax invoice and receipt",
                "lecture-notes.txt": "Course lecture notes",
                "saved-page.html": "<html><body>ordinary saved page</body></html>",
                "notes.txt": "ordinary notes without a strong category",
                "manual-note.txt": "This manual mentions password once.",
                "passwords.txt": "password inventory",
            }
            old = time.time() - 10
            for name, content in files.items():
                path = source / name
                path.write_text(content, encoding="utf-8")
                os.utime(path, (old, old))
            lock_file = source / "~$open-document.docx"
            lock_file.write_bytes(b"temporary office lock")
            os.utime(lock_file, (old, old))
            payload = build_document_plan(config)
            self.assertEqual(payload["summary"]["scanned_documents"], len(files))
            self.assertFalse(any(action["source"].endswith(lock_file.name) for action in payload["actions"]))
            self.assertFalse(any(item["filename"] == lock_file.name for item in payload["llm_review"]))
            categories = {action["evidence"]["category"] for action in payload["actions"]}
            self.assertIn("Work/Finance_Invoices", categories)
            self.assertIn("Study/Papers_Courses", categories)
            self.assertIn("Personal/Web_Exports", categories)
            self.assertIn("Sensitive/Keys", categories)
            by_name = {item["filename"]: item for item in payload["llm_review"]}
            self.assertIn("notes.txt", by_name)
            self.assertEqual(by_name["manual-note.txt"]["privacy"], "local_only_sensitive_signal")
            self.assertIsNone(by_name["manual-note.txt"]["redacted_preview"])
            report_dir = write_document_plan(config, payload)
            rollback_path = apply_plan(config, report_dir / "plan.json", "APPLY")
            self.assertFalse((source / "invoice-2026.txt").exists())
            undo_moves(config, rollback_path, "UNDO")
            self.assertTrue((source / "invoice-2026.txt").exists())


if __name__ == "__main__":
    unittest.main()
