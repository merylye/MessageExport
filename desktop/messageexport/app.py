"""Local web app: a small HTTP server on 127.0.0.1 plus a page opened in the browser.

Nothing is reachable from other computers, and every API call must carry a random
token that only the page opened by this app knows.
"""

from __future__ import annotations

import json
import os
import queue
import secrets
import subprocess
import sys
import threading
import time
import traceback
import webbrowser
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib import resources
from pathlib import Path
from urllib.parse import urlparse

from . import backups, contacts
from .exporter import ExportOptions, ExportRequest, export
from .store import MessageStore, NeedsFullDiskAccess, SourceNotFound

IDLE_TIMEOUT_SECONDS = 600


def default_export_dir() -> Path:
    for candidate in (Path.home() / "Documents", Path.home() / "Downloads", Path.home()):
        if candidate.is_dir():
            return candidate
    return Path.home()


def open_in_file_manager(path: Path) -> None:
    if sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    elif sys.platform.startswith("win"):
        os.startfile(str(path))  # type: ignore[attr-defined]
    else:
        subprocess.Popen(["xdg-open", str(path)])


class MainThreadRunner:
    """Native folder dialogs (tkinter) must run on the main thread, especially on macOS."""

    def __init__(self) -> None:
        self.jobs: queue.Queue = queue.Queue()

    def call(self, fn, timeout: float = 600):
        result: queue.Queue = queue.Queue()
        self.jobs.put((fn, result))
        ok, value = result.get(timeout=timeout)
        if not ok:
            raise value
        return value

    def run_forever(self, should_stop) -> None:
        while not should_stop():
            try:
                fn, result = self.jobs.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                result.put((True, fn()))
            except Exception as exc:  # noqa: BLE001
                result.put((False, exc))


def ask_directory(title: str, initial: str | None) -> str | None:
    try:
        import tkinter
        from tkinter import filedialog
    except ImportError:
        return None
    root = tkinter.Tk()
    root.withdraw()
    try:
        root.attributes("-topmost", True)
    except Exception:  # noqa: BLE001
        pass
    path = filedialog.askdirectory(title=title, initialdir=initial or str(Path.home()), mustexist=True)
    root.destroy()
    return path or None


def dialogs_available() -> bool:
    try:
        import tkinter  # noqa: F401
        return True
    except ImportError:
        return False


class AppState:
    def __init__(self, runner: MainThreadRunner) -> None:
        self.runner = runner
        self.lock = threading.Lock()
        self.store: MessageStore | None = None
        self.contacts = contacts.ContactDirectory()
        self.conversations: dict = {}
        self.extra_backups: list[dict] = []
        self.export_state = {"running": False, "progress": 0.0, "status": "", "error": None, "result": None}
        self.last_seen = time.time()
        self.stop = False

    # ---- sources ----

    def sources(self) -> dict:
        items = []
        if sys.platform == "darwin":
            items.append({"kind": "mac", "label": "This Mac's Messages app"})
        found = backups.find_backups()
        paths = {b["path"] for b in found}
        for b in found + [b for b in self.extra_backups if b["path"] not in paths]:
            items.append({"kind": "backup", "path": b["path"], "label": b["label"], "isEncrypted": b["isEncrypted"]})
        return {
            "sources": items,
            "platform": sys.platform,
            "defaultExportDir": str(default_export_dir()),
            "dialogs": dialogs_available(),
        }

    def choose_backup(self) -> dict:
        root = backups.default_roots()[0] if backups.default_roots() else Path.home()
        path = self.runner.call(lambda: ask_directory("Choose an iPhone backup folder (contains Manifest.db)", str(root)))
        if not path:
            return {"cancelled": True}
        return self.add_backup(path)

    def add_backup(self, path: str) -> dict:
        info = backups.backup_info(Path(path))
        if not info:
            return {"error": "That folder isn't an iPhone backup. Look for a folder that contains Manifest.db."}
        if all(b["path"] != info["path"] for b in self.extra_backups):
            self.extra_backups.append(info)
        return {"source": {"kind": "backup", "path": info["path"], "label": info["label"]}}

    def choose_export_folder(self, initial: str | None) -> dict:
        path = self.runner.call(lambda: ask_directory("Choose where to save the export", initial))
        return {"path": path} if path else {"cancelled": True}

    # ---- loading ----

    def load(self, source: dict) -> dict:
        with self.lock:
            if self.store:
                self.store.close()
                self.store = None
            try:
                store = MessageStore.open(source)
            except NeedsFullDiskAccess:
                return {"needsFullDiskAccess": True}
            except backups.EncryptedBackup as exc:
                return {"error": str(exc)}
            except SourceNotFound as exc:
                return {"error": str(exc)}
            except Exception as exc:  # noqa: BLE001
                return {"error": f"Could not read messages: {exc}"}

            directory = contacts.ContactDirectory()
            if source["kind"] == "backup":
                directory.merge(contacts.from_backup(Path(source["path"])))
            directory.merge(contacts.from_mac_contacts())

            conversations = store.load_conversations()
            for c in conversations:
                for h in c.handles:
                    name = directory.name_for(h)
                    if name:
                        c.names[h] = name
            self.store = store
            self.contacts = directory
            self.conversations = {c.id: c for c in conversations}
            return {
                "conversations": [c.to_json() for c in conversations],
                "contactsFound": len(directory) > 0,
            }

    # ---- export ----

    def start_export(self, body: dict) -> dict:
        if self.export_state["running"]:
            return {"error": "An export is already running."}
        if not self.store:
            return {"error": "Load conversations first."}
        folder = Path(body.get("folder") or default_export_dir()).expanduser()
        if not folder.is_dir():
            return {"error": f"The folder {folder} doesn't exist."}
        requests = []
        for row in body.get("rows", []):
            conv = self.conversations.get(row.get("id"))
            if conv is None:
                continue
            start = datetime.fromisoformat(row["start"]) if row.get("start") else None
            end = datetime.fromisoformat(row["end"]) if row.get("end") else None
            requests.append(ExportRequest(conv, start, end))
        if not requests:
            return {"error": "Select at least one conversation."}
        options = ExportOptions(
            write_csv=bool(body.get("csv", True)),
            write_json=bool(body.get("json", True)),
            copy_attachments=bool(body.get("copyAttachments", False)),
        )
        if not (options.write_csv or options.write_json):
            return {"error": "Choose CSV, JSON, or both."}

        self.export_state = {"running": True, "progress": 0.0, "status": "Starting…", "error": None, "result": None}

        def progress(fraction: float, message: str) -> None:
            self.export_state["progress"] = fraction
            self.export_state["status"] = message

        def work() -> None:
            try:
                with self.lock:
                    summary = export(requests, self.store, self.contacts, options, folder, progress=progress)
                self.export_state["result"] = {
                    "folder": str(summary.folder),
                    "conversations": summary.conversations,
                    "messages": summary.messages,
                    "attachmentsCopied": summary.attachments_copied,
                    "attachmentsMissing": summary.attachments_missing,
                    "copiedAttachments": options.copy_attachments,
                }
            except Exception as exc:  # noqa: BLE001
                traceback.print_exc()
                self.export_state["error"] = f"Export failed: {exc}"
            finally:
                self.export_state["running"] = False

        threading.Thread(target=work, daemon=True).start()
        return {"started": True}

    def open_export(self) -> dict:
        result = self.export_state.get("result")
        if result:
            open_in_file_manager(Path(result["folder"]))
        return {}


def make_handler(state: AppState, token: str):
    page = resources.files("messageexport").joinpath("static/index.html").read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:  # keep the console quiet
            pass

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, data, status: int = 200) -> None:
            self._send(status, json.dumps(data).encode("utf-8"), "application/json")

        def _authorized(self) -> bool:
            # Reject requests from other web pages (DNS rebinding / CSRF) and without the token.
            host = (self.headers.get("Host") or "").split(":")[0]
            if host not in ("127.0.0.1", "localhost"):
                return False
            return secrets.compare_digest(self.headers.get("X-Token", ""), token)

        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path in ("/", "/index.html"):
                self._send(200, page, "text/html; charset=utf-8")
                return
            if not self._authorized():
                self._json({"error": "unauthorized"}, 403)
                return
            state.last_seen = time.time()
            if path == "/api/sources":
                self._json(state.sources())
            elif path == "/api/export-status":
                self._json(state.export_state)
            else:
                self._json({"error": "not found"}, 404)

        def do_POST(self) -> None:
            if not self._authorized():
                self._json({"error": "unauthorized"}, 403)
                return
            state.last_seen = time.time()
            length = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self._json({"error": "bad request"}, 400)
                return
            path = urlparse(self.path).path
            try:
                if path == "/api/load":
                    self._json(state.load(body["source"]))
                elif path == "/api/choose-backup":
                    self._json(state.choose_backup())
                elif path == "/api/add-backup":
                    self._json(state.add_backup(body.get("path", "")))
                elif path == "/api/choose-folder":
                    self._json(state.choose_export_folder(body.get("initial")))
                elif path == "/api/export":
                    self._json(state.start_export(body))
                elif path == "/api/open-export":
                    self._json(state.open_export())
                elif path == "/api/open-privacy-settings":
                    if sys.platform == "darwin":
                        subprocess.Popen(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
                    self._json({})
                elif path == "/api/heartbeat":
                    self._json({})
                elif path == "/api/quit":
                    self._json({})
                    state.stop = True
                else:
                    self._json({"error": "not found"}, 404)
            except Exception as exc:  # noqa: BLE001
                traceback.print_exc()
                self._json({"error": str(exc)}, 500)

    return Handler


def main() -> None:
    token = secrets.token_urlsafe(24)
    runner = MainThreadRunner()
    state = AppState(runner)
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state, token))
    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/#token={token}"
    threading.Thread(target=server.serve_forever, daemon=True).start()

    print("Download My Messages is running.")
    print(f"If your browser didn't open, go to: {url}")
    print("Close this window or click Quit in the page to stop.")
    if not os.environ.get("DMM_NO_BROWSER"):
        webbrowser.open(url)

    def should_stop() -> bool:
        idle = time.time() - state.last_seen > IDLE_TIMEOUT_SECONDS
        return state.stop or (idle and not state.export_state["running"])

    try:
        runner.run_forever(should_stop)
    except KeyboardInterrupt:
        pass
    server.shutdown()
    if state.store:
        state.store.close()


if __name__ == "__main__":
    main()
