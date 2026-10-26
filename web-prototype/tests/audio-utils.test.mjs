import assert from "node:assert/strict";
import test from "node:test";

import { computeBars, encodeWav16, formatTime } from "../static/audio-utils.js";

const ascii = (view, offset, length) =>
  String.fromCharCode(...Array.from({ length }, (_, i) => view.getUint8(offset + i)));

test("encodeWav16 writes a mono 16-bit PCM WAV header", () => {
  const samples = new Float32Array([0, 0.5, -0.5, 1, -1, 2]);
  const view = new DataView(encodeWav16(samples, 24000));
  assert.equal(ascii(view, 0, 4), "RIFF");
  assert.equal(ascii(view, 8, 4), "WAVE");
  assert.equal(ascii(view, 12, 4), "fmt ");
  assert.equal(view.getUint16(20, true), 1, "PCM");
  assert.equal(view.getUint16(22, true), 1, "mono");
  assert.equal(view.getUint32(24, true), 24000, "sample rate");
  assert.equal(view.getUint32(28, true), 48000, "byte rate");
  assert.equal(view.getUint16(34, true), 16, "bits per sample");
  assert.equal(ascii(view, 36, 4), "data");
  assert.equal(view.getUint32(40, true), samples.length * 2);
  assert.equal(view.getUint32(4, true), 36 + samples.length * 2);
  assert.equal(view.byteLength, 44 + samples.length * 2);
});

test("encodeWav16 converts and clamps sample values", () => {
  const view = new DataView(encodeWav16(new Float32Array([0, 0.5, -0.5, 1, -1, 2]), 24000));
  const values = Array.from({ length: 6 }, (_, i) => view.getInt16(44 + i * 2, true));
  assert.deepEqual(values, [0, 16384, -16384, 32767, -32768, 32767]);
});

test("computeBars scales the loudest bucket to 1", () => {
  const samples = new Float32Array(100).map((_, i) => (i < 50 ? 0.1 : 0.4));
  const bars = computeBars(samples, 4);
  assert.equal(bars.length, 4);
  assert.equal(Math.max(...bars), 1);
  assert.ok(bars[0] < bars[3]);
});

test("computeBars handles silence and empty input", () => {
  assert.deepEqual(computeBars(new Float32Array(10), 2), [0, 0]);
  assert.deepEqual(computeBars(new Float32Array(0), 3), [0, 0, 0]);
});

test("formatTime pads minutes and seconds", () => {
  assert.equal(formatTime(0), "00:00");
  assert.equal(formatTime(7.9), "00:07");
  assert.equal(formatTime(600), "10:00");
});
