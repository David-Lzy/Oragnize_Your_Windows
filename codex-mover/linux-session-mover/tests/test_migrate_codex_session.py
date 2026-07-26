from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = (
    PROJECT_ROOT
    / "codex-mover"
    / "linux-session-mover"
    / "scripts"
    / "migrate_codex_session.py"
)


THREADS_SCHEMA = """
CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    rollout_path TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    source TEXT NOT NULL,
    model_provider TEXT NOT NULL,
    cwd TEXT NOT NULL,
    title TEXT NOT NULL,
    sandbox_policy TEXT NOT NULL,
    approval_mode TEXT NOT NULL,
    tokens_used INTEGER NOT NULL DEFAULT 0,
    has_user_event INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    archived_at INTEGER,
    cli_version TEXT NOT NULL DEFAULT '',
    preview TEXT NOT NULL DEFAULT '',
    source_only_metadata TEXT
)
"""


TARGET_THREADS_SCHEMA = THREADS_SCHEMA.replace(
    "\n    source_only_metadata TEXT\n",
    "\n    target_only_metadata TEXT NOT NULL DEFAULT 'target-default'\n",
)


class MigrationFixture:
    def __init__(self, root: Path, *, archived: bool = False) -> None:
        self.root = root
        self.thread_id = str(uuid.uuid4())
        self.old_cwd = root / "old-project"
        self.new_cwd = root / "new-project"
        self.old_cwd.mkdir()
        self.new_cwd.mkdir()
        self.source_home = root / "source-home"
        self.target_home = root / "target-home"
        self.storage = root / "target-storage"
        self.source_home.mkdir(mode=0o700)
        self.target_home.mkdir(mode=0o700)
        self.storage.mkdir(mode=0o700)
        self.archived = archived

        physical_sessions = self.storage / "sessions"
        physical_archived = self.storage / "archived_sessions"
        physical_sessions.mkdir()
        physical_archived.mkdir()
        (self.target_home / "sessions").symlink_to(
            physical_sessions, target_is_directory=True
        )
        (self.target_home / "archived_sessions").symlink_to(
            physical_archived, target_is_directory=True
        )

        filename = f"rollout-2026-01-02T03-04-05-{self.thread_id}.jsonl"
        if archived:
            source_parent = self.source_home / "archived_sessions"
        else:
            source_parent = self.source_home / "sessions" / "2026" / "01" / "02"
        source_parent.mkdir(parents=True)
        self.source_rollout = source_parent / filename
        records = [
            {
                "timestamp": "2026-01-02T03:04:05Z",
                "type": "session_meta",
                "payload": {
                    "id": self.thread_id,
                    "cwd": str(self.old_cwd),
                    "model_provider": "openai",
                },
            },
            {
                "timestamp": "2026-01-02T03:04:06Z",
                "type": "response_item",
                "payload": {
                    "role": "user",
                    "content": (f"Keep this historical text unchanged: {self.old_cwd}"),
                },
            },
            {
                "timestamp": "2026-01-02T03:04:07Z",
                "type": "turn_context",
                "payload": {
                    "cwd": str(self.old_cwd),
                    "approval_policy": "on-request",
                },
            },
        ]
        with self.source_rollout.open("w", encoding="utf-8") as handle:
            for record in records:
                handle.write(
                    json.dumps(record, ensure_ascii=False, separators=(",", ":"))
                )
                handle.write("\n")

        self.source_database = self.source_home / "state_5.sqlite"
        self.target_database = self.target_home / "state_5.sqlite"
        self._create_database(self.source_database, THREADS_SCHEMA)
        self._create_database(self.target_database, TARGET_THREADS_SCHEMA)

        with sqlite3.connect(self.source_database) as connection:
            connection.execute(
                """
                INSERT INTO threads (
                    id, rollout_path, created_at, updated_at, source,
                    model_provider, cwd, title, sandbox_policy, approval_mode,
                    has_user_event, archived, archived_at, cli_version, preview,
                    source_only_metadata
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    self.thread_id,
                    str(self.source_rollout),
                    1767323045,
                    1767323047,
                    "app",
                    "openai",
                    str(self.old_cwd),
                    "Fixture task",
                    "workspace-write",
                    "on-request",
                    1,
                    int(archived),
                    1767323047 if archived else None,
                    "fixture",
                    "Fixture preview",
                    "source-only",
                ),
            )

        index_record = {
            "id": self.thread_id,
            "thread_name": "Fixture task name",
            "updated_at": "2026-01-02T03:04:07Z",
        }
        (self.source_home / "session_index.jsonl").write_text(
            json.dumps(index_record, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def _create_database(path: Path, schema: str) -> None:
        with sqlite3.connect(path) as connection:
            connection.executescript(schema)

    def command(self, *extra: str) -> list[str]:
        return [
            sys.executable,
            str(SCRIPT),
            "--source-home",
            str(self.source_home),
            "--target-home",
            str(self.target_home),
            "--thread-id",
            self.thread_id,
            "--destination-cwd",
            str(self.new_cwd),
            *extra,
        ]

    def run(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.command(*extra),
            cwd=PROJECT_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def target_rollout(self) -> Path:
        if self.archived:
            return self.target_home / "archived_sessions" / self.source_rollout.name
        return (
            self.target_home
            / "sessions"
            / "2026"
            / "01"
            / "02"
            / self.source_rollout.name
        )


class LinuxSessionMigrationTests(unittest.TestCase):
    def test_dry_run_does_not_modify_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            before_database = fixture.target_database.read_bytes()

            result = fixture.run()

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("DRY RUN", result.stdout)
            self.assertFalse(fixture.target_rollout().exists())
            self.assertFalse((fixture.target_home / "session_index.jsonl").exists())
            self.assertFalse((fixture.target_home / "migration-backups").exists())
            self.assertFalse(
                (fixture.target_home / ".linux-session-migration.lock").exists()
            )
            self.assertEqual(before_database, fixture.target_database.read_bytes())

    def test_apply_copies_all_indexes_and_keeps_logical_rollout_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))

            result = fixture.run("--apply", "--confirm-codex-stopped")

            self.assertEqual(result.returncode, 0, result.stderr)
            target_rollout = fixture.target_rollout()
            self.assertTrue(target_rollout.is_file())
            self.assertTrue(fixture.source_rollout.is_file())
            self.assertEqual(
                target_rollout.resolve().parent,
                (fixture.storage / "sessions" / "2026" / "01" / "02").resolve(),
            )

            with sqlite3.connect(fixture.target_database) as connection:
                connection.row_factory = sqlite3.Row
                row = connection.execute(
                    """
                    SELECT rollout_path, cwd, preview, target_only_metadata
                    FROM threads WHERE id = ?
                    """,
                    (fixture.thread_id,),
                ).fetchone()
                self.assertIsNotNone(row)
                self.assertEqual(row["rollout_path"], str(target_rollout))
                self.assertNotEqual(row["rollout_path"], str(target_rollout.resolve()))
                self.assertEqual(row["cwd"], str(fixture.new_cwd))
                self.assertEqual(row["preview"], "Fixture preview")
                self.assertEqual(row["target_only_metadata"], "target-default")

            records = [
                json.loads(line)
                for line in target_rollout.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(records[0]["payload"]["cwd"], str(fixture.new_cwd))
            self.assertEqual(records[2]["payload"]["cwd"], str(fixture.new_cwd))
            self.assertIn(str(fixture.old_cwd), records[1]["payload"]["content"])

            index_records = [
                json.loads(line)
                for line in (fixture.target_home / "session_index.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            self.assertEqual(index_records[0]["id"], fixture.thread_id)
            self.assertEqual(index_records[0]["thread_name"], "Fixture task name")

            manifests = list(
                (fixture.target_home / "migration-backups").glob(
                    f"*-{fixture.thread_id}/migration-manifest.json"
                )
            )
            self.assertEqual(len(manifests), 1)
            manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
            self.assertEqual(manifest["status"], "success")
            self.assertTrue(manifest["source_retained"])
            self.assertEqual(manifest["rollout"]["rewritten_cwd_records"], 2)
            self.assertIn(
                "source_only_metadata", manifest["source_only_sqlite_columns"]
            )

    def test_archived_rollout_uses_flat_archived_sessions_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary), archived=True)

            result = fixture.run("--apply", "--confirm-codex-stopped")

            self.assertEqual(result.returncode, 0, result.stderr)
            target_rollout = fixture.target_rollout()
            self.assertTrue(target_rollout.is_file())
            self.assertEqual(
                target_rollout.parent, fixture.target_home / "archived_sessions"
            )
            with sqlite3.connect(fixture.target_database) as connection:
                row = connection.execute(
                    "SELECT rollout_path, archived FROM threads WHERE id = ?",
                    (fixture.thread_id,),
                ).fetchone()
            self.assertEqual(row, (str(target_rollout), 1))

    def test_custom_backup_root_keeps_large_backups_off_target_home(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            backup_root = fixture.storage / "migration-backups"

            result = fixture.run(
                "--backup-root",
                str(backup_root),
                "--apply",
                "--confirm-codex-stopped",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            manifests = list(
                backup_root.glob(f"*-{fixture.thread_id}/migration-manifest.json")
            )
            self.assertEqual(len(manifests), 1)
            self.assertFalse((fixture.target_home / "migration-backups").exists())
            manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
            self.assertEqual(manifest["backup_root"], str(backup_root))

    def test_backup_root_cannot_be_inside_session_scan_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            unsafe_backup_root = fixture.target_home / "sessions" / "backups"

            result = fixture.run(
                "--backup-root",
                str(unsafe_backup_root),
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn(
                "backup root must be outside sessions and archived_sessions",
                result.stderr,
            )

    def test_existing_target_is_rejected_without_replace_flag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            first = fixture.run("--apply", "--confirm-codex-stopped")
            self.assertEqual(first.returncode, 0, first.stderr)
            original_rollout = fixture.target_rollout().read_bytes()
            original_backups = sorted(
                (fixture.target_home / "migration-backups").iterdir()
            )

            second = fixture.run("--apply", "--confirm-codex-stopped")

            self.assertEqual(second.returncode, 2)
            self.assertIn("target already contains", second.stderr)
            self.assertEqual(original_rollout, fixture.target_rollout().read_bytes())
            self.assertEqual(
                original_backups,
                sorted((fixture.target_home / "migration-backups").iterdir()),
            )

    def test_failure_after_sqlite_write_restores_target_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            target_index = fixture.target_home / "session_index.jsonl"
            invalid_index = b"{not-json}\n"
            target_index.write_bytes(invalid_index)

            result = fixture.run("--apply", "--confirm-codex-stopped")

            self.assertEqual(result.returncode, 2)
            self.assertIn("invalid JSON", result.stderr)
            self.assertFalse(fixture.target_rollout().exists())
            self.assertEqual(target_index.read_bytes(), invalid_index)
            with sqlite3.connect(fixture.target_database) as connection:
                row_count = connection.execute(
                    "SELECT count(*) FROM threads WHERE id = ?",
                    (fixture.thread_id,),
                ).fetchone()[0]
                quick_check = connection.execute("PRAGMA quick_check").fetchone()[0]
            self.assertEqual(row_count, 0)
            self.assertEqual(quick_check, "ok")

            manifests = list(
                (fixture.target_home / "migration-backups").glob(
                    f"*-{fixture.thread_id}/migration-manifest.json"
                )
            )
            self.assertEqual(len(manifests), 1)
            manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
            self.assertEqual(manifest["status"], "failed_rolled_back")
            self.assertEqual(manifest["rollback_errors"], [])

    def test_apply_requires_stopped_confirmation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))

            result = fixture.run("--apply")

            self.assertEqual(result.returncode, 2)
            self.assertIn("--confirm-codex-stopped", result.stderr)
            self.assertFalse(fixture.target_rollout().exists())

    def test_destination_cwd_must_be_absolute(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            command = fixture.command()
            destination_index = command.index("--destination-cwd") + 1
            command[destination_index] = "relative/project"

            result = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("destination cwd must be an absolute path", result.stderr)
            self.assertFalse(fixture.target_rollout().exists())

    def test_nested_session_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            redirected = fixture.root / "unexpected-storage"
            redirected.mkdir()
            (fixture.storage / "sessions" / "2026").symlink_to(
                redirected, target_is_directory=True
            )

            result = fixture.run()

            self.assertEqual(result.returncode, 2)
            self.assertIn("nested symlink found", result.stderr)
            self.assertFalse(fixture.target_rollout().exists())

    def test_source_and_target_cannot_share_same_rollout_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = MigrationFixture(Path(temporary))
            (fixture.target_home / "sessions").unlink()
            (fixture.target_home / "sessions").symlink_to(
                fixture.source_home / "sessions",
                target_is_directory=True,
            )

            result = fixture.run("--replace-existing")

            self.assertEqual(result.returncode, 2)
            self.assertIn("same physical file", result.stderr)
            self.assertTrue(fixture.source_rollout.is_file())


if __name__ == "__main__":
    unittest.main()
