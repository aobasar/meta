"""Notes and lists that Nova keeps for the user.

Stored as one JSON file on this Mac (web-prototype/data/, git-ignored). Voice
and text requests can create notes, create lists, add items, and check items
off; deleting anything happens only from the page, after a confirmation.
"""

from __future__ import annotations

import json
import os
import re
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

MAX_NOTES = 500
MAX_LISTS = 100
MAX_ITEMS_PER_LIST = 200
MAX_NOTE_CHARS = 4000
MAX_TITLE_CHARS = 80
MAX_ITEM_CHARS = 200
MAX_ITEMS_PER_CALL = 50


class WorkspaceError(Exception):
    """A request the workspace can't carry out; the message is safe to show."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _new_id() -> str:
    return uuid.uuid4().hex[:12]


def _key(text: str) -> str:
    """Comparison key: case-insensitive with collapsed whitespace."""
    return re.sub(r"\s+", " ", text).strip().casefold()


def _clean(text, limit: int, what: str) -> str:
    if not isinstance(text, str) or not text.strip():
        raise WorkspaceError(f"The {what} is empty.")
    text = text.strip()
    if len(text) > limit:
        raise WorkspaceError(f"The {what} is longer than {limit} characters.")
    return text


def _clean_items(items) -> list[str]:
    if not isinstance(items, list) or not items:
        raise WorkspaceError("Give at least one item.")
    if len(items) > MAX_ITEMS_PER_CALL:
        raise WorkspaceError(f"Add at most {MAX_ITEMS_PER_CALL} items at a time.")
    return [_clean(item, MAX_ITEM_CHARS, "item") for item in items]


class Workspace:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()

    # -- storage -----------------------------------------------------------

    def _load(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            data = {}
        except (OSError, ValueError) as exc:
            raise WorkspaceError(f"Couldn't read the notes file ({exc.__class__.__name__}).") from None
        return {"notes": list(data.get("notes", [])), "lists": list(data.get("lists", []))}

    def _save(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(temporary, self.path)

    def snapshot(self) -> dict:
        with self.lock:
            return self._load()

    # -- lookups -----------------------------------------------------------

    @staticmethod
    def _find_list(data: dict, name: str) -> dict | None:
        wanted = _key(name)
        return next((item for item in data["lists"] if _key(item["name"]) == wanted), None)

    @staticmethod
    def _find_note(data: dict, title: str) -> dict | None:
        wanted = _key(title)
        return next((note for note in data["notes"] if _key(note["title"]) == wanted), None)

    # -- changes Nova may make on request -----------------------------------

    def add_note(self, text, title=None) -> dict:
        text = _clean(text, MAX_NOTE_CHARS, "note")
        if title:
            title = _clean(title, MAX_TITLE_CHARS, "note title")
        else:
            words = text.split()
            title = " ".join(words[:6]) + ("…" if len(words) > 6 else "")
            title = title[:MAX_TITLE_CHARS]
        with self.lock:
            data = self._load()
            if len(data["notes"]) >= MAX_NOTES:
                raise WorkspaceError(f"There are already {MAX_NOTES} notes.")
            note = {"id": _new_id(), "title": title, "text": text, "createdAt": _now(), "updatedAt": _now()}
            data["notes"].insert(0, note)
            self._save(data)
            return note

    def append_to_note(self, title, text) -> dict:
        title = _clean(title, MAX_TITLE_CHARS, "note title")
        text = _clean(text, MAX_NOTE_CHARS, "text to add")
        with self.lock:
            data = self._load()
            note = self._find_note(data, title)
            if not note:
                raise WorkspaceError(f"There is no note titled “{title}”.")
            combined = f"{note['text']}\n{text}"
            if len(combined) > MAX_NOTE_CHARS:
                raise WorkspaceError("The note would be too long.")
            note["text"] = combined
            note["updatedAt"] = _now()
            self._save(data)
            return note

    def create_list(self, name, items=None) -> tuple[dict, bool, list[dict]]:
        """Returns (list, created, items added). An existing list is reused."""
        name = _clean(name, MAX_TITLE_CHARS, "list name")
        new_items = _clean_items(items) if items else []
        with self.lock:
            data = self._load()
            target = self._find_list(data, name)
            created = target is None
            if created:
                if len(data["lists"]) >= MAX_LISTS:
                    raise WorkspaceError(f"There are already {MAX_LISTS} lists.")
                target = {"id": _new_id(), "name": name, "items": [], "createdAt": _now()}
                data["lists"].insert(0, target)
            added = self._append_items(target, new_items)
            self._save(data)
            return target, created, added

    def add_items(self, name, items) -> tuple[dict, bool, list[dict]]:
        """Add items to a list, creating the list if it doesn't exist yet."""
        _clean_items(items)
        return self.create_list(name, items)

    @staticmethod
    def _append_items(target: dict, texts: list[str]) -> list[dict]:
        existing = {_key(item["text"]) for item in target["items"]}
        added = []
        for text in texts:
            if _key(text) in existing:
                continue  # don't add the same item twice
            if len(target["items"]) >= MAX_ITEMS_PER_LIST:
                raise WorkspaceError(f"A list can hold at most {MAX_ITEMS_PER_LIST} items.")
            item = {"id": _new_id(), "text": text, "done": False}
            target["items"].append(item)
            existing.add(_key(text))
            added.append(item)
        return added

    def set_item_done(self, name, item_text, done: bool) -> tuple[dict, dict]:
        name = _clean(name, MAX_TITLE_CHARS, "list name")
        item_text = _clean(item_text, MAX_ITEM_CHARS, "item")
        with self.lock:
            data = self._load()
            target = self._find_list(data, name)
            if not target:
                raise WorkspaceError(f"There is no list named “{name}”.")
            wanted = _key(item_text)
            matches = [item for item in target["items"] if _key(item["text"]) == wanted]
            if not matches:
                matches = [item for item in target["items"] if wanted in _key(item["text"])]
            if len(matches) != 1:
                raise WorkspaceError(
                    f"“{item_text}” isn't on the list “{target['name']}”." if not matches
                    else f"“{item_text}” matches more than one item on “{target['name']}”."
                )
            matches[0]["done"] = bool(done)
            self._save(data)
            return target, matches[0]

    # -- changes made from the page, after the user confirms -------------------

    def delete_note(self, note_id: str) -> None:
        with self.lock:
            data = self._load()
            remaining = [note for note in data["notes"] if note["id"] != note_id]
            if len(remaining) == len(data["notes"]):
                raise WorkspaceError("That note no longer exists.")
            data["notes"] = remaining
            self._save(data)

    def delete_list(self, list_id: str) -> None:
        with self.lock:
            data = self._load()
            remaining = [item for item in data["lists"] if item["id"] != list_id]
            if len(remaining) == len(data["lists"]):
                raise WorkspaceError("That list no longer exists.")
            data["lists"] = remaining
            self._save(data)

    def delete_item(self, list_id: str, item_id: str) -> None:
        with self.lock:
            data = self._load()
            target = next((item for item in data["lists"] if item["id"] == list_id), None)
            if not target or not any(item["id"] == item_id for item in target["items"]):
                raise WorkspaceError("That item no longer exists.")
            target["items"] = [item for item in target["items"] if item["id"] != item_id]
            self._save(data)

    def toggle_item(self, list_id: str, item_id: str) -> None:
        with self.lock:
            data = self._load()
            target = next((item for item in data["lists"] if item["id"] == list_id), None)
            item = next((entry for entry in (target or {}).get("items", []) if entry["id"] == item_id), None)
            if not item:
                raise WorkspaceError("That item no longer exists.")
            item["done"] = not item["done"]
            self._save(data)

    # -- context for the model --------------------------------------------------

    def summary(self, limit: int = 3000) -> str:
        data = self.snapshot()
        lines = []
        for entry in data["lists"]:
            items = ", ".join(f"{item['text']}{' (done)' if item['done'] else ''}" for item in entry["items"]) or "empty"
            lines.append(f"- List “{entry['name']}”: {items}")
        for note in data["notes"]:
            lines.append(f"- Note “{note['title']}”")
        text = "\n".join(lines) or "(none yet)"
        return text if len(text) <= limit else text[:limit] + "\n…"
