"""Maps phone numbers and emails to contact names."""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

from . import backups
from .store import handle_key


class ContactDirectory:
    def __init__(self) -> None:
        self._names: dict[str, str] = {}

    def __len__(self) -> int:
        return len(self._names)

    def add(self, name: str, handles: list[str]) -> None:
        name = (name or "").strip()
        if not name:
            return
        for handle in handles:
            if not handle:
                continue
            key = handle_key(handle)
            if key and key not in self._names:
                self._names[key] = name

    def merge(self, other: "ContactDirectory") -> None:
        for key, value in other._names.items():
            self._names.setdefault(key, value)

    def name_for(self, handle: str | None) -> str | None:
        if not handle:
            return None
        return self._names.get(handle_key(handle))


def _open_ro(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{Path(path).as_posix()}?mode=ro", uri=True)


def from_backup(backup: Path) -> ContactDirectory:
    """Reads AddressBook.sqlitedb from an iPhone backup."""
    directory = ContactDirectory()
    path = backups.address_book(Path(backup))
    if not path.exists():
        return directory
    try:
        db = _open_ro(path)
        people = {}
        for row_id, first, last, org in db.execute("SELECT ROWID, First, Last, Organization FROM ABPerson"):
            name = " ".join(p for p in (first, last) if p) or (org or "")
            if name:
                people[row_id] = name
        # property 3 = phone, 4 = email
        for record_id, value in db.execute(
            "SELECT record_id, value FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL"
        ):
            if record_id in people:
                directory.add(people[record_id], [value])
        db.close()
    except sqlite3.Error:
        pass
    return directory


def from_mac_contacts() -> ContactDirectory:
    """Reads the Contacts app's databases on a Mac (needs Full Disk Access)."""
    directory = ContactDirectory()
    if sys.platform != "darwin":
        return directory
    root = Path.home() / "Library" / "Application Support" / "AddressBook"
    candidates = [root / "AddressBook-v22.abcddb"]
    try:
        candidates += list((root / "Sources").glob("*/AddressBook-v22.abcddb"))
    except OSError:
        pass
    for path in candidates:
        if not path.exists():
            continue
        try:
            db = _open_ro(path)
            people = {}
            for pk, first, last, org in db.execute(
                "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD"
            ):
                name = " ".join(p for p in (first, last) if p) or (org or "")
                if name:
                    people[pk] = name
            for owner, number in db.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER"):
                if owner in people:
                    directory.add(people[owner], [number])
            for owner, address in db.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"):
                if owner in people:
                    directory.add(people[owner], [address])
            db.close()
        except sqlite3.Error:
            continue
    return directory
