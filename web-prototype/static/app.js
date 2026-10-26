import { computeBars, encodeWav16, formatTime } from "./audio-utils.js";

const SAMPLE_RATE = 24000; // Muse Voice Transcribe's native rate
const MAX_SECONDS = 600; // Meta's limit per clip
const MAX_WAV_BYTES = 32 * 1024 * 1024;
const MAX_IMAGE_EDGE = 2048;
const BAR_COUNT = 44;

const ACTION_LABELS = {
  auto: "Auto",
  ask: "Ask",
  translate: "Translate",
  rewrite: "Rewrite",
  summarize: "Summarize",
  plan_task: "Plan task",
};
const ACTION_ANGLES = { ask: 0, translate: 60, rewrite: 120, summarize: 180, plan_task: 240, auto: 300 };

const PHASES = {
  idle: { label: "Ready", tone: "" },
  recording: { label: "Recording", tone: "recording" },
  preparing: { label: "Preparing audio…", tone: "busy" },
  ready: { label: "Ready to send", tone: "ready" },
  transcribing: { label: "Transcribing…", tone: "busy" },
  transcribed: { label: "Transcript ready", tone: "ready" },
  processing: { label: "Processing…", tone: "busy" },
  completed: { label: "Completed", tone: "done" },
  clarify: { label: "Needs clarification", tone: "clarify" },
  saving: { label: "Saving…", tone: "busy" },
  error: { label: "Error", tone: "error" },
};
const BUSY_PHASES = new Set(["preparing", "transcribing", "processing", "saving"]);

const state = {
  phase: "idle",
  action: "auto",
  clip: null, // { blob, url, seconds, bars }
  image: null, // { dataUrl, name }
  result: "",
  resultIsQuestion: false,
  model: "",
  note: "",
  saved: "",
  notice: "",
  error: "",
  keyLoaded: null,
  setupMessage: "",
  recordStartedAt: 0,
};

let recorder = null;
let stream = null;
let chunks = [];
let discardRecording = false;
let recordTimer = null;
let controller = null;
let pendingSaveText = "";

const $ = (id) => document.getElementById(id);
const el = {
  settingsButton: $("settingsButton"), settings: $("settings"), speechHint: $("speechHint"), recheckKey: $("recheckKey"),
  setup: $("setup"), setupText: $("setupText"),
  ring: $("ring"), sectors: [...document.querySelectorAll(".sector")],
  mic: $("mic"), micIcon: $("micIcon"), stopIcon: $("stopIcon"), micTime: $("micTime"),
  play: $("play"), playIcon: $("playIcon"), pauseIcon: $("pauseIcon"), wave: $("wave"), clipTime: $("clipTime"), player: $("player"),
  newRecording: $("newRecording"), newRecordingLabel: $("newRecordingLabel"), addAudio: $("addAudio"), audioFile: $("audioFile"),
  transcribe: $("transcribe"),
  error: $("error"), errorText: $("errorText"), dismissError: $("dismissError"),
  imageChip: $("imageChip"), imageThumb: $("imageThumb"), imageName: $("imageName"), removeImage: $("removeImage"),
  attachImage: $("attachImage"), imageFile: $("imageFile"),
  transcript: $("transcript"), actionLabel: $("actionLabel"), langWrap: $("langWrap"), lang: $("lang"), run: $("run"),
  status: $("status"), statusText: $("statusText"), note: $("note"), result: $("result"), saved: $("saved"), notice: $("notice"),
  modelLabel: $("modelLabel"), copy: $("copy"), save: $("save"),
  keyDot: $("keyDot"), keyText: $("keyText"), cancel: $("cancel"),
  stageAudio: $("stageAudio"), stageText: $("stageText"), stageResult: $("stageResult"),
  saveModal: $("saveModal"), savePreview: $("savePreview"), saveCancel: $("saveCancel"), saveConfirm: $("saveConfirm"),
};

// ---------------------------------------------------------------------------
// State helpers

const isBusy = () => BUSY_PHASES.has(state.phase);
const isRecording = () => state.phase === "recording";
const hasResult = () => state.result.length > 0 && !state.resultIsQuestion;

function setPhase(phase) {
  state.phase = phase;
  render();
}

function clearMessages() {
  state.error = "";
  state.notice = "";
  state.saved = "";
}

function fail(message) {
  state.error = message;
  setPhase("error");
}

// The phase to fall back to after a cancel or a dismissed error.
function restingPhase() {
  if (el.transcript.value.trim()) return "transcribed";
  return state.clip ? "ready" : "idle";
}

class RequestError extends Error {
  constructor(message, kind) {
    super(message);
    this.kind = kind;
  }
}

async function readJson(response) {
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const message = data?.error?.message || `The local server answered with HTTP ${response.status}.`;
    throw new RequestError(message, data?.error?.kind);
  }
  return data;
}

function handleRequestError(err, canceledNotice) {
  if (err.name === "AbortError") {
    state.notice = canceledNotice;
    setPhase(restingPhase());
    return;
  }
  if (err instanceof TypeError) {
    fail("Couldn't reach the local Star server. Is it still running?");
    return;
  }
  if (err.kind === "setup") refreshKeyStatus();
  fail(err.message);
}

// ---------------------------------------------------------------------------
// Key status (reads the local file through the server; never calls Meta)

async function refreshKeyStatus() {
  try {
    const data = await readJson(await fetch("/api/status"));
    state.keyLoaded = data.keyLoaded;
    state.setupMessage = data.message || "";
  } catch {
    state.keyLoaded = false;
    state.setupMessage = "Couldn't reach the local Star server.";
  }
  render();
}

// ---------------------------------------------------------------------------
// Recording and audio files

async function startRecording() {
  clearMessages();
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
  } catch (err) {
    fail(
      err.name === "NotAllowedError"
        ? "Microphone access was denied. Allow it in the browser's site settings and, if macOS asks, in System Settings › Privacy & Security › Microphone."
        : `Couldn't start the microphone (${err.name}).`
    );
    return;
  }
  chunks = [];
  discardRecording = false;
  recorder = new MediaRecorder(stream);
  recorder.ondataavailable = (event) => {
    if (event.data.size > 0) chunks.push(event.data);
  };
  recorder.onstop = onRecordingStopped;
  recorder.start();
  state.recordStartedAt = Date.now();
  setPhase("recording");
  recordTimer = setInterval(() => {
    if (elapsedSeconds() >= MAX_SECONDS) stopRecording(false);
    else render();
  }, 250);
}

function elapsedSeconds() {
  return (Date.now() - state.recordStartedAt) / 1000;
}

function stopRecording(discard) {
  discardRecording = discard;
  clearInterval(recordTimer);
  recordTimer = null;
  if (recorder && recorder.state !== "inactive") recorder.stop();
  stream?.getTracks().forEach((track) => track.stop());
  stream = null;
}

async function onRecordingStopped() {
  const blob = new Blob(chunks, { type: recorder?.mimeType || "audio/webm" });
  chunks = [];
  recorder = null;
  if (discardRecording) {
    state.notice = "Recording discarded. Nothing was sent.";
    setPhase(restingPhase());
    return;
  }
  await prepareAudio(blob);
}

// Decode any format the browser understands, then resample to 24 kHz mono
// and encode 16-bit PCM WAV, the only input Muse Voice Transcribe accepts.
async function prepareAudio(blob) {
  setPhase("preparing");
  try {
    const context = new AudioContext();
    let decoded;
    try {
      decoded = await context.decodeAudioData(await blob.arrayBuffer());
    } finally {
      context.close();
    }
    if (decoded.duration > MAX_SECONDS) throw new Error("The audio is longer than 10 minutes, Meta's limit per clip.");
    if (decoded.duration < 0.3) throw new Error("The recording is too short.");
    const offline = new OfflineAudioContext(1, Math.ceil(decoded.duration * SAMPLE_RATE), SAMPLE_RATE);
    const source = offline.createBufferSource();
    source.buffer = decoded;
    source.connect(offline.destination);
    source.start();
    const samples = (await offline.startRendering()).getChannelData(0);
    const wav = encodeWav16(samples, SAMPLE_RATE);
    if (wav.byteLength > MAX_WAV_BYTES) throw new Error("The converted audio is larger than 32 MB.");
    replaceClip({ blob: new Blob([wav], { type: "audio/wav" }), seconds: decoded.duration, bars: computeBars(samples, BAR_COUNT) });
    setPhase("ready");
  } catch (err) {
    fail(`Couldn't use that audio: ${err.message}`);
  }
}

function replaceClip(clip) {
  if (state.clip) URL.revokeObjectURL(state.clip.url);
  el.player.pause();
  clip.url = URL.createObjectURL(clip.blob);
  el.player.src = clip.url;
  state.clip = clip;
}

// ---------------------------------------------------------------------------
// Meta calls through the local server

async function transcribe() {
  if (!state.clip || isBusy() || isRecording()) return;
  clearMessages();
  setPhase("transcribing");
  controller = new AbortController();
  try {
    const hint = el.speechHint.value;
    const url = "/api/transcribe" + (hint ? `?languages=${encodeURIComponent(hint)}` : "");
    const data = await readJson(
      await fetch(url, { method: "POST", headers: { "Content-Type": "audio/wav" }, body: state.clip.blob, signal: controller.signal })
    );
    el.transcript.value = data.transcript;
    setPhase("transcribed");
  } catch (err) {
    handleRequestError(err, "Transcription canceled. Meta may still finish the request, but its answer is ignored.");
  } finally {
    controller = null;
  }
}

async function run() {
  const text = el.transcript.value.trim();
  if (!text || isBusy() || isRecording()) return;
  clearMessages();
  setPhase("processing");
  controller = new AbortController();
  try {
    const body = {
      action: state.action,
      text,
      targetLanguage: el.lang.value,
      image: state.image?.dataUrl ?? null,
      currentResult: hasResult() ? state.result : null,
    };
    const data = await readJson(
      await fetch("/api/run", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal: controller.signal })
    );
    state.note = data.note || "";
    if (data.kind === "result") {
      state.result = data.text;
      state.resultIsQuestion = false;
      state.model = data.model;
      if (data.truncated) state.note = `${state.note ? `${state.note} · ` : ""}The answer hit the length limit and may be cut off.`;
      setPhase("completed");
    } else if (data.kind === "clarify") {
      state.result = data.question;
      state.resultIsQuestion = true;
      setPhase("clarify");
    } else if (data.kind === "save") {
      setPhase("completed");
      openSaveModal(data.text);
    }
  } catch (err) {
    handleRequestError(err, "Canceled. Meta may still finish the request, but its answer is ignored.");
  } finally {
    controller = null;
  }
}

// ---------------------------------------------------------------------------
// Saving: show the exact content, let macOS pick the location, then read the
// file back and compare before calling it saved.

function openSaveModal(text) {
  pendingSaveText = text;
  el.savePreview.textContent = text;
  el.saveModal.hidden = false;
  el.saveConfirm.focus();
}

async function confirmSave() {
  const text = pendingSaveText;
  el.saveModal.hidden = true;
  if (!window.showSaveFilePicker) {
    downloadFallback(text);
    return;
  }
  let handle;
  try {
    handle = await window.showSaveFilePicker({
      suggestedName: "Star result.txt",
      types: [{ description: "Text file", accept: { "text/plain": [".txt"] } }],
    });
  } catch (err) {
    if (err.name === "AbortError") {
      state.notice = "Save canceled. Nothing was written.";
      render();
    } else {
      fail(`Couldn't open the save dialog (${err.name}).`);
    }
    return;
  }
  clearMessages();
  setPhase("saving");
  try {
    const writable = await handle.createWritable();
    await writable.write(text);
    await writable.close();
    const readBack = await (await handle.getFile()).text();
    if (readBack !== text) throw new Error("the file on disk doesn't match what Star wrote");
    const bytes = new TextEncoder().encode(text).length;
    state.saved = `Saved and verified: “${handle.name}” in the folder you chose · ${bytes} bytes.`;
    setPhase("completed");
  } catch (err) {
    fail(`Saving failed: ${err.message}. The file may be missing or incomplete.`);
  }
}

function downloadFallback(text) {
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "Star result.txt";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  state.notice = "Handed to the browser as a download. This browser can't confirm the write, so it isn't marked as saved. Use Chrome or Edge for a verified save.";
  render();
}

// ---------------------------------------------------------------------------
// Images

async function attachImage(blob, name) {
  try {
    const bitmap = await createImageBitmap(blob);
    const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close();
    state.image = { dataUrl: canvas.toDataURL("image/png"), name };
    state.notice = "";
    render();
  } catch {
    fail("Couldn't read that image. Use PNG, JPEG, GIF or WebP.");
  }
}

// ---------------------------------------------------------------------------
// Rendering

function render() {
  const phase = PHASES[state.phase];
  const busy = isBusy();
  const recording = isRecording();

  el.statusText.textContent = phase.label;
  el.status.className = `pill ${phase.tone}`;

  // Radial menu
  const center = ACTION_ANGLES[state.action];
  el.ring.style.background =
    "repeating-conic-gradient(from -30deg, rgba(0,0,0,0) 0deg 59.4deg, rgba(160,185,225,0.7) 59.4deg 60deg), " +
    `conic-gradient(from ${center - 30}deg, rgba(120,170,255,0.38) 0deg 60deg, rgba(255,255,255,0.82) 60deg 360deg)`;
  for (const sector of el.sectors) sector.setAttribute("aria-pressed", String(sector.dataset.action === state.action));
  el.actionLabel.textContent = ACTION_LABELS[state.action];
  el.langWrap.hidden = state.action !== "translate";

  // Microphone and clip
  el.mic.classList.toggle("recording", recording);
  el.mic.setAttribute("aria-label", recording ? "Stop recording" : "Start recording");
  el.mic.disabled = busy;
  el.micIcon.hidden = recording;
  el.stopIcon.hidden = !recording;
  el.micTime.hidden = !recording;
  el.micTime.textContent = formatTime(recording ? elapsedSeconds() : 0);
  el.newRecording.disabled = busy;
  el.newRecordingLabel.textContent = recording ? "Stop recording" : "New recording";
  el.addAudio.disabled = busy || recording;
  el.play.disabled = !state.clip || recording;
  el.transcribe.disabled = !state.clip || busy || recording;
  el.clipTime.textContent = formatTime(recording ? elapsedSeconds() : state.clip?.seconds ?? 0);
  renderWave();

  // Transcript and result
  el.attachImage.disabled = busy;
  el.imageChip.hidden = !state.image;
  if (state.image) {
    el.imageThumb.src = state.image.dataUrl;
    el.imageName.textContent = state.image.name;
  }
  el.run.disabled = busy || recording || el.transcript.value.trim().length === 0;
  el.result.textContent = state.result || "Results appear here after you press Run.";
  el.result.classList.toggle("empty", !state.result);
  el.result.classList.toggle("question", state.resultIsQuestion);
  showText(el.note, state.note);
  showText(el.saved, state.saved);
  showText(el.notice, state.notice);
  el.modelLabel.textContent = hasResult() ? `AI-generated by ${state.model}. Check it before you rely on it.` : "";
  el.copy.disabled = !hasResult() || busy;
  el.save.disabled = !hasResult() || busy;
  el.error.hidden = !state.error;
  el.errorText.textContent = state.error;

  // Status bar
  el.cancel.hidden = !(busy || recording) || state.phase === "preparing" || state.phase === "saving";
  el.keyDot.className = `dot ${state.keyLoaded === null ? "" : state.keyLoaded ? "ok" : "missing"}`;
  el.keyText.textContent =
    state.keyLoaded === null ? "Checking the API key…" : state.keyLoaded ? "API key loaded from .env.local" : "API key missing";
  el.setup.hidden = state.keyLoaded !== false;
  el.setupText.textContent = state.setupMessage;
  el.stageAudio.classList.toggle("active", ["recording", "preparing", "ready"].includes(state.phase));
  el.stageText.classList.toggle("active", ["transcribing", "transcribed"].includes(state.phase));
  el.stageResult.classList.toggle("active", ["processing", "completed", "clarify", "saving"].includes(state.phase));
}

function showText(node, text) {
  node.hidden = !text;
  node.textContent = text;
}

function renderWave() {
  const bars = state.clip?.bars ?? new Array(BAR_COUNT).fill(0);
  if (el.wave.children.length !== BAR_COUNT) {
    el.wave.replaceChildren(...bars.map(() => Object.assign(document.createElement("span"), { className: "bar" })));
  }
  const progress = state.clip && !el.player.paused ? el.player.currentTime / Math.max(0.1, state.clip.seconds) : 0;
  [...el.wave.children].forEach((bar, i) => {
    bar.style.height = `${state.clip ? 6 + Math.round(bars[i] * 34) : 4}px`;
    bar.classList.toggle("on", Boolean(state.clip));
    bar.classList.toggle("played", Boolean(state.clip) && i / BAR_COUNT < progress);
  });
  el.playIcon.hidden = !el.player.paused;
  el.pauseIcon.hidden = el.player.paused;
  el.play.setAttribute("aria-label", el.player.paused ? "Play recording" : "Pause playback");
}

// ---------------------------------------------------------------------------
// Events

el.settingsButton.addEventListener("click", () => {
  el.settings.hidden = !el.settings.hidden;
  el.settingsButton.setAttribute("aria-expanded", String(!el.settings.hidden));
});
el.recheckKey.addEventListener("click", refreshKeyStatus);

for (const sector of el.sectors) {
  sector.addEventListener("click", () => {
    state.action = sector.dataset.action;
    render();
  });
}

const toggleRecording = () => {
  if (isBusy()) return;
  if (isRecording()) stopRecording(false);
  else startRecording();
};
el.mic.addEventListener("click", toggleRecording);
el.newRecording.addEventListener("click", toggleRecording);

el.addAudio.addEventListener("click", () => el.audioFile.click());
el.audioFile.addEventListener("change", () => {
  const file = el.audioFile.files[0];
  el.audioFile.value = "";
  if (file) {
    clearMessages();
    prepareAudio(file);
  }
});

el.play.addEventListener("click", () => {
  if (!state.clip) return;
  if (el.player.paused) el.player.play();
  else el.player.pause();
});
for (const event of ["play", "pause", "ended", "timeupdate"]) el.player.addEventListener(event, renderWave);

el.transcribe.addEventListener("click", transcribe);
el.run.addEventListener("click", run);
el.transcript.addEventListener("input", render);

el.cancel.addEventListener("click", () => {
  if (isRecording()) stopRecording(true);
  else controller?.abort();
});
el.dismissError.addEventListener("click", () => {
  state.error = "";
  setPhase(restingPhase());
});

el.attachImage.addEventListener("click", () => el.imageFile.click());
el.imageFile.addEventListener("change", () => {
  const file = el.imageFile.files[0];
  el.imageFile.value = "";
  if (file) attachImage(file, file.name);
});
el.removeImage.addEventListener("click", () => {
  state.image = null;
  render();
});
document.addEventListener("paste", (event) => {
  const item = [...(event.clipboardData?.items ?? [])].find((entry) => entry.type.startsWith("image/"));
  if (!item) return;
  event.preventDefault();
  attachImage(item.getAsFile(), "Pasted image");
});

el.copy.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(state.result);
    state.notice = "Copied to the clipboard.";
  } catch {
    state.notice = "The browser blocked clipboard access. Select the text and copy it instead.";
  }
  render();
});
el.save.addEventListener("click", () => {
  if (hasResult()) openSaveModal(state.result);
});
el.saveCancel.addEventListener("click", () => {
  el.saveModal.hidden = true;
  state.notice = "Save canceled. Nothing was written.";
  render();
});
el.saveConfirm.addEventListener("click", confirmSave);

render();
refreshKeyStatus();
