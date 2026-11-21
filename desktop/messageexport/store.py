"""Reads conversations and messages from a Messages database.

chat.db on a Mac and sms.db inside an iPhone backup share the same schema.
"""

from __future__ import annotations

import os
import re
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import backups
from .attributed_body import decode_attributed_body

APPLE_EPOCH_OFFSET = 978_307_200  # seconds between 1970-01-01 and 2001-01-01


class NeedsFullDiskAccess(Exception):
    """macOS blocked access to the Messages database."""


class SourceNotFound(Exception):
    pass


def apple_to_datetime(raw: int) -> datetime:
    # Since macOS 10.13 / iOS 11 the value is nanoseconds; before that, seconds.
    seconds = raw / 1_000_000_000 if raw > 1_000_000_000_000 else raw
    return datetime.fromtimestamp(seconds + APPLE_EPOCH_OFFSET, tz=timezone.utc)


def datetime_to_apple(value: datetime, nanoseconds: bool) -> int:
    seconds = value.timestamp() - APPLE_EPOCH_OFFSET
    return int(seconds * 1_000_000_000) if nanoseconds else int(seconds)


def handle_key(handle: str) -> str:
    """Turns '+1 (412) 555-1234' and '4125551234' into the same key; lowercases emails."""
    handle = handle.strip()
    if "@" in handle:
        return handle.lower()
    digits = re.sub(r"\D", "", handle)
    if not digits:
        return handle.lower()
    return digits[-10:] if len(digits) > 10 else digits


@dataclass
class Conversation:
    id: str
    chat_ids: list[int]
    group_name: str | None
    handles: list[str]
    is_group: bool
    message_count: int
    first_date: datetime | None
    last_date: datetime | None
    services: list[str] = field(default_factory=list)
    names: dict[str, str] = field(default_factory=dict)

    def name_for(self, handle: str) -> str:
        return self.names.get(handle, handle)

    @property
    def title(self) -> str:
        if self.group_name:
            return self.group_name
        if not self.handles:
            return "Unknown"
        return ", ".join(self.name_for(h) for h in self.handles)

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "title": self.title,
            "handles": self.handles,
            "isGroup": self.is_group,
            "messageCount": self.message_count,
            "firstDate": self.first_date.isoformat() if self.first_date else None,
            "lastDate": self.last_date.isoformat() if self.last_date else None,
        }


@dataclass
class RawMessage:
    row_id: int
    guid: str
    text: str
    date: datetime
    is_from_me: bool
    handle: str | None
    service: str | None
    associated_type: int
    associated_guid: str | None
    thread_originator_guid: str | None
    edited: bool
    emoji: str | None
    item_type: int


@dataclass
class RawAttachment:
    stored_path: str | None
    mime_type: str | None
    uti: str | None
    transfer_name: str | None


class MessageStore:
    def __init__(self, db_path: Path, source: dict, home: Path | None = None, temp_dir: str | None = None):
        self.source = source
        self.home = home or Path.home()
        self._temp_dir = temp_dir
        uri = f"file:{db_path.as_posix()}?mode=ro" if temp_dir is None else f"file:{db_path.as_posix()}"
        self.db = sqlite3.connect(uri, uri=True, check_same_thread=False)
        self.message_columns = self._columns("message")
        self.attachment_columns = self._columns("attachment")
        self.chat_columns = self._columns("chat")
        if not self.message_columns or not self._table_exists("chat_message_join"):
            raise SourceNotFound("This file doesn't look like a Messages database.")
        max_date = self.db.execute("SELECT MAX(date) FROM message").fetchone()[0] or 0
        self.uses_nanoseconds = max_date > 1_000_000_000_000

    # ---- opening ----

    @classmethod
    def open(cls, source: dict, home: Path | None = None) -> "MessageStore":
        """source is {"kind": "mac"} or {"kind": "backup", "path": "..."}."""
        home = home or Path.home()
        if source["kind"] == "mac":
            live = home / "Library" / "Messages" / "chat.db"
            _check_readable(live)
            temp = tempfile.mkdtemp(prefix="DownloadMyMessages-")
            for suffix in ("", "-wal", "-shm"):
                src = Path(str(live) + suffix)
                if src.exists():
                    shutil.copy2(src, Path(temp) / ("chat.db" + suffix))
            return cls(Path(temp) / "chat.db", source, home, temp_dir=temp)

        backup_dir = Path(source["path"])
        info = backups.backup_info(backup_dir)
        if info and info["isEncrypted"]:
            raise backups.EncryptedBackup()
        db_path = backups.messages_database(backup_dir)
        if not db_path.exists():
            raise SourceNotFound("This backup doesn't contain a Messages database.")
        _check_readable(db_path)
        return cls(db_path, source, home)

    def close(self) -> None:
        self.db.close()
        if self._temp_dir:
            shutil.rmtree(self._temp_dir, ignore_errors=True)

    # ---- helpers ----

    def _table_exists(self, table: str) -> bool:
        return self.db.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ).fetchone() is not None

    def _columns(self, table: str) -> set[str]:
        return {row[1] for row in self.db.execute(f"PRAGMA table_info({table})")}

    def _mcol(self, name: str, fallback: str = "NULL") -> str:
        return f"m.{name}" if name in self.message_columns else fallback

    @property
    def _visible_filter(self) -> str:
        return f"{self._mcol('associated_message_type', '0')} = 0 AND {self._mcol('item_type', '0')} = 0"

    # ---- conversations ----

    def load_conversations(self) -> list[Conversation]:
        handles = {row_id: hid for row_id, hid in self.db.execute("SELECT ROWID, id FROM handle") if hid}

        chat_handles: dict[int, list[str]] = {}
        if self._table_exists("chat_handle_join"):
            for chat_id, handle_id in self.db.execute(
                "SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id, handle_id"
            ):
                if handle_id in handles:
                    chat_handles.setdefault(chat_id, []).append(handles[handle_id])

        stats = {
            chat_id: (count, first, last)
            for chat_id, count, first, last in self.db.execute(f"""
                SELECT cmj.chat_id, COUNT(*), MIN(m.date), MAX(m.date)
                FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
                WHERE {self._visible_filter}
                GROUP BY cmj.chat_id
            """)
        }

        style = "style" if "style" in self.chat_columns else "0"
        service = "service_name" if "service_name" in self.chat_columns else "NULL"
        name = "display_name" if "display_name" in self.chat_columns else "NULL"

        merged: dict[str, Conversation] = {}
        for chat_id, identifier, group_name, service_name, chat_style in self.db.execute(
            f"SELECT ROWID, chat_identifier, {name}, {service}, {style} FROM chat"
        ):
            stat = stats.get(chat_id)
            if not stat or stat[0] == 0:
                continue
            group_name = group_name or None
            people: list[str] = []
            seen: set[str] = set()
            for h in chat_handles.get(chat_id, []):
                k = handle_key(h)
                if k not in seen:
                    seen.add(k)
                    people.append(h)
            if not people:
                people = [identifier or "Unknown"]
            is_group = len(people) > 1 or chat_style == 43

            if is_group:
                key = "group:" + ",".join(sorted(handle_key(p) for p in people)) + "|" + (group_name or "")
            else:
                key = "person:" + handle_key(people[0])

            first, last = apple_to_datetime(stat[1]), apple_to_datetime(stat[2])
            if key in merged:
                c = merged[key]
                c.chat_ids.append(chat_id)
                c.message_count += stat[0]
                c.first_date = min(c.first_date, first) if c.first_date else first
                c.last_date = max(c.last_date, last) if c.last_date else last
                if service_name and service_name not in c.services:
                    c.services.append(service_name)
                c.group_name = c.group_name or group_name
            else:
                merged[key] = Conversation(
                    id=key, chat_ids=[chat_id], group_name=group_name, handles=people, is_group=is_group,
                    message_count=stat[0], first_date=first, last_date=last,
                    services=[service_name] if service_name else [],
                )

        return sorted(merged.values(), key=lambda c: c.last_date or datetime.min.replace(tzinfo=timezone.utc), reverse=True)

    # ---- messages ----

    def fetch_messages(self, chat_ids: list[int], start: datetime | None, end: datetime | None):
        """Visible messages in [start, end], plus every tapback on or after start."""
        if not chat_ids:
            return [], []
        ids = ",".join(str(int(i)) for i in chat_ids)
        params: list = []
        date_filter = ""
        if start is not None:
            date_filter = "AND m.date >= ?"
            params.append(datetime_to_apple(start, self.uses_nanoseconds))
        sql = f"""
            SELECT m.ROWID, m.guid, m.text, {self._mcol('attributedBody')}, m.date, m.is_from_me, h.id,
                   {self._mcol('service')}, {self._mcol('associated_message_type', '0')},
                   {self._mcol('associated_message_guid')}, {self._mcol('thread_originator_guid')},
                   {self._mcol('date_edited', '0')}, {self._mcol('associated_message_emoji')},
                   {self._mcol('item_type', '0')}
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN ({ids}) {date_filter}
            ORDER BY m.date, m.ROWID
        """
        seen: set[int] = set()
        messages: list[RawMessage] = []
        reactions: list[RawMessage] = []
        for row in self.db.execute(sql, params):
            row_id = row[0]
            if row_id in seen:
                continue
            seen.add(row_id)
            text = row[2] or ""
            if not text.strip() and row[3]:
                text = decode_attributed_body(bytes(row[3])) or ""
            msg = RawMessage(
                row_id=row_id, guid=row[1] or str(row_id), text=text, date=apple_to_datetime(row[4] or 0),
                is_from_me=bool(row[5]), handle=row[6], service=row[7], associated_type=row[8] or 0,
                associated_guid=row[9], thread_originator_guid=row[10], edited=bool(row[11]),
                emoji=row[12], item_type=row[13] or 0,
            )
            if msg.associated_type != 0:
                reactions.append(msg)
            elif msg.item_type == 0:
                if end is not None and msg.date > end:
                    continue
                messages.append(msg)
        return messages, reactions

    def fetch_attachments(self, chat_ids: list[int]) -> dict[int, list[RawAttachment]]:
        if not chat_ids or not self.attachment_columns or not self._table_exists("message_attachment_join"):
            return {}
        ids = ",".join(str(int(i)) for i in chat_ids)

        def col(name: str) -> str:
            return f"a.{name}" if name in self.attachment_columns else "NULL"

        result: dict[int, list[RawAttachment]] = {}
        seen: set[tuple[int, int]] = set()
        for message_id, attachment_id, filename, mime, uti, transfer in self.db.execute(f"""
            SELECT maj.message_id, maj.attachment_id, {col('filename')}, {col('mime_type')}, {col('uti')}, {col('transfer_name')}
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            JOIN chat_message_join cmj ON cmj.message_id = maj.message_id
            WHERE cmj.chat_id IN ({ids})
            ORDER BY maj.message_id, maj.attachment_id
        """):
            if (message_id, attachment_id) in seen:
                continue
            seen.add((message_id, attachment_id))
            result.setdefault(message_id, []).append(RawAttachment(filename, mime, uti, transfer))
        return result

    def attachment_file(self, attachment: RawAttachment) -> Path | None:
        stored = attachment.stored_path
        if not stored:
            return None
        if self.source["kind"] == "mac":
            if stored.startswith("~/"):
                return self.home / stored[2:]
            return Path(stored)
        return backups.attachment_file(Path(self.source["path"]), stored)


def _check_readable(path: Path) -> None:
    if not path.exists():
        parent = path.parent
        if parent.exists():
            try:
                os.listdir(parent)
            except PermissionError:
                raise NeedsFullDiskAccess()
        raise SourceNotFound(f"No Messages database was found at {path}.")
    try:
        with open(path, "rb"):
            pass
    except PermissionError:
        raise NeedsFullDiskAccess()
