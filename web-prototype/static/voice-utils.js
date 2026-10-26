// Pure helpers for conversation mode: voice activity detection, echo
// detection, and preparing replies for speech. No browser APIs, so they can be
// unit-tested in Node.

export function rms(frame) {
  let sum = 0;
  for (let i = 0; i < frame.length; i += 1) sum += frame[i] * frame[i];
  return frame.length ? Math.sqrt(sum / frame.length) : 0;
}

/**
 * Energy-based voice activity detector. Feed it the RMS of each audio frame;
 * it tracks the background noise level and reports when speech starts and
 * when it has ended (after a stretch of silence).
 *
 * "Strict" mode is for barge-in while Nova is speaking: it needs louder and
 * longer speech, so Nova's own voice from the speakers is less likely to
 * count as the user talking.
 */
export class VoiceActivityDetector {
  constructor({
    frameMs = 20,
    startRatio = 3.2,
    strictRatio = 6,
    minLevel = 0.004,
    minSpeechMs = 180,
    strictMinSpeechMs = 360,
    endSilenceMs = 900,
    floorAdapt = 0.05,
    warmupMs = 400,
  } = {}) {
    Object.assign(this, { frameMs, startRatio, strictRatio, minLevel, minSpeechMs, strictMinSpeechMs, endSilenceMs, floorAdapt, warmupMs });
    this.reset();
  }

  reset() {
    this.floor = this.minLevel;
    this.warmupLeftMs = this.warmupMs;
    this.inSpeech = false;
    this.aboveMs = 0;
    this.belowMs = 0;
  }

  /** Returns "start", "end" or null for one frame's RMS level. */
  push(level, { strict = false } = {}) {
    // Learn the room's noise level first, so steady noise isn't taken for speech.
    if (this.warmupLeftMs > 0) {
      this.warmupLeftMs -= this.frameMs;
      this.floor += (level - this.floor) * 0.3;
      return null;
    }
    const floor = Math.max(this.floor, this.minLevel);
    if (!this.inSpeech) {
      const threshold = floor * (strict ? this.strictRatio : this.startRatio);
      if (level > threshold) {
        this.aboveMs += this.frameMs;
        if (this.aboveMs >= (strict ? this.strictMinSpeechMs : this.minSpeechMs)) {
          this.inSpeech = true;
          this.belowMs = 0;
          return "start";
        }
      } else {
        this.aboveMs = 0;
        this.floor += (level - this.floor) * this.floorAdapt;
      }
      return null;
    }
    // Hysteresis: once speaking, a quieter level still counts as speech.
    const keepThreshold = floor * this.startRatio * 0.6;
    if (level > keepThreshold) {
      this.belowMs = 0;
    } else {
      this.belowMs += this.frameMs;
      if (this.belowMs >= this.endSilenceMs) {
        this.inSpeech = false;
        this.aboveMs = 0;
        return "end";
      }
    }
    return null;
  }
}

function words(text) {
  return (text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []);
}

/**
 * True when a transcript is mostly words Nova was just saying, which means
 * the microphone picked up Nova's own voice rather than the user.
 */
export function looksLikeEcho(transcript, spokenText) {
  const heard = words(transcript);
  if (heard.length < 2 || !spokenText) return false;
  const spoken = new Set(words(spokenText));
  const matches = heard.filter((word) => spoken.has(word)).length;
  return matches / heard.length >= 0.6;
}

const TURKISH_LETTERS = /[çğışöüÇĞİŞÖÜ]/;
const TURKISH_WORDS = /\b(ve|bir|bu|için|değil|ile|ama|evet|hayır|nasıl|neden|şu|çok)\b/i;

/** BCP 47 language for the system voice: Turkish or English. */
export function guessSpeechLanguage(text) {
  return TURKISH_LETTERS.test(text) || TURKISH_WORDS.test(text) ? "tr-TR" : "en-US";
}

/**
 * Split a reply into short chunks for speech synthesis. Long single
 * utterances get cut off in some browsers, and list markers read badly.
 */
export function splitForSpeech(text, maxLength = 220) {
  const cleaned = text
    .split("\n")
    .map((line) => line.replace(/^\s*(?:[-*•]|\d+[.)])\s+/, "").trim())
    .filter(Boolean)
    .join(". ")
    .replace(/[*_#`]/g, "")
    .replace(/\.\s*\./g, ".");
  const sentences = cleaned.match(/[^.!?…]+[.!?…]*/g) ?? [];
  const chunks = [];
  let current = "";
  for (const raw of sentences) {
    const sentence = raw.trim();
    if (!sentence) continue;
    if (current && (current + " " + sentence).length > maxLength) {
      chunks.push(current);
      current = sentence;
    } else {
      current = current ? `${current} ${sentence}` : sentence;
    }
    while (current.length > maxLength) {
      const cut = current.lastIndexOf(" ", maxLength);
      const at = cut > 0 ? cut : maxLength;
      chunks.push(current.slice(0, at).trim());
      current = current.slice(at).trim();
    }
  }
  if (current) chunks.push(current);
  return chunks;
}
