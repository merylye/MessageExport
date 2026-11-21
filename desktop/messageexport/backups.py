"""Finds and reads iPhone backups made by Finder (Mac) or iTunes / Apple Devices (Windows)."""

from __future__ import annotations

import hashlib
import os
import plistlib
import sys
from datetime import datetime
from pathlib import Path


class EncryptedBackup(Exception):
    def __str__(self) -> str:
        return (
            "This iPhone backup is encrypted, which isn't supported yet. Turn off "
            "\"Encrypt local backup\" (Finder on Mac, or the Apple Devices app / iTunes on Windows; "
            "it asks for the backup password) and back up again."
        )


def default_roots() -> list[Path]:
    home = Path.home()
    if sys.platform == "darwin":
        return [home / "Library" / "Application Support" / "MobileSync" / "Backup"]
    if sys.platform.startswith("win"):
        roots = []
        appdata = os.environ.get("APPDATA")
        if appdata:
            roots.append(Path(appdata) / "Apple Computer" / "MobileSync" / "Backup")
        # Microsoft Store versions of iTunes / Apple Devices.
        roots.append(home / "Apple" / "MobileSync" / "Backup")
        return roots
    return []


def find_backups() -> list[dict]:
    found = []
    for root in default_roots():
        try:
            entries = list(root.iterdir())
        except (FileNotFoundError, PermissionError, NotADirectoryError):
            continue
        for entry in entries:
            if entry.is_dir():
                info = backup_info(entry)
                if info:
                    found.append(info)
    found.sort(key=lambda b: b.get("lastBackup") or "", reverse=True)
    return found


def backup_info(folder: Path) -> dict | None:
    folder = Path(folder)
    if not ((folder / "Manifest.db").exists() or (folder / "Info.plist").exists()):
        return None
    device_name = folder.name
    last_backup = None
    try:
        with open(folder / "Info.plist", "rb") as f:
            info = plistlib.load(f)
        device_name = info.get("Device Name") or info.get("Display Name") or device_name
        value = info.get("Last Backup Date")
        if isinstance(value, datetime):
            last_backup = value.isoformat()
    except Exception:
        pass
    encrypted = False
    try:
        with open(folder / "Manifest.plist", "rb") as f:
            encrypted = bool(plistlib.load(f).get("IsEncrypted", False))
    except Exception:
        pass
    label = f"iPhone backup: {device_name}"
    if last_backup:
        label += f" · {last_backup[:10]}"
    return {
        "path": str(folder),
        "deviceName": device_name,
        "lastBackup": last_backup,
        "isEncrypted": encrypted,
        "label": label,
    }


def file_path(backup: Path, domain: str, relative_path: str) -> Path:
    """Files in an unencrypted backup are stored as <first 2 hex>/<SHA1("Domain-relativePath")>."""
    digest = hashlib.sha1(f"{domain}-{relative_path}".encode("utf-8")).hexdigest()
    nested = Path(backup) / digest[:2] / digest
    if nested.exists():
        return nested
    return Path(backup) / digest  # very old backups were flat


def messages_database(backup: Path) -> Path:
    return file_path(backup, "HomeDomain", "Library/SMS/sms.db")


def address_book(backup: Path) -> Path:
    return file_path(backup, "HomeDomain", "Library/AddressBook/AddressBook.sqlitedb")


def attachment_file(backup: Path, stored_path: str) -> Path | None:
    path = stored_path
    for prefix in ("~/", "/var/mobile/", "/private/var/mobile/"):
        if path.startswith(prefix):
            path = path[len(prefix):]
            break
    if not path.startswith("Library/"):
        return None
    return file_path(backup, "MediaDomain", path)
