from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from download_curator.core import load_config
from download_curator.indexer import build_index, index_stats, search_index


class DownloadIndexTests(unittest.TestCase):
    def test_incremental_index_and_content_search(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "Download"
            document_dir = root / "分类整理" / "Work" / "Contracts_Legal"
            document_dir.mkdir(parents=True)
            archive = root / "Archive"
            archive.mkdir()
            document = document_dir / "agency-agreement.txt"
            document.write_text("Alpha procurement agreement for wind equipment", encoding="utf-8")
            config_path = base / "config.toml"
            root_text = str(root).replace("\\", "\\\\")
            config_path.write_text(
                f'''root = "{root_text}"
archive_dir = "Archive"
organized_dir = "分类整理"
settle_hours = 0
quick_hash_bytes = 16
dedupe_move_scope = "root_files"

[index_settings]
database = ".state/test-index.sqlite3"

[document_settings]
source_dir = "Documents/General"
max_extract_mb = 2
pdf_pages = 1
''',
                encoding="utf-8",
            )
            config = load_config(config_path)
            first = build_index(config)
            self.assertEqual(first["scanned"], 1)
            self.assertEqual(first["added"], 1)
            result = search_index(config, "Alpha agreement")
            self.assertEqual(result["matches"], 1)
            self.assertEqual(result["results"][0]["path"], str(document))
            second = build_index(config)
            self.assertEqual(second["unchanged"], 1)
            document.unlink()
            third = build_index(config)
            self.assertEqual(third["removed"], 1)
            self.assertEqual(index_stats(config)["files"], 0)


if __name__ == "__main__":
    unittest.main()
