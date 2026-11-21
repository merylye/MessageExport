import csv
import hashlib
import json
import plistlib
import sqlite3
import threading
import urllib.request
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

from messageexport import app, backups, contacts
from messageexport.attributed_body import decode_attributed_body
from messageexport.exporter import ExportOptions, ExportRequest, export
from messageexport.store import MessageStore, NeedsFullDiskAccess

SCHEMA = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT, style INTEGER);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER,
    date INTEGER, is_from_me INTEGER, service TEXT, associated_message_type INTEGER DEFAULT 0,
    associated_message_guid TEXT, thread_originator_guid TEXT, date_edited INTEGER DEFAULT 0,
    associated_message_emoji TEXT, item_type INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0);
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, transfer_name TEXT);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
INSERT INTO handle VALUES (1, '+14125551234', 'iMessage'), (2, '4125551234', 'SMS'), (3, 'friend@example.com', 'iMessage');
INSERT INTO chat VALUES (1, 'iMessage;-;+14125551234', '+14125551234', '', 'iMessage', 45),
                        (2, 'SMS;-;4125551234', '4125551234', '', 'SMS', 45),
                        (3, 'iMessage;+;chat123', 'chat123', 'Trip Planning', 'iMessage', 43);
INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (3, 1), (3, 3);
INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1),(1,2),(2,3),(2,4),(1,5),(1,6),(1,7),(3,8),(3,9),(3,10);
INSERT INTO message_attachment_join VALUES (4, 1);
"""


def attributed_body(text: str) -> bytes:
    b = bytes([0x04, 0x0B]) + b"streamtyped" + bytes([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84])
    b += bytes([0x12]) + b"NSAttributedString" + bytes([0x00, 0x84, 0x84, 0x08]) + b"NSObject"
    b += bytes([0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]) + b"NSString" + bytes([0x01, 0x94, 0x84, 0x01, 0x2B])
    data = text.encode()
    b += bytes([len(data)]) if len(data) < 0x80 else bytes([0x81]) + len(data).to_bytes(2, "little")
    return b + data + bytes([0x86, 0x84, 0x02, 0x69, 0x49, 0x01])


def nanos(iso: str) -> int:
    return int((datetime.fromisoformat(iso).timestamp() - 978_307_200) * 1_000_000_000)


MESSAGES = [
    (1, "G1", "Hey, are you free Saturday?", None, 1, "2024-01-10T15:00:00+00:00", 0, "iMessage", 0, None, None, 0),
    (2, "G2", None, attributed_body("Yes! Brunch?"), 1, "2024-01-10T15:05:00+00:00", 1, "iMessage", 0, None, None, 0),
    (3, "G3", 'Sounds good, "Cafe", 11am', None, 2, "2024-06-01T12:00:00+00:00", 0, "SMS", 0, None, None, 0),
    (4, "G4", "￼", None, 2, "2024-06-02T12:00:00+00:00", 1, "SMS", 0, None, None, 0),
    (5, "R1", "Loved", None, 1, "2025-03-01T00:00:00+00:00", 0, "iMessage", 2000, "p:0/G2", None, 0),
    (6, "R2", "Liked", None, 1, "2024-01-10T16:00:00+00:00", 1, "iMessage", 2001, "p:0/G1", None, 0),
    (7, "R3", "Removed", None, 1, "2024-01-10T16:01:00+00:00", 1, "iMessage", 3001, "p:0/G1", None, 0),
    (8, "G5", "Group hello", None, 3, "2024-02-01T10:00:00+00:00", 0, "iMessage", 0, None, None, 0),
    (9, "G6", "Replying in thread", None, 1, "2024-02-01T10:05:00+00:00", 0, "iMessage", 0, None, "G5", 0),
    (10, "G7", None, None, 0, "2024-02-01T10:06:00+00:00", 1, "iMessage", 0, None, None, 2),
]


def build_db(path: Path, attachment_path: str) -> None:
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    for m in MESSAGES:
        db.execute(
            "INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, service,"
            " associated_message_type, associated_message_guid, thread_originator_guid, item_type)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (m[0], m[1], m[2], m[3], m[4], nanos(m[5]), m[6], m[7], m[8], m[9], m[10], m[11]),
        )
    db.execute("INSERT INTO attachment VALUES (1, 'A1', ?, 'image/jpeg', 'public.jpeg', 'IMG_0001.jpeg')", (attachment_path,))
    db.commit()
    db.close()


@pytest.fixture
def mac_home(tmp_path):
    home = tmp_path / "home"
    messages = home / "Library" / "Messages"
    messages.mkdir(parents=True)
    build_db(messages / "chat.db", "~/Library/Messages/Attachments/ab/01/A1/IMG_0001.jpeg")
    att = messages / "Attachments" / "ab" / "01" / "A1" / "IMG_0001.jpeg"
    att.parent.mkdir(parents=True)
    att.write_bytes(b"fake jpeg")
    return home


def sha1(s: str) -> str:
    return hashlib.sha1(s.encode()).hexdigest()


@pytest.fixture
def backup_dir(tmp_path):
    backup = tmp_path / "Backup" / "00008110-001234"
    backup.mkdir(parents=True)
    with open(backup / "Info.plist", "wb") as f:
        plistlib.dump({"Device Name": "Test iPhone", "Last Backup Date": datetime(2026, 11, 1)}, f)
    with open(backup / "Manifest.plist", "wb") as f:
        plistlib.dump({"IsEncrypted": False}, f)
    (backup / "Manifest.db").write_bytes(b"")

    sms_id = sha1("HomeDomain-Library/SMS/sms.db")
    (backup / sms_id[:2]).mkdir()
    build_db(backup / sms_id[:2] / sms_id, "~/Library/SMS/Attachments/ab/01/A1/IMG_0001.jpeg")

    att_id = sha1("MediaDomain-Library/SMS/Attachments/ab/01/A1/IMG_0001.jpeg")
    (backup / att_id[:2]).mkdir(exist_ok=True)
    (backup / att_id[:2] / att_id).write_bytes(b"fake jpeg from backup")

    ab_id = sha1("HomeDomain-Library/AddressBook/AddressBook.sqlitedb")
    (backup / ab_id[:2]).mkdir(exist_ok=True)
    ab = sqlite3.connect(backup / ab_id[:2] / ab_id)
    ab.executescript("""
        CREATE TABLE ABPerson (ROWID INTEGER PRIMARY KEY, First TEXT, Last TEXT, Organization TEXT);
        CREATE TABLE ABMultiValue (record_id INTEGER, property INTEGER, value TEXT);
        INSERT INTO ABPerson VALUES (1, 'Alex', 'Kim', NULL), (2, NULL, NULL, 'Travel Buddy Inc');
        INSERT INTO ABMultiValue VALUES (1, 3, '(412) 555-1234'), (2, 4, 'Friend@Example.com');
    """)
    ab.commit()
    ab.close()
    return backup


def load_json(folder: Path, name: str) -> dict:
    return json.loads((folder / f"{name}.json").read_text(encoding="utf-8"))


def test_attributed_body():
    assert decode_attributed_body(attributed_body("hello there")) == "hello there"
    long = "long message 🎉 " * 40
    assert decode_attributed_body(attributed_body(long)) == long
    assert decode_attributed_body(b"\x01\x02\x03") is None


def test_mac_conversations_and_export(mac_home, tmp_path):
    store = MessageStore.open({"kind": "mac"}, home=mac_home)
    directory = contacts.ContactDirectory()
    directory.add("Alex Kim", ["(412) 555-1234"])
    convs = store.load_conversations()
    for c in convs:
        c.names = {h: directory.name_for(h) for h in c.handles if directory.name_for(h)}

    assert len(convs) == 2, "iMessage and SMS chats with the same person merge"
    alex = next(c for c in convs if not c.is_group)
    group = next(c for c in convs if c.is_group)
    assert alex.title == "Alex Kim"
    assert alex.message_count == 4
    assert group.title == "Trip Planning" and group.message_count == 2

    out = tmp_path / "out"
    out.mkdir()
    summary = export(
        [ExportRequest(alex, None, None),
         ExportRequest(group, datetime(2024, 2, 1, 10, 3, tzinfo=timezone.utc), datetime(2024, 2, 2, tzinfo=timezone.utc))],
        store, directory, ExportOptions(copy_attachments=True), out,
    )
    assert (summary.conversations, summary.messages, summary.attachments_copied) == (2, 5, 1)

    doc = load_json(summary.folder, "Alex Kim")
    assert [m["text"] for m in doc["messages"]] == [
        "Hey, are you free Saturday?", "Yes! Brunch?", 'Sounds good, "Cafe", 11am', ""]
    assert doc["messages"][1]["reactions"] == [{"sender": "Alex Kim", "reaction": "loved"}]
    assert doc["messages"][0]["reactions"] == []
    assert doc["messages"][0]["sender"] == "Alex Kim" and doc["messages"][1]["sender"] == "Me"
    path = doc["messages"][3]["attachments"][0]["path"]
    assert path.startswith("attachments/Alex Kim/")
    assert (summary.folder / path).read_bytes() == b"fake jpeg"

    gdoc = load_json(summary.folder, "Trip Planning")
    assert len(gdoc["messages"]) == 1 and gdoc["messages"][0]["replyTo"] == "G5"

    raw = (summary.folder / "Alex Kim.csv").read_bytes()
    assert raw.startswith(b"\xef\xbb\xbf"), "CSV has a byte-order mark for Excel"
    with open(summary.folder / "Alex Kim.csv", encoding="utf-8-sig", newline="") as f:
        table = list(csv.DictReader(f))
    assert table[2]["text"] == 'Sounds good, "Cafe", 11am'
    assert table[1]["reactions"] == "Alex Kim: loved"

    index = json.loads((summary.folder / "export-summary.json").read_text())
    assert [c["messages"] for c in index["conversations"]] == [4, 1]
    store.close()


def test_type_only_attachments(mac_home, tmp_path):
    store = MessageStore.open({"kind": "mac"}, home=mac_home)
    alex = next(c for c in store.load_conversations() if not c.is_group)
    summary = export([ExportRequest(alex, None, None)], store, contacts.ContactDirectory(),
                     ExportOptions(copy_attachments=False), tmp_path)
    doc = load_json(summary.folder, alex.title)
    assert doc["messages"][3]["attachments"] == [{"type": "image/jpeg"}]
    assert not (summary.folder / "attachments").exists()
    store.close()


def test_backup_source(backup_dir, tmp_path):
    info = backups.backup_info(backup_dir)
    assert info["deviceName"] == "Test iPhone" and not info["isEncrypted"]
    store = MessageStore.open({"kind": "backup", "path": str(backup_dir)})
    directory = contacts.from_backup(backup_dir)
    assert directory.name_for("+1 412-555-1234") == "Alex Kim"
    assert directory.name_for("friend@example.com") == "Travel Buddy Inc"

    convs = store.load_conversations()
    alex = next(c for c in convs if not c.is_group)
    summary = export([ExportRequest(alex, None, None)], store, directory, ExportOptions(copy_attachments=True), tmp_path)
    doc = load_json(summary.folder, "+14125551234")
    att = doc["messages"][3]["attachments"][0]
    assert (summary.folder / att["path"]).read_bytes() == b"fake jpeg from backup"
    store.close()


def test_encrypted_backup_is_rejected(backup_dir):
    with open(backup_dir / "Manifest.plist", "wb") as f:
        plistlib.dump({"IsEncrypted": True}, f)
    with pytest.raises(backups.EncryptedBackup):
        MessageStore.open({"kind": "backup", "path": str(backup_dir)})


def test_permission_denied_reports_full_disk_access(tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / "Library" / "Messages").mkdir(parents=True)
    (home / "Library" / "Messages" / "chat.db").write_bytes(b"")

    real_open = open

    def deny(path, *args, **kwargs):
        if str(path).endswith("chat.db"):
            raise PermissionError("Operation not permitted")
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr("builtins.open", deny)
    with pytest.raises(NeedsFullDiskAccess):
        MessageStore.open({"kind": "mac"}, home=home)


def test_server_requires_token_and_exports(backup_dir, tmp_path):
    state = app.AppState(app.MainThreadRunner())
    server = ThreadingHTTPServer(("127.0.0.1", 0), app.make_handler(state, "secret"))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"

    def call(path, body=None, token="secret"):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, headers={"X-Token": token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as res:
                return res.status, json.loads(res.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    try:
        assert call("/api/sources", token="wrong")[0] == 403
        with urllib.request.urlopen(base + "/") as res:
            assert b"Download My Messages" in res.read()

        status, added = call("/api/add-backup", {"path": str(backup_dir)})
        assert status == 200 and added["source"]["kind"] == "backup"
        status, loaded = call("/api/load", {"source": added["source"]})
        assert status == 200 and len(loaded["conversations"]) == 2
        alex = next(c for c in loaded["conversations"] if not c["isGroup"])
        assert alex["title"] == "Alex Kim"

        status, started = call("/api/export", {
            "rows": [{"id": alex["id"], "start": "2024-01-01T00:00:00Z", "end": "2024-01-31T23:59:59Z"}],
            "csv": True, "json": True, "copyAttachments": False, "folder": str(tmp_path),
        })
        assert started == {"started": True}
        for _ in range(100):
            _, s = call("/api/export-status")
            if not s["running"]:
                break
            threading.Event().wait(0.05)
        assert s["error"] is None and s["result"]["messages"] == 2
    finally:
        server.shutdown()
        if state.store:
            state.store.close()
