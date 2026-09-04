import test from "node:test";
import assert from "node:assert/strict";
import {
  MAX_MODEL_ROWS,
  decodeDeliveryFailure,
  decodeDeliveryResult,
  decodeTranscriptReady,
  decodeTranscriptionFailure,
  encodeDeliveryRequest,
  encodeTranscriptionRequest,
  parseModelRows,
} from "../src/protocol.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const bytes = (value: string) => encoder.encode(value);
const jsonBytes = (value: unknown) => bytes(JSON.stringify(value));

test("transcript and request codecs preserve arbitrary UTF-8 and exact identity", () => {
  const text = 'Say "hello" \\ path/next\nemoji 🧑🏽‍💻 and cafe\u0301';
  const decoded = decodeTranscriptReady(jsonBytes({
    ok: true,
    sessionId: 42,
    generation: 77,
    text,
    silence: false,
  }));
  assert.notEqual(decoded, null);
  assert.equal(decoder.decode(decoded!.text), text);
  assert.equal(decoded!.sessionId, 42);
  assert.equal(decoded!.generation, 77);
  assert.equal(decoder.decode(encodeTranscriptionRequest(42, 77)!), "session=42;generation=77");
  assert.equal(decoder.decode(encodeDeliveryRequest(42, 77, false)!), "session=42;generation=77;paste=0");
  assert.equal(encodeTranscriptionRequest(0, 1), null);
  assert.equal(encodeDeliveryRequest(1.5, 1, true), null);
});

test("JSON string decoding handles escapes and surrogate pairs without normalization", () => {
  const decoded = decodeTranscriptReady(bytes('{"sessionId":1,"generation":2,"silence":false,"text":"quote: \\" slash: \\\\ solidus: \\/ line:\\n emoji: \\uD83D\\uDE00 combining: e\\u0301"}'));
  assert.notEqual(decoded, null);
  assert.equal(decoder.decode(decoded!.text), 'quote: " slash: \\ solidus: / line:\n emoji: 😀 combining: e\u0301');
});

test("transcript codecs reject malformed, duplicate, wrong-type, and overflow fields", () => {
  const malformed = [
    '{"sessionId":1,"generation":2,"silence":false,"text":"bad\\q"}',
    '{"sessionId":1,"generation":2,"silence":false,"text":"\\uD800"}',
    '{"sessionId":1,"sessionId":1,"generation":2,"silence":false,"text":"ok"}',
    '{"sessionId":1,"\\u0073essionId":1,"generation":2,"silence":false,"text":"ok"}',
    '{"sessionId":"1","generation":2,"silence":false,"text":"ok"}',
    '{"sessionId":9007199254740992,"generation":2,"silence":false,"text":"ok"}',
    '{"sessionId":1,"generation":2,"silence":false,"text":""}',
    '{"sessionId":1,"generation":2,"silence":true,"text":"not silence"}',
    '{"sessionId":1,"generation":2,"silence":false,"text":"unterminated}',
  ];
  for (const value of malformed) assert.equal(decodeTranscriptReady(bytes(value)), null, value);
  const invalidUtf8 = bytes('{"sessionId":1,"generation":2,"silence":false,"text":"x"}');
  invalidUtf8[invalidUtf8.length - 3] = 0xff;
  assert.equal(decodeTranscriptReady(invalidUtf8), null);
});

test("delivery codecs preserve shown text and structured native reasons", () => {
  const text = 'final "words" \\ next\n👩🏾‍🚀 e\u0301';
  const reason = 'Clipboard said "no"\nTry Copy.';
  const shown = decodeDeliveryResult(jsonBytes({ kind: "shown", ok: false, message: reason, sessionId: 8, generation: 9, text }));
  assert.notEqual(shown, null);
  assert.equal(shown!.kind, "shown");
  assert.equal(decoder.decode(shown!.text), text);
  assert.equal(decoder.decode(shown!.message), reason);

  const failed = decodeDeliveryFailure(jsonBytes({ ok: false, sessionId: 8, generation: 9, message: reason, text }));
  assert.notEqual(failed, null);
  assert.equal(failed!.hasIdentity, true);
  assert.equal(decoder.decode(failed!.text), text);
  assert.equal(decoder.decode(failed!.message), reason);

  const hostFailure = decodeDeliveryFailure(jsonBytes({ ok: false, code: "delivery_failed", message: reason }));
  assert.notEqual(hostFailure, null);
  assert.equal(hostFailure!.hasIdentity, false);
  assert.equal(hostFailure!.text.length, 0);
});

test("delivery and transcription failure codecs reject malformed contracts", () => {
  assert.equal(decodeDeliveryResult(bytes('{"kind":"other","message":"x","sessionId":1,"generation":2,"text":"x"}')), null);
  assert.equal(decodeDeliveryResult(bytes('{"kind":"shown","message":"x","sessionId":1,"generation":2}')), null);
  assert.equal(decodeDeliveryFailure(bytes('{"message":"x","sessionId":1}')), null);
  assert.equal(decodeTranscriptionFailure(bytes('{"sessionId":1,"generation":2,"retryAudioAvailable":"yes","message":"x"}')), null);
  const failure = decodeTranscriptionFailure(jsonBytes({ sessionId: 1, generation: 2, retryAudioAvailable: true, message: "model \\ failed" }));
  assert.notEqual(failure, null);
  assert.equal(failure!.retryAudioAvailable, true);
  assert.equal(decoder.decode(failure!.message), "model \\ failed");
});

test("model row codec keeps an explicit bounded 128-row library reachable", () => {
  const models = Array.from({ length: MAX_MODEL_ROWS + 1 }, (_, index) => ({
    modelKey: 1000 + index,
    displayName: index === 9 ? 'Model "ten" \\ 🦜\nline' : `Model ${index + 1}`,
    sourceLabel: "Local file · reference only",
    license: "CC-BY-4.0",
    languageSummary: "1 language",
    sizeText: "700 MB",
    managed: index % 2 === 0,
    active: false,
  }));
  const rows = parseModelRows(jsonBytes({ ok: true, models }));
  assert.equal(rows.length, MAX_MODEL_ROWS);
  assert.equal(decoder.decode(rows[9].name), models[9].displayName);
  assert.equal(decoder.decode(rows[MAX_MODEL_ROWS - 1].modelKey), "1127");
  assert.equal(rows[10].managed, true);
});

test("model row codec rejects malformed rows instead of returning partial data", () => {
  const body = bytes('{"models":[{"modelKey":1000,"displayName":"ok","sourceLabel":"local","license":"x","languageSummary":"1","sizeText":"1 MB","managed":false,"active":false},{"modelKey":1001,"displayName":"bad\\q","sourceLabel":"local","license":"x","languageSummary":"1","sizeText":"1 MB","managed":false,"active":false}]}');
  assert.deepEqual(parseModelRows(body), []);
});
