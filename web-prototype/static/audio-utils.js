// Pure helpers for audio handling, kept free of browser APIs so they can be
// unit-tested in Node.

/**
 * Encode mono float samples (-1...1) as a 16-bit PCM RIFF/WAVE file, the
 * format Muse Voice Transcribe accepts.
 */
export function encodeWav16(samples, sampleRate) {
  const dataBytes = samples.length * 2;
  const buffer = new ArrayBuffer(44 + dataBytes);
  const view = new DataView(buffer);
  writeAscii(view, 0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  writeAscii(view, 8, "WAVE");
  writeAscii(view, 12, "fmt ");
  view.setUint32(16, 16, true); // fmt chunk size
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true); // byte rate
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  writeAscii(view, 36, "data");
  view.setUint32(40, dataBytes, true);
  let offset = 44;
  for (let i = 0; i < samples.length; i += 1, offset += 2) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, s < 0 ? Math.round(s * 0x8000) : Math.round(s * 0x7fff), true);
  }
  return buffer;
}

/** Mono float samples (-1...1) as signed 16-bit little-endian PCM bytes. */
export function toPcm16(samples) {
  const view = new DataView(new ArrayBuffer(samples.length * 2));
  for (let i = 0; i < samples.length; i += 1) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(i * 2, s < 0 ? Math.round(s * 0x8000) : Math.round(s * 0x7fff), true);
  }
  return view.buffer;
}

function writeAscii(view, offset, text) {
  for (let i = 0; i < text.length; i += 1) view.setUint8(offset + i, text.charCodeAt(i));
}

/** Loudness per bucket, scaled so the loudest bucket is 1. */
export function computeBars(samples, count) {
  const bars = new Array(count).fill(0);
  if (samples.length === 0) return bars;
  const size = Math.max(1, Math.floor(samples.length / count));
  let peak = 0;
  for (let b = 0; b < count; b += 1) {
    const start = b * size;
    const end = Math.min(samples.length, start + size);
    let sum = 0;
    for (let i = start; i < end; i += 1) sum += samples[i] * samples[i];
    const rms = end > start ? Math.sqrt(sum / (end - start)) : 0;
    bars[b] = rms;
    peak = Math.max(peak, rms);
  }
  return peak > 0 ? bars.map((v) => v / peak) : bars;
}

export function formatTime(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}
