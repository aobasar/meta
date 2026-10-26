import assert from "node:assert/strict";
import test from "node:test";

import { guessSpeechLanguage, looksLikeEcho, rms, splitForSpeech, VoiceActivityDetector } from "../static/voice-utils.js";

// Feed `ms` worth of 20 ms frames at one level; return the events seen.
function feed(vad, level, ms, options) {
  const events = [];
  for (let t = 0; t < ms; t += 20) {
    const event = vad.push(level, options);
    if (event) events.push(event);
  }
  return events;
}

test("rms of a constant signal is its magnitude", () => {
  assert.equal(rms(new Float32Array([0.5, -0.5, 0.5, -0.5])), 0.5);
  assert.equal(rms(new Float32Array(0)), 0);
});

test("detector reports start after sustained speech and end after silence", () => {
  const vad = new VoiceActivityDetector();
  assert.deepEqual(feed(vad, 0.003, 1000), [], "background noise is not speech");
  assert.deepEqual(feed(vad, 0.1, 400), ["start"]);
  assert.deepEqual(feed(vad, 0.1, 400), [], "no repeated start while speaking");
  assert.deepEqual(feed(vad, 0.003, 600), [], "a short pause does not end the turn");
  assert.deepEqual(feed(vad, 0.1, 200), []);
  assert.deepEqual(feed(vad, 0.003, 1400), ["end"]);
});

test("a brief click does not start speech", () => {
  const vad = new VoiceActivityDetector();
  feed(vad, 0.003, 500);
  assert.deepEqual(feed(vad, 0.2, 100), []);
  assert.deepEqual(feed(vad, 0.003, 500), []);
});

test("strict mode needs louder and longer speech", () => {
  const level = 0.003 * 4.5; // above the normal threshold, below the strict one
  const normal = new VoiceActivityDetector();
  feed(normal, 0.003, 1000);
  assert.deepEqual(feed(normal, level, 400), ["start"]);

  const strict = new VoiceActivityDetector();
  feed(strict, 0.003, 1000);
  assert.deepEqual(feed(strict, level, 400, { strict: true }), []);
  assert.deepEqual(feed(strict, 0.2, 200, { strict: true }), [], "loud but too short");
  assert.deepEqual(feed(strict, 0.2, 300, { strict: true }), ["start"]);
});

test("the noise floor adapts to a louder room", () => {
  const vad = new VoiceActivityDetector();
  feed(vad, 0.02, 3000); // steady fan noise
  assert.deepEqual(feed(vad, 0.03, 600), [], "slightly louder noise is not speech");
  assert.deepEqual(feed(vad, 0.2, 400), ["start"]);
});

test("looksLikeEcho matches Nova's own words, not new requests", () => {
  const spoken = "Tomorrow in Paris it will be sunny with a high of 21 degrees.";
  assert.equal(looksLikeEcho("it will be sunny with a high", spoken), true);
  assert.equal(looksLikeEcho("Stop, what about London?", spoken), false);
  assert.equal(looksLikeEcho("sunny", spoken), false, "one word is too little to judge");
  assert.equal(looksLikeEcho("anything", ""), false);
});

test("guessSpeechLanguage picks Turkish or English", () => {
  assert.equal(guessSpeechLanguage("Yarın saat üçte buluşalım."), "tr-TR");
  assert.equal(guessSpeechLanguage("Bu bir test ve sorun yok"), "tr-TR");
  assert.equal(guessSpeechLanguage("See you tomorrow at three."), "en-US");
});

test("splitForSpeech drops list markers and keeps chunks short", () => {
  assert.deepEqual(splitForSpeech("- First point\n- Second point"), ["First point. Second point"]);
  assert.deepEqual(splitForSpeech("1. Open Calendar.\n2. Pick a time."), ["Open Calendar. Pick a time."]);
  const long = "This sentence is fairly long. ".repeat(20);
  const chunks = splitForSpeech(long, 100);
  assert.ok(chunks.length > 1);
  assert.ok(chunks.every((chunk) => chunk.length <= 100));
  assert.equal(chunks.join(" ").replace(/\s+/g, " ").trim(), long.trim());
  assert.deepEqual(splitForSpeech(""), []);
});
