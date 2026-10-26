"""Tests for notes and lists: the store, the tool-calling loop, and the
page's edit endpoint."""

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from test_server import FAKE_KEY, FakeOpener, chat_reply

import server
from workspace import Workspace, WorkspaceError


def tool_call(name, arguments, call_id="call_1"):
    return {
        "model": server.REASONING_MODEL,
        "choices": [
            {
                "message": {
                    "content": None,
                    "tool_calls": [{"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}],
                },
                "finish_reason": "tool_calls",
            }
        ],
    }


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workspace = Workspace(Path(self.tmp.name) / "data" / "workspace.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_lists_are_created_reused_and_deduplicated(self):
        first, created, added = self.workspace.create_list("Shopping", ["milk", "eggs"])
        self.assertTrue(created)
        self.assertEqual([item["text"] for item in added], ["milk", "eggs"])
        second, created, added = self.workspace.add_items("  shopping ", ["Milk", "bread"])
        self.assertFalse(created)
        self.assertEqual(second["id"], first["id"])
        self.assertEqual([item["text"] for item in added], ["bread"])
        self.assertEqual([item["text"] for item in self.workspace.snapshot()["lists"][0]["items"]], ["milk", "eggs", "bread"])

    def test_add_items_creates_a_missing_list(self):
        target, created, _ = self.workspace.add_items("Groceries", ["apples"])
        self.assertTrue(created)
        self.assertEqual(target["name"], "Groceries")

    def test_set_item_done_matches_exactly_or_by_unique_part(self):
        self.workspace.create_list("Shopping", ["whole milk", "eggs"])
        _, item = self.workspace.set_item_done("shopping", "milk", True)
        self.assertEqual((item["text"], item["done"]), ("whole milk", True))
        with self.assertRaises(WorkspaceError):
            self.workspace.set_item_done("Shopping", "bananas", True)
        with self.assertRaises(WorkspaceError):
            self.workspace.set_item_done("Errands", "eggs", True)

    def test_notes_get_a_title_and_can_be_extended(self):
        note = self.workspace.add_note("Call the dentist on Friday about the appointment time")
        self.assertEqual(note["title"], "Call the dentist on Friday about…")
        self.workspace.append_to_note(note["title"], "Ask about parking too.")
        self.assertEqual(self.workspace.snapshot()["notes"][0]["text"].splitlines()[-1], "Ask about parking too.")

    def test_validation(self):
        for call in (
            lambda: self.workspace.add_note("   "),
            lambda: self.workspace.add_note("x" * 5000),
            lambda: self.workspace.create_list(""),
            lambda: self.workspace.add_items("Shopping", []),
            lambda: self.workspace.add_items("Shopping", ["ok"] * 51),
        ):
            with self.assertRaises(WorkspaceError):
                call()

    def test_deletes_and_toggles_by_id(self):
        target, _, added = self.workspace.create_list("Shopping", ["milk"])
        self.workspace.toggle_item(target["id"], added[0]["id"])
        self.assertTrue(self.workspace.snapshot()["lists"][0]["items"][0]["done"])
        self.workspace.delete_item(target["id"], added[0]["id"])
        self.assertEqual(self.workspace.snapshot()["lists"][0]["items"], [])
        self.workspace.delete_list(target["id"])
        self.assertEqual(self.workspace.snapshot()["lists"], [])
        with self.assertRaises(WorkspaceError):
            self.workspace.delete_list(target["id"])

    def test_survives_a_restart(self):
        self.workspace.add_note("Remember the milk")
        again = Workspace(self.workspace.path)
        self.assertEqual(again.snapshot()["notes"][0]["text"], "Remember the milk")

    def test_summary_lists_content(self):
        self.workspace.create_list("Shopping", ["milk"])
        self.workspace.set_item_done("Shopping", "milk", True)
        self.workspace.add_note("Dentist Friday", "Dentist")
        summary = self.workspace.summary()
        self.assertIn("List “Shopping”: milk (done)", summary)
        self.assertIn("Note “Dentist”", summary)


class ToolLoopTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workspace = Workspace(Path(self.tmp.name) / "workspace.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_ask_runs_tools_then_answers(self):
        opener = FakeOpener(tool_call("create_list", {"name": "Shopping", "items": ["milk", "eggs"]}), chat_reply("Done, I made the list."))
        result = server.run_request({"action": "ask", "text": "Make a shopping list with milk and eggs"}, FAKE_KEY, opener, self.workspace)
        self.assertEqual(result["text"], "Done, I made the list.")
        self.assertEqual(result["changes"][0]["summary"], "Created list Shopping: milk, eggs")
        self.assertEqual(result["workspace"]["lists"][0]["name"], "Shopping")

        first = json.loads(opener.requests[0].data)
        self.assertEqual([tool["function"]["name"] for tool in first["tools"]], [tool["function"]["name"] for tool in server.WORKSPACE_TOOLS])
        self.assertIn("(none yet)", first["messages"][0]["content"])
        second = json.loads(opener.requests[1].data)["messages"]
        self.assertEqual(second[-2]["tool_calls"][0]["id"], "call_1")
        self.assertEqual(second[-1]["role"], "tool")
        self.assertEqual(json.loads(second[-1]["content"])["added"], ["milk", "eggs"])

    def test_tool_failures_are_reported_to_the_model(self):
        opener = FakeOpener(tool_call("set_list_item_done", {"list_name": "Errands", "item": "x", "done": True}), chat_reply("There is no Errands list."))
        result = server.run_request({"action": "ask", "text": "Check x off errands"}, FAKE_KEY, opener, self.workspace)
        self.assertNotIn("changes", result)
        tool_result = json.loads(json.loads(opener.requests[1].data)["messages"][-1]["content"])
        self.assertFalse(tool_result["ok"])

    def test_bad_arguments_and_unknown_tools_do_not_crash(self):
        bad = tool_call("add_note", {})
        bad["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] = "{not json"
        opener = FakeOpener(bad, tool_call("delete_everything", {}), chat_reply("Sorry."))
        result = server.run_request({"action": "ask", "text": "hi"}, FAKE_KEY, opener, self.workspace)
        self.assertEqual(result["text"], "Sorry.")
        self.assertEqual(self.workspace.snapshot(), {"notes": [], "lists": []})

    def test_runaway_tool_loops_stop(self):
        opener = FakeOpener(*[tool_call("add_note", {"text": f"n{i}"}) for i in range(server.MAX_TOOL_ROUNDS)])
        with self.assertRaisesRegex(server.UpstreamError, "too many tool steps"):
            server.run_request({"action": "ask", "text": "hi"}, FAKE_KEY, opener, self.workspace)

    def test_text_transforms_get_no_tools(self):
        opener = FakeOpener(chat_reply("Hello"))
        server.run_request({"action": "translate", "text": "Merhaba", "targetLanguage": "English"}, FAKE_KEY, opener, self.workspace)
        self.assertNotIn("tools", json.loads(opener.requests[0].data))


class EditEndpointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        env = Path(self.tmp.name) / ".env.local"
        env.write_text(f"MODEL_API_KEY={FAKE_KEY}\n")
        self.httpd = server.NovaServer(0, env, FakeOpener(), data_dir=Path(self.tmp.name))
        self.origin = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.list, _, self.items = self.httpd.workspace.create_list("Shopping", ["milk"])

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def post(self, body, origin=None):
        request = urllib.request.Request(
            f"{self.origin}/api/workspace",
            data=json.dumps(body).encode(),
            method="POST",
            headers={"Content-Type": "application/json", "Origin": origin or self.origin},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            with exc:
                return exc.code, json.loads(exc.read())

    def test_get_returns_the_workspace(self):
        with urllib.request.urlopen(f"{self.origin}/api/workspace", timeout=5) as response:
            self.assertEqual(json.loads(response.read())["lists"][0]["name"], "Shopping")

    def test_toggle_then_delete(self):
        status, data = self.post({"op": "toggle_item", "id": self.list["id"], "itemId": self.items[0]["id"]})
        self.assertEqual(status, 200)
        self.assertTrue(data["lists"][0]["items"][0]["done"])
        status, data = self.post({"op": "delete_list", "id": self.list["id"]})
        self.assertEqual((status, data["lists"]), (200, []))
        status, data = self.post({"op": "delete_list", "id": self.list["id"]})
        self.assertEqual(status, 409)

    def test_rejects_foreign_origin_and_unknown_operations(self):
        status, _ = self.post({"op": "delete_list", "id": self.list["id"]}, origin="https://evil.example")
        self.assertEqual(status, 403)
        status, _ = self.post({"op": "drop_everything"})
        self.assertEqual(status, 400)
        self.assertEqual(len(self.httpd.workspace.snapshot()["lists"]), 1)


if __name__ == "__main__":
    unittest.main()
