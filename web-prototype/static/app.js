import { computeBars, encodeWav16, formatTime } from "./audio-utils.js";
import { RealtimeTurn } from "./realtime.js";
import { Speaker } from "./speaker.js";
import { looksLikeEcho, rms, VoiceActivityDetector } from "./voice-utils.js";

const SAMPLE_RATE = 24000; // Muse Voice Transcribe's native rate
const MAX_SECONDS = 600; // Meta's limit per clip
const MAX_WAV_BYTES = 32 * 1024 * 1024;
const MAX_IMAGE_EDGE = 2048;
const BAR_COUNT = 44;

// Conversation mode
const FRAME_MS = 20; // pcm-worklet.js posts 480-sample frames at 24 kHz
const PREROLL_FRAMES = 20; // keep 400 ms before speech starts so the first word isn't clipped
const MIN_UTTERANCE_SECONDS = 0.4;
const MAX_UTTERANCE_FRAMES = (60 * 1000) / FRAME_MS;
const IDLE_LIMIT_MS = 60 * 1000; // end the conversation after a minute without speech
const MAX_HISTORY_MESSAGES = 12;
const REALTIME_FLUSH_MS = 2500; // how long to wait for Meta's final transcript after local end-of-speech

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
  listening: { label: "Listening…", tone: "live" },
  hearing: { label: "Hearing you…", tone: "recording" },
  speaking: { label: "Speaking…", tone: "live" },
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

// Live conversation session; everything here lives in memory only and is
// dropped when the conversation ends.
const convo = {
  active: false,
  context: null,
  stream: null,
  node: null,
  vad: null,
  preroll: [],
  utterance: [],
  capturing: false,
  turnId: 0,
  turnController: null,
  history: [],
  spokenText: "",
  pausedForBargeIn: false,
  lastActivity: 0,
  idleTimer: null,
  level: 0,
  realtime: null, // RealtimeTurn streaming the current utterance, if any
  inflightText: "", // transcript of the turn waiting for an answer
  carry: "", // that transcript, kept when the user keeps talking over it
};

let recorder = null;
let stream = null;
let chunks = [];
let discardRecording = false;
let recordTimer = null;
let controller = null;
let pendingSaveText = "";
const speaker = new Speaker();

const $ = (id) => document.getElementById(id);
const el = {
  settingsButton: $("settingsButton"), settings: $("settings"), speechHint: $("speechHint"), recheckKey: $("recheckKey"),
  speakReplies: $("speakReplies"), realtimeAsr: $("realtimeAsr"),
  setup: $("setup"), setupText: $("setupText"),
  ring: $("ring"), sectors: [...document.querySelectorAll(".sector")],
  mic: $("mic"), micIcon: $("micIcon"), stopIcon: $("stopIcon"), micTime: $("micTime"), micHint: $("micHint"),
  play: $("play"), playIcon: $("playIcon"), pauseIcon: $("pauseIcon"), wave: $("wave"), clipTime: $("clipTime"), player: $("player"),
  newRecording: $("newRecording"), newRecordingLabel: $("newRecordingLabel"), addAudio: $("addAudio"), audioFile: $("audioFile"),
  transcribe: $("transcribe"),
  error: $("error"), errorText: $("errorText"), dismissError: $("dismissError"),
  imageChip: $("imageChip"), imageThumb: $("imageThumb"), imageName: $("imageName"), removeImage: $("removeImage"),
  attachImage: $("attachImage"), imageFile: $("imageFile"),
  transcript: $("transcript"), actionLabel: $("actionLabel"), langWrap: $("langWrap"), lang: $("lang"), run: $("run"),
  status: $("status"), statusText: $("statusText"), note: $("note"), result: $("result"), saved: $("saved"), notice: $("notice"),
  modelLabel: $("modelLabel"), readAloud: $("readAloud"), copy: $("copy"), save: $("save"),
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
  constructor(message, kind, code) {
    super(message);
    this.kind = kind;
    this.code = code;
  }
}

async function readJson(response) {
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const message = data?.error?.message || `The local server answered with HTTP ${response.status}.`;
    throw new RequestError(message, data?.error?.kind, data?.error?.code);
  }
  return data;
}

function handleRequestError(err, canceledNotice) {
  if (err.name === "AbortError") {
    state.notice = canceledNotice;
    setPhase(restingPhase());
    return;
  }
  fail(describeError(err));
}

function describeError(err) {
  if (err instanceof TypeError) return "Couldn't reach the local Nova server. Is it still running?";
  if (err.kind === "setup") refreshKeyStatus();
  return err.message;
}

function languageHints() {
  return el.speechHint.value ? el.speechHint.value.split(",") : [];
}

function postTranscribe(wavBlob, signal) {
  const hint = el.speechHint.value;
  const url = "/api/transcribe" + (hint ? `?languages=${encodeURIComponent(hint)}` : "");
  return fetch(url, { method: "POST", headers: { "Content-Type": "audio/wav" }, body: wavBlob, signal }).then(readJson);
}

function postRun(text, signal, extra = {}) {
  const body = {
    action: state.action,
    text,
    targetLanguage: el.lang.value,
    image: state.image?.dataUrl ?? null,
    currentResult: hasResult() ? state.result : null,
    ...extra,
  };
  return fetch("/api/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  }).then(readJson);
}

// Apply a /api/run answer to the result card. Returns the text to speak, if any.
function applyRunResult(data) {
  state.note = data.note || "";
  if (data.kind === "result") {
    state.result = data.text;
    state.resultIsQuestion = false;
    state.model = data.model;
    if (data.truncated) state.note = `${state.note ? `${state.note} · ` : ""}The answer hit the length limit and may be cut off.`;
    setPhase("completed");
    return data.text;
  }
  if (data.kind === "clarify") {
    state.result = data.question;
    state.resultIsQuestion = true;
    setPhase("clarify");
    return data.question;
  }
  if (data.kind === "save") {
    setPhase("completed");
    openSaveModal(data.text);
    return "The text is ready to save. Confirm it on the screen.";
  }
  return "";
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
    state.setupMessage = "Couldn't reach the local Nova server.";
  }
  render();
}

function micErrorMessage(err) {
  return err.name === "NotAllowedError"
    ? "Microphone access was denied. Allow it in the browser's site settings and, if macOS asks, in System Settings › Privacy & Security › Microphone."
    : `Couldn't start the microphone (${err.name}).`;
}

// ---------------------------------------------------------------------------
// Single recording (New recording button)

async function startRecording() {
  clearMessages();
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
  } catch (err) {
    fail(micErrorMessage(err));
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
// Manual flow: Send for transcription, then Run

async function transcribe() {
  if (!state.clip || isBusy() || isRecording() || convo.active) return;
  clearMessages();
  setPhase("transcribing");
  controller = new AbortController();
  try {
    const data = await postTranscribe(state.clip.blob, controller.signal);
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
  if (!text || isBusy() || isRecording() || convo.active) return;
  clearMessages();
  setPhase("processing");
  controller = new AbortController();
  try {
    applyRunResult(await postRun(text, controller.signal));
  } catch (err) {
    handleRequestError(err, "Canceled. Meta may still finish the request, but its answer is ignored.");
  } finally {
    controller = null;
  }
}

// ---------------------------------------------------------------------------
// Conversation mode: one tap starts it. Nova listens, sends each utterance
// when you stop talking, answers out loud, and listens again. Talking while
// Nova speaks interrupts it. Tap again, or stay quiet for a minute, to end.

async function startConversation() {
  clearMessages();
  let micStream;
  try {
    micStream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
  } catch (err) {
    fail(micErrorMessage(err));
    return;
  }
  try {
    const context = new AudioContext({ sampleRate: SAMPLE_RATE });
    await context.audioWorklet.addModule("/pcm-worklet.js");
    const node = new AudioWorkletNode(context, "pcm-capture");
    const mute = context.createGain();
    mute.gain.value = 0;
    context.createMediaStreamSource(micStream).connect(node);
    node.connect(mute).connect(context.destination); // keeps the worklet running without playing the mic
    node.port.onmessage = (event) => onConversationFrame(event.data);
    Object.assign(convo, {
      active: true, context, stream: micStream, node, vad: new VoiceActivityDetector({ frameMs: FRAME_MS }),
      preroll: [], utterance: [], capturing: false, history: [], spokenText: "", pausedForBargeIn: false,
      lastActivity: Date.now(),
    });
    convo.idleTimer = setInterval(checkIdle, 1000);
    state.notice = "Conversation on. Speak naturally; Nova answers when you pause. Headphones keep Nova from hearing itself.";
    setPhase("listening");
  } catch (err) {
    micStream.getTracks().forEach((track) => track.stop());
    fail(`Couldn't start conversation mode (${err.message}).`);
  }
}

function stopConversation(notice = "Conversation ended. The microphone is off.") {
  if (!convo.active) return;
  convo.active = false;
  convo.turnId += 1;
  convo.turnController?.abort();
  convo.turnController = null;
  convo.realtime?.abort();
  speaker.cancel();
  clearInterval(convo.idleTimer);
  convo.node?.port.close();
  convo.node?.disconnect();
  convo.stream?.getTracks().forEach((track) => track.stop());
  convo.context?.close();
  Object.assign(convo, {
    context: null, stream: null, node: null, vad: null, preroll: [], utterance: [], capturing: false, history: [], level: 0,
    realtime: null, inflightText: "", carry: "",
  });
  state.notice = notice;
  setPhase(restingPhase());
}

function checkIdle() {
  if (convo.active && state.phase === "listening" && Date.now() - convo.lastActivity > IDLE_LIMIT_MS) {
    stopConversation("Conversation ended after a minute of silence. The microphone is off.");
  }
}

function onConversationFrame(frame) {
  if (!convo.active) return;
  const level = rms(frame);
  convo.level = level;
  convo.preroll.push(frame);
  if (convo.preroll.length > PREROLL_FRAMES) convo.preroll.shift();
  if (convo.capturing) {
    convo.utterance.push(frame);
    convo.realtime?.pushFrame(frame);
  }

  let event = convo.vad.push(level, { strict: state.phase === "speaking" });
  if (convo.capturing && convo.utterance.length >= MAX_UTTERANCE_FRAMES) {
    convo.vad.reset();
    event = "end";
  }
  if (event === "start") onSpeechStart();
  else if (event === "end" && convo.capturing) finishUtterance();
  updateMicGlow();
}

function onSpeechStart() {
  convo.lastActivity = Date.now();
  if (state.phase === "speaking") {
    // Barge-in: pause first; if it turns out to be Nova's own echo, resume.
    speaker.pause();
    convo.pausedForBargeIn = true;
  } else if (state.phase === "transcribing" || state.phase === "processing") {
    // The user kept talking: drop the pending answer, keep what they said so
    // far, and take it together with the new speech.
    convo.carry = convo.inflightText;
    convo.turnId += 1;
    convo.turnController?.abort();
  }
  convo.capturing = true;
  convo.utterance = [...convo.preroll];
  convo.realtime = el.realtimeAsr.checked ? startRealtime() : null;
  for (const frame of convo.preroll) convo.realtime?.pushFrame(frame);
  setPhase("hearing");
}

// Stream the utterance to Meta while the user talks. Meta's own end-of-speech
// detection usually finishes the turn before the local silence timer does.
function startRealtime() {
  const realtime = new RealtimeTurn({
    languages: languageHints(),
    onPartial: (text) => {
      if (convo.realtime === realtime && convo.capturing) {
        el.transcript.value = convo.carry ? `${convo.carry} ${text}` : text;
      }
    },
  });
  realtime.done.then((outcome) => {
    if (convo.realtime === realtime && convo.capturing && outcome.complete) finishUtterance();
  });
  return realtime;
}

function finishUtterance() {
  convo.capturing = false;
  convo.lastActivity = Date.now();
  convo.vad.reset();
  const realtime = convo.realtime;
  convo.realtime = null;
  const frames = convo.utterance;
  convo.utterance = [];
  const samples = new Float32Array(frames.reduce((total, frame) => total + frame.length, 0));
  let offset = 0;
  for (const frame of frames) {
    samples.set(frame, offset);
    offset += frame.length;
  }
  if (samples.length < SAMPLE_RATE * MIN_UTTERANCE_SECONDS && !realtime?.finalText) {
    realtime?.abort();
    resumeAfterNoise();
    return;
  }
  handleTurn(samples, realtime);
}

const within = (promise, ms) => Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve(null), ms))]);

// A false start (a cough, a click, Nova's echo): carry on as before.
function resumeAfterNoise() {
  if (convo.pausedForBargeIn) {
    convo.pausedForBargeIn = false;
    speaker.resume();
    setPhase("speaking");
  } else {
    setPhase("listening");
  }
}

async function handleTurn(samples, realtime) {
  const turn = ++convo.turnId;
  const turnController = new AbortController();
  convo.turnController = turnController;
  const wav = new Blob([encodeWav16(samples, SAMPLE_RATE)], { type: "audio/wav" });
  replaceClip({ blob: wav, seconds: samples.length / SAMPLE_RATE, bars: computeBars(samples, BAR_COUNT) });
  clearMessages();
  setPhase("transcribing");
  try {
    // Prefer the realtime transcript; fall back to uploading the clip.
    let heard = null;
    if (realtime) {
      realtime.end();
      const outcome = await within(realtime.done, REALTIME_FLUSH_MS);
      if (outcome?.error?.kind === "setup") throw new RequestError(outcome.error.message, "setup");
      heard = outcome?.text ?? null;
      if (!outcome?.complete) realtime.abort();
    }
    if (turn !== convo.turnId) return;
    if (!heard) heard = (await postTranscribe(wav, turnController.signal)).transcript;
    if (turn !== convo.turnId) return;
    if (convo.pausedForBargeIn && looksLikeEcho(heard, convo.spokenText)) {
      resumeAfterNoise();
      return;
    }
    if (convo.pausedForBargeIn) {
      speaker.cancel();
      convo.pausedForBargeIn = false;
    }
    if (convo.carry) {
      heard = `${convo.carry} ${heard}`;
      convo.carry = "";
    }
    convo.inflightText = heard;
    el.transcript.value = heard;
    setPhase("processing");
    const data = await postRun(heard, turnController.signal, { history: convo.history, voice: true });
    if (turn !== convo.turnId) return;
    convo.inflightText = "";
    const reply = applyRunResult(data);
    if (data.kind === "result" || data.kind === "clarify") {
      convo.history.push({ role: "user", content: heard }, { role: "assistant", content: reply });
      convo.history = convo.history.slice(-MAX_HISTORY_MESSAGES);
    }
    speakReply(reply);
  } catch (err) {
    if (err.name === "AbortError" || turn !== convo.turnId) return;
    if (err.code === "empty_transcript") {
      resumeAfterNoise();
      return;
    }
    const message = describeError(err);
    stopConversation("");
    fail(message);
  } finally {
    if (convo.turnController === turnController) convo.turnController = null;
  }
}

function speakReply(text) {
  if (!convo.active) return;
  if (!text || !el.speakReplies.checked || !speaker.available) {
    setPhase("listening");
    return;
  }
  convo.spokenText = text;
  convo.vad.reset();
  speaker.speak(text, () => {
    if (convo.active && state.phase === "speaking") {
      convo.lastActivity = Date.now();
      setPhase("listening");
    }
  });
  if (speaker.missingVoice === "tr-TR") {
    state.notice = "No Turkish system voice found. Add one in System Settings › Accessibility › Spoken Content › System Voice.";
  }
  setPhase("speaking");
}

function updateMicGlow() {
  const live = convo.active && (state.phase === "listening" || state.phase === "hearing");
  const ring = live ? 10 + Math.min(18, Math.round(convo.level * 400)) : 10;
  el.mic.style.setProperty("--glow", `${ring}px`);
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
      suggestedName: "Nova result.txt",
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
  const resumeTo = convo.active ? state.phase : null;
  clearMessages();
  setPhase("saving");
  try {
    const writable = await handle.createWritable();
    await writable.write(text);
    await writable.close();
    const readBack = await (await handle.getFile()).text();
    if (readBack !== text) throw new Error("the file on disk doesn't match what Nova wrote");
    const bytes = new TextEncoder().encode(text).length;
    state.saved = `Saved and verified: “${handle.name}” in the folder you chose · ${bytes} bytes.`;
    setPhase(resumeTo ?? "completed");
  } catch (err) {
    fail(`Saving failed: ${err.message}. The file may be missing or incomplete.`);
  }
}

function downloadFallback(text) {
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "Nova result.txt";
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
  const talking = convo.active;

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

  // Microphone: in conversation mode it ends the conversation; during a
  // single recording it stops that recording.
  const stopMode = talking || recording;
  el.mic.classList.toggle("recording", recording || state.phase === "hearing");
  el.mic.classList.toggle("live", talking && state.phase !== "hearing");
  el.mic.setAttribute("aria-label", talking ? "End conversation" : recording ? "Stop recording" : "Start conversation");
  el.mic.disabled = (busy && !talking) || state.phase === "preparing";
  el.micIcon.hidden = stopMode;
  el.stopIcon.hidden = !stopMode;
  el.micTime.hidden = !recording;
  el.micTime.textContent = formatTime(recording ? elapsedSeconds() : 0);
  el.micHint.textContent = talking ? "Tap to end the conversation" : recording ? "Tap to stop recording" : "Tap to talk with Nova";
  updateMicGlow();
  el.newRecording.disabled = busy || talking;
  el.newRecordingLabel.textContent = recording ? "Stop recording" : "New recording";
  el.addAudio.disabled = busy || recording || talking;
  el.play.disabled = !state.clip || recording;
  el.transcribe.disabled = !state.clip || busy || recording || talking;
  el.clipTime.textContent = formatTime(recording ? elapsedSeconds() : state.clip?.seconds ?? 0);
  renderWave();

  // Transcript and result
  el.attachImage.disabled = busy;
  el.imageChip.hidden = !state.image;
  if (state.image) {
    el.imageThumb.src = state.image.dataUrl;
    el.imageName.textContent = state.image.name;
  }
  el.run.disabled = busy || recording || talking || el.transcript.value.trim().length === 0;
  el.result.textContent = state.result || "Results appear here after you press Run.";
  el.result.classList.toggle("empty", !state.result);
  el.result.classList.toggle("question", state.resultIsQuestion);
  showText(el.note, state.note);
  showText(el.saved, state.saved);
  showText(el.notice, state.notice);
  el.modelLabel.textContent = hasResult() ? `AI-generated by ${state.model}. Check it before you rely on it.` : "";
  el.readAloud.disabled = !state.result || talking || !speaker.available;
  el.copy.disabled = !hasResult() || busy;
  el.save.disabled = !hasResult() || busy;
  el.error.hidden = !state.error;
  el.errorText.textContent = state.error;

  // Status bar
  el.cancel.textContent = talking ? "End conversation" : "Cancel";
  el.cancel.hidden = !(talking || ((busy || recording) && state.phase !== "preparing" && state.phase !== "saving"));
  el.keyDot.className = `dot ${state.keyLoaded === null ? "" : state.keyLoaded ? "ok" : "missing"}`;
  el.keyText.textContent =
    state.keyLoaded === null ? "Checking the API key…" : state.keyLoaded ? "API key loaded from .env.local" : "API key missing";
  el.setup.hidden = state.keyLoaded !== false;
  el.setupText.textContent = state.setupMessage;
  el.stageAudio.classList.toggle("active", ["recording", "preparing", "ready", "listening", "hearing"].includes(state.phase));
  el.stageText.classList.toggle("active", ["transcribing", "transcribed"].includes(state.phase));
  el.stageResult.classList.toggle("active", ["processing", "completed", "clarify", "saving", "speaking"].includes(state.phase));
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

el.mic.addEventListener("click", () => {
  if (isRecording()) stopRecording(false);
  else if (convo.active) stopConversation();
  else if (!isBusy()) startConversation();
});
el.newRecording.addEventListener("click", () => {
  if (isBusy() || convo.active) return;
  if (isRecording()) stopRecording(false);
  else startRecording();
});

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
  if (convo.active) stopConversation();
  else if (isRecording()) stopRecording(true);
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

el.readAloud.addEventListener("click", () => {
  if (state.result && !convo.active) speaker.speak(state.result);
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
