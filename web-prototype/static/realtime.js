// Streams one spoken turn to Muse Voice Transcribe's realtime endpoint
// through the local server, which holds the API key. Meta detects the end of
// speech itself (ENDPOINTING mode) and sends the final transcript.

import { toPcm16 } from "./audio-utils.js";

export class RealtimeTurn {
  constructor({ languages = [], onPartial } = {}) {
    this.onPartial = onPartial;
    this.queue = [];
    this.ready = false;
    this.ended = false;
    this.settled = false;
    this.finalText = null;
    this.lastPartial = "";
    this.error = null;
    this.done = new Promise((resolve) => {
      this.resolve = resolve;
    });

    this.socket = new WebSocket(`ws://${location.host}/api/realtime`);
    this.socket.binaryType = "arraybuffer";
    this.socket.onopen = () => this.socket.send(JSON.stringify({ languages }));
    this.socket.onmessage = (message) => {
      try {
        this.handle(JSON.parse(message.data));
      } catch {
        // Ignore anything that isn't a JSON event.
      }
    };
    this.socket.onclose = () => this.settle();
    this.socket.onerror = () => {
      this.error ??= { kind: "network", message: "The realtime connection failed." };
    };
  }

  handle(event) {
    switch (event.type) {
      case "ready":
        this.ready = true;
        for (const chunk of this.queue) this.socket.send(chunk);
        this.queue = [];
        if (this.ended) this.sendEnd();
        break;
      case "transcript":
        if (event.transcript) {
          this.lastPartial = event.transcript;
          this.onPartial?.(event.transcript);
        }
        break;
      case "speechComplete":
        if (this.finalText === null && event.transcript?.trim()) {
          this.finalText = event.transcript.trim();
          this.end();
          this.settle();
        }
        break;
      case "error":
        this.error = { kind: event.kind, message: event.message };
        this.settle();
        break;
      default:
        break; // speechStart, speechEnd, closed, and future event types
    }
  }

  /** Queue or send one frame of mono float samples at 24 kHz. */
  pushFrame(samples) {
    if (this.ended || this.socket.readyState > WebSocket.OPEN) return;
    const pcm = toPcm16(samples);
    if (this.ready && this.socket.readyState === WebSocket.OPEN) this.socket.send(pcm);
    else this.queue.push(pcm);
  }

  /** Stop sending audio; Meta flushes the final transcript and closes. */
  end() {
    if (this.ended) return;
    this.ended = true;
    if (this.ready) this.sendEnd();
  }

  sendEnd() {
    if (this.socket.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify({ type: "endStream" }));
  }

  abort() {
    this.ended = true;
    this.socket.close();
    this.settle();
  }

  // Resolves `done` once with { text, complete, error }.
  settle() {
    if (this.settled) return;
    this.settled = true;
    const text = this.finalText ?? (this.lastPartial.trim() || null);
    this.resolve({ text, complete: this.finalText !== null, error: this.error });
  }
}
