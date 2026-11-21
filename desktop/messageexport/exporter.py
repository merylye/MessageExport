"""Writes conversations to CSV and JSON. Same format as the Mac app."""

from __future__ import annotations

import csv
import io
import json
import re
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable

from .contacts import ContactDirectory
from .store import Conversation, MessageStore, RawAttachment, RawMessage

REACTION_NAMES = {0: "loved", 1: "liked", 2: "disliked", 3: "laughed", 4: "emphasized", 5: "questioned", 6: "emoji", 7: "sticker"}
CSV_HEADER = ["conversation", "timestamp", "sender", "sender_handle", "is_from_me", "text",
              "attachments", "reactions", "reply_to", "edited", "service", "message_id"]


@dataclass
class ExportRequest:
    conversation: Conversation
    start: datetime | None
    end: datetime | None


@dataclass
class ExportOptions:
    write_csv: bool = True
    write_json: bool = True
    copy_attachments: bool = False


@dataclass
class ExportSummary:
    folder: Path
    conversations: int = 0
    messages: int = 0
    attachments_copied: int = 0
    attachments_missing: int = 0


def iso(value: datetime) -> str:
    return value.astimezone().isoformat(timespec="seconds")


def export(
    requests: list[ExportRequest],
    store: MessageStore,
    contacts: ContactDirectory,
    options: ExportOptions,
    parent: Path,
    now: datetime | None = None,
    progress: Callable[[float, str], None] = lambda f, m: None,
) -> ExportSummary:
    now = now or datetime.now().astimezone()
    folder = _unique_dir(Path(parent) / f"Messages Export {now.strftime('%Y-%m-%d %H%M%S')}")
    folder.mkdir(parents=True)
    summary = ExportSummary(folder=folder)
    used: set[str] = set()
    index = []

    for position, request in enumerate(requests):
        conv = request.conversation
        progress(position / max(len(requests), 1), f"Exporting {conv.title}…")
        base = _unique_name(safe_file_name(conv.title), used)
        raw_messages, raw_reactions = store.fetch_messages(conv.chat_ids, request.start, request.end)
        attachments_by_message = store.fetch_attachments(conv.chat_ids)
        reactions = collect_reactions(raw_reactions, contacts)

        messages = []
        for raw in raw_messages:
            text = clean_text(raw.text)
            attachments = []
            for n, att in enumerate(attachments_by_message.get(raw.row_id, []), start=1):
                kind = attachment_type(att)
                if not options.copy_attachments:
                    attachments.append({"type": kind})
                    continue
                original = att.transfer_name or (Path(att.stored_path).name if att.stored_path else "attachment")
                relative = f"attachments/{base}/{raw.row_id}-{n}-{safe_file_name(original)}"
                source = store.attachment_file(att)
                if source is not None and source.exists():
                    destination = folder / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    if not destination.exists():
                        shutil.copy2(source, destination)
                    summary.attachments_copied += 1
                    attachments.append({"type": kind, "filename": original, "path": relative})
                else:
                    summary.attachments_missing += 1
                    attachments.append({"type": kind, "filename": original, "missing": True})
            if not text and not attachments:
                continue

            if raw.is_from_me:
                sender = "Me"
            elif raw.handle:
                sender = contacts.name_for(raw.handle) or raw.handle
            else:
                sender = "Unknown" if conv.is_group else conv.title
            sender_handle = None if raw.is_from_me else (raw.handle or (None if conv.is_group else (conv.handles[0] if conv.handles else None)))

            message = {
                "id": raw.guid,
                "timestamp": iso(raw.date),
                "sender": sender,
                "isFromMe": raw.is_from_me,
                "text": text,
                "attachments": attachments,
                "reactions": reactions.get(raw.guid, []),
                "edited": raw.edited,
            }
            if sender_handle:
                message["senderHandle"] = sender_handle
            if raw.service:
                message["service"] = raw.service
            if raw.thread_originator_guid:
                message["replyTo"] = raw.thread_originator_guid
            messages.append(message)

        range_start = iso(request.start) if request.start else None
        range_end = iso(request.end) if request.end else None

        if options.write_json:
            doc = {
                "conversation": conv.title,
                "isGroup": conv.is_group,
                "participants": [
                    {"handle": h, **({"name": contacts.name_for(h)} if contacts.name_for(h) else {})}
                    for h in conv.handles
                ],
                "exportedAt": iso(now),
                "messageCount": len(messages),
                "messages": messages,
            }
            if range_start:
                doc["rangeStart"] = range_start
            if range_end:
                doc["rangeEnd"] = range_end
            (folder / f"{base}.json").write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")

        if options.write_csv:
            (folder / f"{base}.csv").write_text(to_csv(messages, conv.title), encoding="utf-8-sig", newline="")

        index.append({
            "conversation": conv.title, "file": base,
            "rangeStart": range_start or "all", "rangeEnd": range_end or "all",
            "messages": len(messages),
        })
        summary.conversations += 1
        summary.messages += len(messages)

    (folder / "export-summary.json").write_text(json.dumps({
        "exportedAt": iso(now),
        "attachments": "copied" if options.copy_attachments else "type only",
        "conversations": index,
    }, indent=2, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    progress(1.0, "Done")
    return summary


def collect_reactions(raw: list[RawMessage], contacts: ContactDirectory) -> dict[str, list[dict]]:
    """Applies tapbacks in time order, honoring removals (types 3000+)."""
    state: dict[str, list[tuple[str, dict]]] = {}
    for m in sorted(raw, key=lambda r: r.date):
        if not m.associated_guid:
            continue
        target = target_guid(m.associated_guid)
        sender = "Me" if m.is_from_me else (contacts.name_for(m.handle) or m.handle or "Unknown")
        t = m.associated_type
        if 2000 <= t <= 2007:
            kind = t - 2000
            name = REACTION_NAMES.get(kind, "reacted")
            if kind == 6 and m.emoji:
                name = m.emoji
            key = f"{sender}|{kind}"
            entries = [e for e in state.get(target, []) if e[0] != key]
            entries.append((key, {"sender": sender, "reaction": name}))
            state[target] = entries
        elif 3000 <= t <= 3007:
            key = f"{sender}|{t - 3000}"
            state[target] = [e for e in state.get(target, []) if e[0] != key]
    return {k: [e[1] for e in v] for k, v in state.items()}


def target_guid(raw: str) -> str:
    """associated_message_guid looks like 'p:0/GUID' or 'bp:GUID'."""
    if raw.startswith("bp:"):
        return raw[3:]
    if "/" in raw:
        return raw.split("/", 1)[1]
    return raw


def clean_text(text: str) -> str:
    return text.replace("￼", "").replace("�", "").strip()


def attachment_type(att: RawAttachment) -> str:
    if att.mime_type:
        return att.mime_type
    name = att.transfer_name or att.stored_path or ""
    ext = Path(name).suffix.lstrip(".").lower()
    if ext:
        return ext
    return att.uti or "unknown"


def to_csv(messages: list[dict], conversation: str) -> str:
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\r\n")
    writer.writerow(CSV_HEADER)
    for m in messages:
        attachments = [
            a.get("path") or (f"{a['filename']} (missing)" if a.get("filename") else a["type"])
            for a in m["attachments"]
        ]
        writer.writerow([
            conversation, m["timestamp"], m["sender"], m.get("senderHandle", ""), "1" if m["isFromMe"] else "0",
            m["text"], "; ".join(attachments),
            "; ".join(f"{r['sender']}: {r['reaction']}" for r in m["reactions"]),
            m.get("replyTo", ""), "1" if m["edited"] else "0", m.get("service", ""), m["id"],
        ])
    return out.getvalue()


def safe_file_name(name: str) -> str:
    cleaned = re.sub(r'[/\\:*?"<>|\n\r\t]', "_", name).strip()
    if cleaned.startswith("."):
        cleaned = "_" + cleaned[1:]
    cleaned = cleaned.rstrip(". ")  # Windows dislikes trailing dots/spaces
    return (cleaned or "conversation")[:100]


def _unique_name(base: str, used: set[str]) -> str:
    name, n = base, 2
    while name.lower() in used:
        name = f"{base} ({n})"
        n += 1
    used.add(name.lower())
    return name


def _unique_dir(path: Path) -> Path:
    candidate, n = path, 2
    while candidate.exists():
        candidate = path.with_name(f"{path.name} ({n})")
        n += 1
    return candidate
