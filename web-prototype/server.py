#!/usr/bin/env python3
"""Local prototype server for Nova.

Serves the web UI and forwards its requests to the Meta Model API. The API key
is read from .env.local on every request and never leaves this process: the
browser only talks to this server, which listens on 127.0.0.1 only.

Standard library only, so it runs with any Python 3.10+ without installs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

import ws

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
STATIC_DIR = HERE / "static"
DEFAULT_ENV_FILE = REPO_ROOT / ".env.local"
DEFAULT_PORT = 9005

API_BASE = "https://api.meta.ai/v1"
KEY_NAME = "MODEL_API_KEY"
KEY_PLACEHOLDERS = {"", "your_model_api_key_here", "your-api-key-here"}

# Standard-tier models only (HACKATHON.md, design rule 1). The browser cannot
# choose a model; every request uses these pinned IDs.
TRANSCRIBE_MODEL = "muse-voice-transcribe-1.0"
REASONING_MODEL = "muse-spark-1.3"

MAX_AUDIO_BYTES = 32 * 1024 * 1024  # Meta's transcribe request limit
MAX_RUN_BYTES = 40 * 1024 * 1024  # text plus an inline image
UPSTREAM_TIMEOUT_SECONDS = 120

REALTIME_URL = "wss://api.meta.ai/v1/asr/realtime"
REALTIME_MAX_SECONDS = 120  # one conversation turn; Meta allows 60-minute sessions
REALTIME_HANDSHAKE_SECONDS = 10
MAX_LANGUAGE_HINTS = 3

# Languages Muse Voice Transcribe supports, as named in Meta's docs.
SPEECH_LANGUAGES = {
    "Arabic", "Bengali", "Dutch", "English", "French", "German", "Hebrew", "Hindi",
    "Indonesian", "Italian", "Japanese", "Kannada", "Korean", "Malay",
    "Mandarin Chinese", "Marathi", "Polish", "Portuguese", "Spanish", "Tagalog",
    "Tamil", "Telugu", "Thai", "Turkish", "Vietnamese",
}

ACTION_LABELS = {
    "auto": "Auto",
    "ask": "Ask",
    "translate": "Translate",
    "rewrite": "Rewrite",
    "summarize": "Summarize",
    "plan_task": "Plan task",
}
EXECUTABLE_ACTIONS = ("ask", "translate", "rewrite", "summarize", "plan_task")

STYLE_RULE = (
    "You are Nova, a desktop assistant on the user's Mac. Write plain text without "
    "Markdown headings or bold; short '-' bullet lists are fine."
)

VOICE_RULE = (
    "Your reply will be read aloud by a speech synthesizer in a spoken conversation. "
    "Keep it short, at most three sentences unless the user asks for more, and avoid "
    "lists, symbols and URLs."
)

# Actions that use earlier conversation turns; the others work on the given text only.
CONVERSATIONAL_ACTIONS = ("ask", "plan_task")
MAX_HISTORY_MESSAGES = 12
MAX_HISTORY_CHARS = 4000

ACTION_PROMPTS = {
    "ask": (
        "Answer the user's request or question directly and concisely, in the language "
        "the user wrote in. If an image is attached, base your answer on it. If you are "
        "not sure, say so."
    ),
    "translate": (
        "Translate the user's text into {language}. The text may start with a spoken "
        "instruction such as 'translate this into English:'. Translate only the content "
        "that instruction refers to, never the instruction itself. Output only the "
        "translation."
    ),
    "rewrite": (
        "Rewrite the user's text so it reads clearly and naturally. Keep its language, "
        "meaning and tone. If the text starts with a spoken instruction, apply it and "
        "leave the instruction out. Output only the rewritten text."
    ),
    "summarize": (
        "Summarize the user's text in its own language as a few short '-' bullet points. "
        "If an image is attached, summarize what it shows."
    ),
    "plan_task": (
        "Turn the user's request into a short numbered plan for doing it on a Mac. You "
        "cannot perform any step and nothing has been done yet, so never describe a step "
        "as done. End with what you would need to know from the user, if anything. Reply "
        "in the user's language."
    ),
}

AUTO_ACTIONS = [
    "ask", "translate", "rewrite", "summarize", "plan_task",
    "save_result_as_text_file", "clarify",
]

AUTO_PROMPT = """You route spoken requests for Nova, a desktop assistant. Pick exactly one action:
- ask: a question or a general request.
- translate: translate text. Set target_language to the English name of the target language, such as "English".
- rewrite: rewrite or polish text.
- summarize: summarize text.
- plan_task: plan the steps of a task on the computer.
- save_result_as_text_file: save the current result, or text the user gives, as a text file.
- clarify: the request is ambiguous or is missing information you need.
Put the text the action should work on in content, without the command itself. For ask and plan_task, put the whole request in content. If the user refers to the current result instead of giving text, leave content empty.
For clarify, write one short question in the user's language in clarification_question.
Use an empty string for every field that does not apply.
Context: a current result exists: {has_result}. An image is attached: {has_image}."""

# Muse Spark 1.3's lowest reasoning setting ("none" is rejected). Measured on
# 2026-10-26: routing dropped from ~2.9 s to ~0.9 s and short spoken answers
# from ~2.5 s to ~1.0 s, with the same routing decisions.
FAST_REASONING = "minimal"

AUTO_RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {
        "name": "nova_intent",
        "schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": AUTO_ACTIONS},
                "target_language": {"type": "string"},
                "content": {"type": "string"},
                "clarification_question": {"type": "string"},
            },
            "required": ["action", "target_language", "content", "clarification_question"],
            "additionalProperties": False,
        },
    },
}

IMAGE_DATA_URL = re.compile(r"^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=]+$")
TARGET_LANGUAGE = re.compile(r"^[A-Za-z][A-Za-z ()-]{0,39}$")


class ConfigError(Exception):
    """The local key setup is incomplete; the message tells the user how to fix it."""


class BadRequest(Exception):
    """The browser sent something this server won't forward."""


class UpstreamError(Exception):
    """Meta's API returned an error or could not be reached."""

    def __init__(self, status: int, message: str, code: str | None = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code


# ---------------------------------------------------------------------------
# Configuration


def parse_env(text: str) -> dict[str, str]:
    """Parse dotenv lines: KEY=VALUE, '#' comments, optional quotes and 'export'."""
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep or not key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        elif " #" in value:
            value = value.split(" #", 1)[0].rstrip()
        values[key] = value
    return values


def load_api_key(env_file: Path) -> str:
    if not env_file.is_file():
        raise ConfigError(
            f"No {env_file.name} file found in the project root. Copy .env.example to "
            f".env.local and set {KEY_NAME} to your Meta Model API key."
        )
    try:
        values = parse_env(env_file.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"Couldn't read {env_file.name}: {exc.__class__.__name__}.") from None
    key = values.get(KEY_NAME, "").strip()
    if key in KEY_PLACEHOLDERS:
        raise ConfigError(
            f"{KEY_NAME} is empty in {env_file.name}. Create a key at https://dev.meta.ai "
            "(API keys, then Create API key) and paste it after the equals sign."
        )
    return key


def redact(text: str, secret: str) -> str:
    return text.replace(secret, "[redacted]") if secret else text


# ---------------------------------------------------------------------------
# Meta Model API


def friendly_error(status: int, detail: str | None) -> str:
    messages = {
        400: "Meta rejected the request (400).",
        401: f"Meta rejected the API key (401). Check {KEY_NAME} in .env.local.",
        403: "This account can't use this model or feature (403).",
        404: "Model or endpoint not found (404).",
        406: "Meta couldn't return the requested format (406).",
        413: "The upload is too large for Meta (413). Keep audio under 32 MB.",
        429: "Rate or concurrency limit reached (429). Wait a moment, then try again.",
    }
    if status in messages:
        base = messages[status]
    elif status >= 500:
        base = f"Meta had a server error ({status}). Try again later."
    else:
        base = f"Meta returned HTTP {status}."
    return f"{base} Details: {detail}" if detail else base


def error_detail(body: bytes) -> str | None:
    """Pull the message out of Meta's error body: {"error": {...}} or a flat object."""
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return None
    if isinstance(data, dict):
        inner = data.get("error", data)
        if isinstance(inner, dict) and isinstance(inner.get("message"), str):
            return inner["message"][:500]
    return None


def call_meta(request: urllib.request.Request, api_key: str, opener) -> dict:
    try:
        with opener(request, timeout=UPSTREAM_TIMEOUT_SECONDS) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        detail = error_detail(exc.read())
        raise UpstreamError(exc.code, friendly_error(exc.code, redact(detail, api_key) if detail else None)) from None
    except urllib.error.URLError as exc:
        raise UpstreamError(0, f"Couldn't reach api.meta.ai ({exc.reason}).") from None
    except TimeoutError:
        raise UpstreamError(0, "Meta didn't answer within two minutes.") from None
    try:
        return json.loads(body)
    except ValueError:
        raise UpstreamError(0, "Meta sent a response this prototype couldn't read.") from None


def build_multipart(parts: list[tuple[str, str | None, str, bytes]], boundary: str) -> bytes:
    """Encode (name, filename, content_type, data) parts as multipart/form-data."""
    out = bytearray()
    for name, filename, content_type, data in parts:
        out += f"--{boundary}\r\n".encode()
        disposition = f'form-data; name="{name}"'
        if filename:
            disposition += f'; filename="{filename}"'
        out += f"Content-Disposition: {disposition}\r\n".encode()
        out += f"Content-Type: {content_type}\r\n\r\n".encode()
        out += data
        out += b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out)


def transcribe(wav: bytes, languages: list[str], api_key: str, opener) -> dict:
    settings = {"model": TRANSCRIBE_MODEL, "audioEncoding": "WAV", "mode": "PUSH_TO_TALK"}
    if languages:
        settings["languageBias"] = languages
    boundary = f"nova-{uuid.uuid4().hex}"
    body = build_multipart(
        [
            ("request", None, "application/json", json.dumps(settings).encode()),
            ("audio", "recording.wav", "audio/wav", wav),
        ],
        boundary,
    )
    request = urllib.request.Request(
        f"{API_BASE}/asr/transcribe",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    data = call_meta(request, api_key, opener)
    transcript = (data.get("transcript") or "").strip()
    if not transcript:
        raise UpstreamError(0, "Meta returned an empty transcript. Was there speech in the recording?", "empty_transcript")
    return {
        "transcript": transcript,
        "sessionId": data.get("sessionId"),
        "audioDurationMs": data.get("audioDurationMs"),
        "model": TRANSCRIBE_MODEL,
    }


def chat(
    messages: list[dict],
    api_key: str,
    opener,
    response_format: dict | None = None,
    reasoning_effort: str | None = None,
) -> dict:
    payload: dict = {"model": REASONING_MODEL, "messages": messages}
    if reasoning_effort:
        payload["reasoning_effort"] = reasoning_effort
    if response_format:
        payload["response_format"] = response_format
    request = urllib.request.Request(
        f"{API_BASE}/chat/completions",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    data = call_meta(request, api_key, opener)
    served = str(data.get("model") or REASONING_MODEL)
    if "contributor" in served.lower():
        # Design rule 1: screen and voice content must never reach a Contributor model.
        raise UpstreamError(0, f"Meta served a Contributor model ({served}); the result was discarded.")
    choices = data.get("choices") or []
    message = choices[0].get("message", {}) if choices else {}
    text = (message.get("content") or "").strip() if isinstance(message.get("content"), str) else ""
    if not text:
        raise UpstreamError(0, "Meta returned an empty answer.")
    return {"text": text, "model": served, "truncated": choices[0].get("finish_reason") == "length"}


# ---------------------------------------------------------------------------
# Prompting


def user_message(text: str, image: str | None) -> dict:
    if not image:
        return {"role": "user", "content": text}
    return {
        "role": "user",
        "content": [
            {"type": "text", "text": text},
            {"type": "image_url", "image_url": {"url": image}},
        ],
    }


def build_messages(
    action: str,
    text: str,
    target_language: str,
    image: str | None,
    history: list[dict] | None = None,
    voice: bool = False,
) -> list[dict]:
    instruction = ACTION_PROMPTS[action].format(language=target_language)
    rules = f"{STYLE_RULE}\n\n{instruction}"
    if voice:
        rules += f"\n\n{VOICE_RULE}"
    earlier = list(history or []) if action in CONVERSATIONAL_ACTIONS else []
    return [{"role": "developer", "content": rules}, *earlier, user_message(text, image)]


def parse_history(value) -> list[dict]:
    """Validate earlier conversation turns sent by the page."""
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > MAX_HISTORY_MESSAGES:
        raise BadRequest(f"History must be a list of at most {MAX_HISTORY_MESSAGES} messages.")
    turns = []
    for item in value:
        if (
            not isinstance(item, dict)
            or item.get("role") not in ("user", "assistant")
            or not isinstance(item.get("content"), str)
            or not item["content"].strip()
            or len(item["content"]) > MAX_HISTORY_CHARS
        ):
            raise BadRequest("Invalid conversation history.")
        turns.append({"role": item["role"], "content": item["content"]})
    return turns


def build_auto_messages(text: str, has_result: bool, has_image: bool) -> list[dict]:
    prompt = AUTO_PROMPT.format(
        has_result="yes" if has_result else "no",
        has_image="yes" if has_image else "no",
    )
    return [{"role": "developer", "content": prompt}, {"role": "user", "content": text}]


def resolve_auto(intent: dict, transcript: str, current_result: str | None) -> dict:
    """Turn the classifier's answer into one concrete step."""
    action = intent.get("action")
    content = str(intent.get("content") or "").strip()
    question = str(intent.get("clarification_question") or "").strip()
    current = (current_result or "").strip()

    def clarify(fallback: str) -> dict:
        return {"type": "clarify", "question": question or fallback}

    if action == "clarify":
        return clarify("Could you say a bit more about what you want me to do?")
    if action == "save_result_as_text_file":
        text = content or current
        if not text:
            return {"type": "clarify", "question": "There is no result to save yet. Run another action first, or say what to save."}
        return {"type": "save", "text": text}
    if action not in EXECUTABLE_ACTIONS:
        return clarify("I couldn't tell what you want me to do. Could you rephrase it?")

    language = str(intent.get("target_language") or "").strip()
    if action == "translate" and not TARGET_LANGUAGE.match(language):
        return clarify("Which language should I translate into?")
    if content:
        source = content
    elif action in ("translate", "rewrite", "summarize") and current:
        source = current
    else:
        source = transcript
    return {"type": "execute", "action": action, "text": source, "targetLanguage": language}


def run_request(body: dict, api_key: str, opener) -> dict:
    action = body.get("action")
    text = str(body.get("text") or "").strip()
    image = body.get("image") or None
    current_result = body.get("currentResult") or None
    target_language = str(body.get("targetLanguage") or "English").strip()
    history = parse_history(body.get("history"))
    voice = body.get("voice") is True

    if action not in ACTION_LABELS:
        raise BadRequest("Unknown action.")
    if not text:
        raise BadRequest("The transcript is empty.")
    if image is not None and (not isinstance(image, str) or not IMAGE_DATA_URL.match(image)):
        raise BadRequest("The image must be a PNG, JPEG, GIF or WebP data URL.")
    if not TARGET_LANGUAGE.match(target_language):
        raise BadRequest("Unsupported target language.")

    note = None
    if action == "auto":
        classified = chat(
            build_auto_messages(text, bool(current_result), bool(image)),
            api_key, opener, AUTO_RESPONSE_FORMAT, FAST_REASONING,
        )
        try:
            intent = json.loads(classified["text"])
        except ValueError:
            raise UpstreamError(0, "Auto mode got an answer it couldn't parse. Pick an action manually.") from None
        plan = resolve_auto(intent, text, current_result)
        if plan["type"] == "clarify":
            return {"kind": "clarify", "question": plan["question"], "note": "Auto: needs clarification"}
        if plan["type"] == "save":
            return {"kind": "save", "text": plan["text"], "note": "Auto: save as a text file"}
        action, text, target_language = plan["action"], plan["text"], plan["targetLanguage"] or target_language
        label = f"Translate ({target_language})" if action == "translate" else ACTION_LABELS[action]
        note = f"Auto: {label}"

    # Spoken turns favor speed; typed requests keep the model's default depth.
    effort = FAST_REASONING if voice else None
    answer = chat(build_messages(action, text, target_language, image, history, voice), api_key, opener, reasoning_effort=effort)
    return {"kind": "result", "text": answer["text"], "model": answer["model"], "truncated": answer["truncated"], "note": note}


# ---------------------------------------------------------------------------
# Realtime transcription relay
#
# The page streams one spoken turn over a WebSocket to this server, which
# forwards it to Meta's realtime endpoint. The key only appears in the
# handshake this server sends to Meta, never in anything sent to the page.


def parse_languages(value) -> list[str]:
    if value is None:
        return []
    if (
        not isinstance(value, list)
        or len(value) > MAX_LANGUAGE_HINTS
        or any(name not in SPEECH_LANGUAGES for name in value)
    ):
        raise BadRequest("Unsupported speech language hint.")
    return list(value)


def open_realtime(api_key: str, languages: list[str], connect) -> tuple[ws.WebSocket, str]:
    """Open a Meta realtime session in ENDPOINTING mode; returns (socket, sessionId)."""
    try:
        upstream = connect(f"{REALTIME_URL}?sessionId=nova-{uuid.uuid4().hex}")
    except (OSError, ws.HandshakeError) as exc:
        raise UpstreamError(0, f"Couldn't open Meta's realtime session ({exc.__class__.__name__}).") from None
    handshake = {
        "authorization": {"accessToken": f"Bearer {api_key}"},
        "audioEncoding": "PCM_24KHZ",
        "model": TRANSCRIBE_MODEL,
        "mode": "ENDPOINTING",
        "partialMode": "CUMULATIVE",
        "emitAudioProgress": False,
    }
    if languages:
        handshake["languageBias"] = languages
    try:
        upstream.sock.settimeout(REALTIME_HANDSHAKE_SECONDS)
        upstream.send_text(json.dumps(handshake))
        _, payload = upstream.recv()
        upstream.sock.settimeout(None)
        ack = json.loads(payload)
    except ws.WebSocketClosed as closed:
        upstream.shutdown()
        reason = redact(closed.reason, api_key)
        raise UpstreamError(closed.code or 0, f"Meta closed the realtime session ({closed.code}). {reason}".strip()) from None
    except (OSError, ValueError):
        upstream.shutdown()
        raise UpstreamError(0, "Meta's realtime session didn't answer the handshake.") from None
    if not isinstance(ack, dict) or "sessionId" not in ack:
        upstream.shutdown()
        message = ack.get("message") if isinstance(ack, dict) else None
        raise UpstreamError(0, redact(str(message or "Meta rejected the realtime handshake."), api_key))
    return upstream, str(ack["sessionId"])


def relay_realtime(browser: ws.WebSocket, env_file: Path, connect) -> None:
    """Run one realtime turn: page audio to Meta, Meta events back to the page."""

    def send_event(event: dict) -> None:
        try:
            browser.send_text(json.dumps(event))
        except (OSError, ws.WebSocketClosed):
            pass

    api_key = ""
    try:
        opcode, payload = browser.recv()
        config = json.loads(payload) if opcode == ws.OP_TEXT else None
        if not isinstance(config, dict):
            raise BadRequest("The first message must be the JSON configuration.")
        languages = parse_languages(config.get("languages"))
        api_key = load_api_key(env_file)
        upstream, session_id = open_realtime(api_key, languages, connect)
    except ConfigError as exc:
        send_event({"type": "error", "kind": "setup", "message": str(exc)})
        return
    except BadRequest as exc:
        send_event({"type": "error", "kind": "request", "message": str(exc)})
        return
    except UpstreamError as exc:
        send_event({"type": "error", "kind": "upstream", "message": exc.message})
        return
    except (ValueError, OSError, ws.WebSocketClosed):
        return

    send_event({"type": "ready", "sessionId": session_id, "model": TRANSCRIBE_MODEL})
    upstream_done = threading.Event()

    def pump_events() -> None:
        try:
            while True:
                opcode, payload = upstream.recv()
                if opcode != ws.OP_TEXT:
                    continue
                event = json.loads(payload)
                if not isinstance(event, dict):
                    continue
                if event.get("type") == "error":
                    event = {"type": "error", "kind": "upstream", "message": redact(str(event.get("message", "")), api_key)}
                send_event(event)
        except ws.WebSocketClosed as closed:
            if closed.code not in (None, 1000):
                reason = redact(closed.reason, api_key)
                send_event({"type": "error", "kind": "upstream", "message": f"Meta closed the realtime session ({closed.code}). {reason}".strip()})
        except (OSError, ValueError):
            pass
        finally:
            upstream_done.set()
            send_event({"type": "closed"})
            browser.close()

    threading.Thread(target=pump_events, daemon=True).start()

    deadline = time.monotonic() + REALTIME_MAX_SECONDS
    try:
        while not upstream_done.is_set() and time.monotonic() < deadline:
            opcode, payload = browser.recv()
            if opcode == ws.OP_BINARY:
                upstream.send_binary(payload)
            elif opcode == ws.OP_TEXT and json.loads(payload).get("type") == "endStream":
                break
    except (ws.WebSocketClosed, OSError, ValueError, AttributeError):
        pass
    try:
        upstream.send_text(json.dumps({"type": "endStream"}))
    except (OSError, ws.WebSocketClosed):
        pass
    # Let Meta flush the final transcript, then make sure both sides are closed.
    upstream_done.wait(timeout=10)
    upstream.close()
    upstream.shutdown()
    browser.close()


# ---------------------------------------------------------------------------
# HTTP server

CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}
CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; "
    "media-src 'self' blob:; connect-src 'self' {websockets}; frame-ancestors 'none'; base-uri 'none'"
)


class NovaServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port: int, env_file: Path, opener=urllib.request.urlopen, ws_connect=ws.connect):
        super().__init__(("127.0.0.1", port), NovaHandler)
        self.env_file = env_file
        self.opener = opener
        self.ws_connect = ws_connect
        bound = self.server_address[1]
        self.allowed_hosts = {f"127.0.0.1:{bound}", f"localhost:{bound}"}
        self.allowed_origins = {f"http://{host}" for host in self.allowed_hosts}


class NovaHandler(BaseHTTPRequestHandler):
    server: NovaServer
    server_version = "NovaPrototype/0.1"

    # Requests only from this machine's own pages: the Host check blocks DNS
    # rebinding, the Origin check blocks other websites posting to localhost.
    def _host_ok(self) -> bool:
        if self.headers.get("Host") in self.server.allowed_hosts:
            return True
        self._json(403, {"error": {"kind": "request", "message": "Unexpected Host header."}})
        return False

    def _origin_ok(self) -> bool:
        if self.headers.get("Origin") in self.server.allowed_origins:
            return True
        self._json(403, {"error": {"kind": "request", "message": "Requests must come from the Nova page."}})
        return False

    def do_GET(self) -> None:
        if not self._host_ok():
            return
        path = self.path.split("?", 1)[0]
        if path == "/api/status":
            self._json(200, self._status())
        elif path == "/api/realtime":
            self._realtime()
        else:
            self._static(path)

    def _realtime(self) -> None:
        if not self._origin_ok():
            return
        key = self.headers.get("Sec-WebSocket-Key")
        if self.headers.get("Upgrade", "").lower() != "websocket" or not key:
            self._json(400, {"error": {"kind": "request", "message": "Expected a WebSocket upgrade."}})
            return
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", ws.accept_key(key))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        browser = ws.WebSocket(self.rfile, self.connection, mask_outgoing=False)
        try:
            relay_realtime(browser, self.server.env_file, self.server.ws_connect)
        finally:
            browser.close()

    def do_POST(self) -> None:
        if not self._host_ok() or not self._origin_ok():
            return
        path, _, query = self.path.partition("?")
        try:
            if path == "/api/transcribe":
                payload = self._transcribe(query)
            elif path == "/api/run":
                payload = self._run()
            else:
                self._json(404, {"error": {"kind": "request", "message": "Not found."}})
                return
            self._json(200, payload)
        except ConfigError as exc:
            self._json(503, {"error": {"kind": "setup", "message": str(exc)}})
        except BadRequest as exc:
            self._json(400, {"error": {"kind": "request", "message": str(exc)}})
        except UpstreamError as exc:
            self._json(502, {"error": {"kind": "upstream", "status": exc.status, "code": exc.code, "message": exc.message}})
        except (BrokenPipeError, ConnectionResetError):
            pass  # the page canceled the request

    def _status(self) -> dict:
        try:
            load_api_key(self.server.env_file)
            loaded, message = True, None
        except ConfigError as exc:
            loaded, message = False, str(exc)
        return {
            "keyLoaded": loaded,
            "message": message,
            "models": {"transcription": TRANSCRIBE_MODEL, "reasoning": REASONING_MODEL},
        }

    def _read_body(self, limit: int) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise BadRequest("Missing Content-Length.") from None
        if length <= 0:
            raise BadRequest("The request body is empty.")
        if length > limit:
            raise BadRequest(f"The upload is larger than {limit // (1024 * 1024)} MB.")
        return self.rfile.read(length)

    def _transcribe(self, query: str) -> dict:
        if self.headers.get("Content-Type") != "audio/wav":
            raise BadRequest("Audio must be sent as audio/wav.")
        wav = self._read_body(MAX_AUDIO_BYTES)
        if wav[:4] != b"RIFF" or wav[8:12] != b"WAVE":
            raise BadRequest("The audio is not a WAV file.")
        requested = parse_qs(query).get("languages", [""])[0]
        languages = [name.strip() for name in requested.split(",") if name.strip()]
        if any(name not in SPEECH_LANGUAGES for name in languages):
            raise BadRequest("Unsupported speech language hint.")
        api_key = load_api_key(self.server.env_file)
        return transcribe(wav, languages, api_key, self.server.opener)

    def _run(self) -> dict:
        if self.headers.get("Content-Type") != "application/json":
            raise BadRequest("Send JSON.")
        try:
            body = json.loads(self._read_body(MAX_RUN_BYTES))
        except ValueError:
            raise BadRequest("Invalid JSON.") from None
        if not isinstance(body, dict):
            raise BadRequest("Invalid request.")
        api_key = load_api_key(self.server.env_file)
        return run_request(body, api_key, self.server.opener)

    def _static(self, path: str) -> None:
        name = "index.html" if path in ("", "/") else path.lstrip("/")
        target = (STATIC_DIR / name).resolve()
        if STATIC_DIR not in target.parents or not target.is_file():
            self._json(404, {"error": {"kind": "request", "message": "Not found."}})
            return
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPES.get(target.suffix, "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        websockets = " ".join(f"ws://{host}" for host in sorted(self.server.allowed_hosts))
        self.send_header("Content-Security-Policy", CSP.format(websockets=websockets))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args) -> None:
        # Method, path and status only; bodies (audio, text, images) are never logged.
        sys.stderr.write(f"{self.log_date_time_string()} {format % args}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Nova local web prototype.")
    parser.add_argument("--port", type=int, default=int(os.environ.get("NOVA_PORT", DEFAULT_PORT)))
    args = parser.parse_args()
    env_file = Path(os.environ.get("NOVA_ENV_FILE", DEFAULT_ENV_FILE)).expanduser()
    server = NovaServer(args.port, env_file)
    print(f"Nova prototype: http://127.0.0.1:{args.port}  (key file: {env_file})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
