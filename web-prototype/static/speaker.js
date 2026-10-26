// Speaks replies with the macOS system voices through the browser's speech
// synthesis. No model is involved: the voice comes from the operating system.

import { guessSpeechLanguage, splitForSpeech } from "./voice-utils.js";

export class Speaker {
  constructor() {
    this.synth = "speechSynthesis" in window ? window.speechSynthesis : null;
    this.token = 0;
    this.onDone = null;
    this.missingVoice = "";
    // Voices load asynchronously in Chrome; asking once starts the load.
    this.synth?.getVoices();
  }

  get available() {
    return Boolean(this.synth);
  }

  voiceFor(lang) {
    const voices = this.synth.getVoices();
    const base = lang.slice(0, 2);
    return (
      voices.find((voice) => voice.lang === lang && voice.localService) ||
      voices.find((voice) => voice.lang === lang) ||
      voices.find((voice) => voice.lang.startsWith(base)) ||
      null
    );
  }

  /** Speak text; onDone runs once when it finishes (not when canceled). */
  speak(text, onDone) {
    if (!this.synth) {
      onDone?.();
      return;
    }
    this.cancel();
    const token = ++this.token;
    const lang = guessSpeechLanguage(text);
    const voice = this.voiceFor(lang);
    this.missingVoice = voice ? "" : lang;
    this.onDone = onDone;
    const chunks = splitForSpeech(text);
    if (chunks.length === 0) {
      this.finish(token);
      return;
    }
    chunks.forEach((chunk, index) => {
      const utterance = new SpeechSynthesisUtterance(chunk);
      utterance.lang = lang;
      if (voice) utterance.voice = voice;
      if (index === chunks.length - 1) utterance.onend = () => this.finish(token);
      utterance.onerror = (event) => {
        if (event.error !== "interrupted" && event.error !== "canceled") this.finish(token);
      };
      this.synth.speak(utterance);
    });
  }

  pause() {
    this.synth?.pause();
  }

  resume() {
    this.synth?.resume();
  }

  cancel() {
    this.token += 1;
    this.onDone = null;
    this.synth?.cancel();
  }

  finish(token) {
    if (token !== this.token) return;
    const done = this.onDone;
    this.onDone = null;
    done?.();
  }
}
