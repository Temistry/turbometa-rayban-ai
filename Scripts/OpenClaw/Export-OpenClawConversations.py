#!/usr/bin/env python3
"""Export OpenClaw Gateway session transcripts to privacy-filtered Obsidian notes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

SECRET_KEYS = re.compile(
    r"(?i)(token|password|secret|authorization|cookie|signature|nonce|device.?id|request.?id|connection.?id)"
)
BEARER = re.compile(r"(?i)\b(?:bearer|token)\s+[A-Za-z0-9._~+/=-]{12,}")
URL_CREDENTIAL = re.compile(r"(?i)(https?://)[^/@\s:]+:[^/@\s]+@")
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
UUID = re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b")
LONG_SECRET = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9_~+/=-]{40,}(?![A-Za-z0-9])")


@dataclass(frozen=True)
class SessionSource:
    agent_id: str
    session_key: str
    session_id: str
    session_file: Path
    display_name: str
    channel: str
    updated_at: int


def short_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def redact_text(text: str) -> str:
    value = BEARER.sub("[REDACTED_CREDENTIAL]", text)
    value = URL_CREDENTIAL.sub(r"\1[REDACTED]@", value)
    value = IPV4.sub("[REDACTED_IP]", value)
    value = UUID.sub("[REDACTED_ID]", value)
    value = LONG_SECRET.sub("[REDACTED_SECRET]", value)
    return value


def sanitize(value: Any, key: str = "") -> Any:
    if key and SECRET_KEYS.search(key):
        return "[REDACTED]"
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, dict):
        return {str(k): sanitize(v, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize(v) for v in value]
    return value


def safe_alias(value: str) -> str:
    cleaned = re.sub(r"[^0-9A-Za-z가-힣._-]+", "-", value).strip("-._")
    return (cleaned[:48] or "session").lower()


def iso_from_ms(value: Any) -> str:
    try:
        return datetime.fromtimestamp(float(value) / 1000, timezone.utc).astimezone().isoformat(timespec="seconds")
    except (TypeError, ValueError, OSError):
        return "unknown"


def discover_sessions(openclaw_home: Path) -> list[SessionSource]:
    sessions: list[SessionSource] = []
    for store_path in sorted(openclaw_home.glob("agents/*/sessions/sessions.json")):
        agent_id = store_path.parents[1].name
        try:
            store = json.loads(store_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"warning: cannot read session store for agent={agent_id}: {exc}", file=sys.stderr)
            continue
        if not isinstance(store, dict):
            continue
        for session_key, metadata in store.items():
            if not isinstance(metadata, dict):
                continue
            session_id = str(metadata.get("sessionId") or "")
            file_value = metadata.get("sessionFile")
            session_file = Path(file_value) if isinstance(file_value, str) else store_path.parent / f"{session_id}.jsonl"
            if not session_id or not session_file.is_file():
                continue
            display = str(metadata.get("displayName") or metadata.get("channel") or "OpenClaw")
            sessions.append(
                SessionSource(
                    agent_id=agent_id,
                    session_key=str(session_key),
                    session_id=session_id,
                    session_file=session_file,
                    display_name=display,
                    channel=str(metadata.get("channel") or metadata.get("kind") or "unknown"),
                    updated_at=int(metadata.get("updatedAt") or 0),
                )
            )
    return sessions


def load_records(path: Path) -> Iterable[dict[str, Any]]:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, start=1):
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                print(f"warning: skipped invalid JSONL record file={path.name} line={line_number}", file=sys.stderr)
                continue
            if isinstance(value, dict):
                yield value


def render_content(content: Any) -> str:
    if isinstance(content, str):
        return redact_text(content)
    if not isinstance(content, list):
        return "```json\n" + json.dumps(sanitize(content), ensure_ascii=False, indent=2) + "\n```"

    sections: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            sections.append(str(sanitize(item)))
            continue
        item_type = str(item.get("type") or "content")
        if item_type == "text":
            sections.append(redact_text(str(item.get("text") or "")))
            continue
        safe_item = sanitize(item)
        sections.append(f"**{item_type}**\n\n```json\n{json.dumps(safe_item, ensure_ascii=False, indent=2)}\n```")
    return "\n\n".join(section for section in sections if section.strip())


def render_session(source: SessionSource) -> tuple[str, int, str]:
    message_blocks: list[str] = []
    count = 0
    digest = hashlib.sha256()

    for index, record in enumerate(load_records(source.session_file)):
        if record.get("type") != "message":
            continue
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "unknown")
        timestamp = str(record.get("timestamp") or message.get("timestamp") or "unknown")
        content = render_content(message.get("content"))
        if not content.strip():
            continue
        count += 1
        identity_seed = json.dumps(
            sanitize({"index": index, "role": role, "timestamp": timestamp, "content": message.get("content")}),
            ensure_ascii=False,
            sort_keys=True,
        )
        message_hash = short_hash(identity_seed)
        digest.update(identity_seed.encode("utf-8"))
        title = {"user": "사용자", "assistant": "OpenClaw", "toolResult": "도구 결과"}.get(role, role)
        message_blocks.append(
            f"## {count}. {title}\n\n"
            f"- 시각: `{redact_text(timestamp)}`\n"
            f"- 메시지: `{message_hash}`\n\n"
            f"{content}\n"
        )

    session_hash = short_hash(f"{source.agent_id}:{source.session_key}:{source.session_id}")
    header = (
        "---\n"
        "type: openclaw-conversation\n"
        f"agent: {safe_alias(source.agent_id)}\n"
        f"channel: {safe_alias(source.channel)}\n"
        f"session_hash: {session_hash}\n"
        f"updated: {iso_from_ms(source.updated_at)}\n"
        f"message_count: {count}\n"
        "---\n\n"
        f"# OpenClaw 대화 · {redact_text(source.display_name)}\n\n"
        "> Gateway의 canonical JSONL transcript에서 생성한 장기 보관본입니다. "
        "인증정보, IP 및 내부 식별자는 자동 제거됩니다.\n\n"
    )
    return header + "\n".join(message_blocks), count, digest.hexdigest()


def atomic_write(path: Path, content: str) -> bool:
    encoded = content.encode("utf-8")
    if path.is_file() and path.read_bytes() == encoded:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(encoded)
    os.replace(temporary, path)
    return True


def export(openclaw_home: Path, vault: Path, dry_run: bool) -> dict[str, Any]:
    sessions = discover_sessions(openclaw_home)
    changed: list[dict[str, Any]] = []
    manifest: list[dict[str, Any]] = []

    for source in sessions:
        content, count, transcript_hash = render_session(source)
        session_hash = short_hash(f"{source.agent_id}:{source.session_key}:{source.session_id}")
        month = datetime.fromtimestamp(source.updated_at / 1000, timezone.utc).astimezone().strftime("%Y-%m") if source.updated_at else "unknown"
        filename = f"{safe_alias(source.display_name)}-{session_hash}.md"
        relative = Path("Inbox") / "OpenClaw" / month / "Sessions" / filename
        destination = vault / relative
        would_change = not destination.is_file() or destination.read_text(encoding="utf-8", errors="replace") != content
        if would_change:
            changed.append({"path": relative.as_posix(), "messages": count})
            if not dry_run:
                atomic_write(destination, content)
        manifest.append(
            {
                "path": relative.as_posix(),
                "sessionHash": session_hash,
                "messages": count,
                "updated": iso_from_ms(source.updated_at),
                "transcriptHash": transcript_hash,
            }
        )

    manifest.sort(key=lambda item: item["path"])
    manifest_content = json.dumps({"version": 1, "sessions": manifest}, ensure_ascii=False, indent=2) + "\n"
    manifest_path = vault / ".openclaw-sync-manifest.json"
    if not dry_run:
        atomic_write(manifest_path, manifest_content)

    return {"sessions": len(sessions), "changed": changed, "changedCount": len(changed), "manifest": str(manifest_path)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--openclaw-home", type=Path, default=Path.home() / ".openclaw")
    parser.add_argument("--vault", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.openclaw_home.is_dir():
        parser.error(f"OpenClaw home not found: {args.openclaw_home}")
    if not args.vault.is_dir():
        parser.error(f"Obsidian vault not found: {args.vault}")

    result = export(args.openclaw_home.resolve(), args.vault.resolve(), args.dry_run)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
