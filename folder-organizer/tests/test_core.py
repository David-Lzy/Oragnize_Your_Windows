from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from download_curator.core import (
    HashCache,
    apply_plan,
    build_plan,
    load_config,
    normalize_filename_family,
    parse_version,
    undo_moves,
    write_plan,
)


class DownloadCuratorTests(unittest.TestCase):
    def make_config(self, base: Path) -> Path:
        root = base / "Download"
        root.mkdir()
        (root / "分类整理" / "Documents" / "General").mkdir(parents=True)
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

[category_rules]
"Documents/General" = [".pdf", ".txt"]
"Software/Installers_Apps" = [".exe"]
''',
            encoding="utf-8",
        )
        return config

    def test_parse_version(self) -> None:
        self.assertEqual(parse_version("v1.2.3"), (1, 2, 3, 0))
        self.assertEqual(parse_version("Product 2026.001.21529 x64"), (2026, 1, 21529, 0))
        self.assertIsNone(parse_version("no-version"))
        self.assertEqual(
            normalize_filename_family("npp.8.7.1.Installer.x64"),
            normalize_filename_family("npp.8.5.5.Installer.x64"),
        )
        self.assertNotEqual(
            normalize_filename_family("GeForce_Experience_v3.28.0.417"),
            normalize_filename_family("576.02-desktop-win10-win11-64bit"),
        )

    def test_plan_duplicate_and_category_then_apply_and_undo(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            config_path = self.make_config(base)
            config = load_config(config_path)
            kept = config.organized / "Documents" / "General" / "kept.txt"
            duplicate = config.root / "duplicate.txt"
            pdf = config.root / "paper.pdf"
            kept.write_bytes(b"same-content")
            duplicate.write_bytes(b"same-content")
            pdf.write_bytes(b"pdf-content")
            old = time.time() - 10
            for path in (kept, duplicate, pdf):
                os.utime(path, (old, old))
            plan = build_plan(config)
            duplicate_actions = [action for action in plan.actions if action.kind == "archive_duplicate"]
            category_actions = [action for action in plan.actions if action.kind == "categorize"]
            self.assertEqual(len(duplicate_actions), 1)
            self.assertEqual(Path(duplicate_actions[0].source), duplicate.resolve())
            self.assertEqual(len(category_actions), 1)
            self.assertEqual(Path(category_actions[0].source), pdf.resolve())
            report_dir = write_plan(config, plan)
            rollback_path = apply_plan(config, report_dir / "plan.json", "APPLY")
            rollback = json.loads(rollback_path.read_text(encoding="utf-8"))
            self.assertEqual(len(rollback["moves"]), 2)
            self.assertFalse(duplicate.exists())
            self.assertFalse(pdf.exists())
            result_path = undo_moves(config, rollback_path, "UNDO")
            result = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertEqual(len(result["undone"]), 2)
            self.assertTrue(duplicate.exists())
            self.assertTrue(pdf.exists())

    def test_hash_cache_reuses_unchanged_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            config_path = self.make_config(base)
            config = load_config(config_path)
            file_path = config.root / "data.txt"
            file_path.write_text("data", encoding="utf-8")
            stat = file_path.stat()
            from download_curator.core import FileRecord

            record = FileRecord(file_path.resolve(), "data.txt", stat.st_size, stat.st_mtime_ns, stat.st_mtime)
            cache = HashCache(config.state_db)
            cache.put(record, "quick", "full")
            cache.commit()
            self.assertEqual(cache.get(record), ("quick", "full"))
            cache.close()

    def test_apply_and_undo_root_directory_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            config_path = self.make_config(base)
            config = load_config(config_path)
            source = config.root / "downloaded-package"
            source.mkdir()
            (source / "payload.bin").write_bytes(b"payload")
            destination = config.organized / "Software" / "downloaded-package"
            from download_curator.core import directory_snapshot

            action = {
                "kind": "categorize_directory",
                "source": str(source),
                "destination": str(destination),
                **directory_snapshot(source),
            }
            report_dir = config.reports_dir / "directory-test"
            report_dir.mkdir(parents=True)
            plan_path = report_dir / "plan.json"
            plan_path.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "safety_policy": {
                            "delete_supported": False,
                            "dedupe_move_scope": "root_files",
                        },
                        "run_id": "directory-test",
                        "root": str(config.root),
                        "actions": [action],
                    }
                ),
                encoding="utf-8",
            )
            rollback_path = apply_plan(config, plan_path, "APPLY")
            self.assertFalse(source.exists())
            self.assertTrue((destination / "payload.bin").is_file())
            result_path = undo_moves(config, rollback_path, "UNDO")
            result = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertEqual(len(result["undone"]), 1)
            self.assertTrue((source / "payload.bin").is_file())

    def test_nested_duplicates_are_reported_but_not_planned_for_move(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            config_path = self.make_config(base)
            config = load_config(config_path)
            first_dir = config.root / "package-a"
            second_dir = config.root / "package-b"
            first_dir.mkdir()
            second_dir.mkdir()
            first = first_dir / "dependency.bin"
            second = second_dir / "dependency.bin"
            first.write_bytes(b"shared dependency")
            second.write_bytes(b"shared dependency")
            old = time.time() - 10
            os.utime(first, (old, old))
            os.utime(second, (old, old))
            plan = build_plan(config)
            self.assertEqual(plan.duplicate_groups, 1)
            self.assertFalse(any(action.kind == "archive_duplicate" for action in plan.actions))

    def test_apply_rejects_obsolete_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            config_path = self.make_config(base)
            config = load_config(config_path)
            obsolete = config.project_dir / "obsolete.json"
            obsolete.write_text(
                json.dumps({"run_id": "old", "root": str(config.root), "actions": []}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "obsolete or unknown"):
                apply_plan(config, obsolete, "APPLY")


if __name__ == "__main__":
    unittest.main()
