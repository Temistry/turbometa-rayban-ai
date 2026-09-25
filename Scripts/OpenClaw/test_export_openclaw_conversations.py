import importlib.util
import json
import tempfile
import unittest
import sys
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("Export-OpenClawConversations.py")
SPEC = importlib.util.spec_from_file_location("openclaw_exporter", MODULE_PATH)
EXPORTER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = EXPORTER
SPEC.loader.exec_module(EXPORTER)


class ExportOpenClawConversationsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.home = self.root / ".openclaw"
        self.vault = self.root / "vault"
        sessions = self.home / "agents" / "main" / "sessions"
        sessions.mkdir(parents=True)
        self.vault.mkdir()

        session_id = "11111111-1111-4111-8111-111111111111"
        transcript = sessions / f"{session_id}.jsonl"
        records = [
            {"type": "session", "id": session_id},
            {
                "type": "message",
                "timestamp": "2026-08-18T01:00:00Z",
                "message": {"role": "user", "content": [{"type": "text", "text": "서버 100.64.1.2 token abcdefghijklmnopqrstuvwxyz123456"}]},
            },
            {
                "type": "message",
                "timestamp": "2026-08-18T01:00:01Z",
                "message": {"role": "assistant", "content": [{"type": "text", "text": "전체 답변입니다."}]},
            },
        ]
        transcript.write_text("\n".join(json.dumps(item, ensure_ascii=False) for item in records), encoding="utf-8")
        store = {
            "agent:main:test": {
                "sessionId": session_id,
                "sessionFile": str(transcript),
                "updatedAt": 1787014800000,
                "displayName": "private session",
                "channel": "test",
            }
        }
        (sessions / "sessions.json").write_text(json.dumps(store), encoding="utf-8")

    def tearDown(self):
        self.temporary.cleanup()

    def test_export_redacts_secrets_and_is_idempotent(self):
        first = EXPORTER.export(self.home, self.vault, dry_run=False)
        self.assertEqual(first["changedCount"], 1)
        note = next((self.vault / "Inbox" / "OpenClaw").rglob("*.md"))
        content = note.read_text(encoding="utf-8")
        self.assertNotIn("100.64.1.2", content)
        self.assertNotIn("abcdefghijklmnopqrstuvwxyz123456", content)
        self.assertNotIn("11111111-1111-4111-8111-111111111111", content)
        self.assertIn("전체 답변입니다.", content)

        second = EXPORTER.export(self.home, self.vault, dry_run=False)
        self.assertEqual(second["changedCount"], 0)

    def test_dry_run_writes_nothing(self):
        result = EXPORTER.export(self.home, self.vault, dry_run=True)
        self.assertEqual(result["changedCount"], 1)
        self.assertFalse((self.vault / "Inbox").exists())


if __name__ == "__main__":
    unittest.main()
