import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { Model, ModelRow } from "./core.ts";

const MAX_SAFE_INTEGER = 9007199254740991;
export const MAX_MODEL_ROWS = 128;

interface JsonStringMeasure {
  readonly length: number;
  readonly next: number;
}

interface JsonStringValue {
  readonly value: Uint8Array;
  readonly next: number;
}

interface JsonField {
  readonly present: boolean;
  readonly start: number;
  readonly end: number;
}

interface OptionalJsonString {
  readonly present: boolean;
  readonly value: Uint8Array;
}

export interface TranscriptReadyPayload {
  readonly sessionId: number;
  readonly generation: number;
  readonly silence: boolean;
  readonly text: Uint8Array;
}

export interface DeliveryResultPayload {
  readonly sessionId: number;
  readonly generation: number;
  readonly kind: "pasted" | "clipboard" | "shown";
  readonly message: Uint8Array;
  readonly text: Uint8Array;
}

export interface DeliveryFailurePayload {
  readonly hasIdentity: boolean;
  readonly sessionId: number;
  readonly generation: number;
  readonly message: Uint8Array;
  readonly text: Uint8Array;
}

export interface TranscriptionFailurePayload {
  readonly sessionId: number;
  readonly generation: number;
  readonly retryAudioAvailable: boolean;
  readonly message: Uint8Array;
}

export function hasPrefix(bytes: Uint8Array, prefix: Uint8Array): boolean {
  if (bytes.length < prefix.length) return false;
  for (let index = 0; index < prefix.length; index += 1) if (bytes[index] !== prefix[index]) return false;
  return true;
}

export function contains(bytes: Uint8Array, needle: Uint8Array): boolean {
  if (needle.length === 0) return true;
  if (bytes.length < needle.length) return false;
  for (let start = 0; start <= bytes.length - needle.length; start += 1) {
    let match = true;
    for (let index = 0; index < needle.length; index += 1) if (bytes[start + index] !== needle[index]) match = false;
    if (match) return true;
  }
  return false;
}

export function byteEquals(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) if (left[index] !== right[index]) return false;
  return true;
}

function skipWhitespace(bytes: Uint8Array, start: number): number {
  let at = start;
  while (at < bytes.length && (bytes[at] === 32 || bytes[at] === 9 || bytes[at] === 10 || bytes[at] === 13)) at += 1;
  return at;
}

function hexValue(byte: number): number {
  if (byte >= 48 && byte <= 57) return byte - 48;
  if (byte >= 65 && byte <= 70) return byte - 55;
  if (byte >= 97 && byte <= 102) return byte - 87;
  return -1;
}

function hexQuad(bytes: Uint8Array, start: number): number {
  if (start + 4 > bytes.length) return -1;
  const a = hexValue(bytes[start]);
  const b = hexValue(bytes[start + 1]);
  const c = hexValue(bytes[start + 2]);
  const d = hexValue(bytes[start + 3]);
  if (a < 0 || b < 0 || c < 0 || d < 0) return -1;
  return a * 4096 + b * 256 + c * 16 + d;
}

function utf8SequenceLength(bytes: Uint8Array, start: number, end: number): number {
  const first = bytes[start];
  if (first <= 127) return 1;
  if (first >= 194 && first <= 223) {
    if (start + 2 > end || bytes[start + 1] < 128 || bytes[start + 1] > 191) return 0;
    return 2;
  }
  if (first >= 224 && first <= 239) {
    if (start + 3 > end) return 0;
    const second = bytes[start + 1];
    const third = bytes[start + 2];
    if (third < 128 || third > 191) return 0;
    if (first === 224 && (second < 160 || second > 191)) return 0;
    if (first === 237 && (second < 128 || second > 159)) return 0;
    if (first !== 224 && first !== 237 && (second < 128 || second > 191)) return 0;
    return 3;
  }
  if (first >= 240 && first <= 244) {
    if (start + 4 > end) return 0;
    const second = bytes[start + 1];
    if (bytes[start + 2] < 128 || bytes[start + 2] > 191 || bytes[start + 3] < 128 || bytes[start + 3] > 191) return 0;
    if (first === 240 && (second < 144 || second > 191)) return 0;
    if (first === 244 && (second < 128 || second > 143)) return 0;
    if (first !== 240 && first !== 244 && (second < 128 || second > 191)) return 0;
    return 4;
  }
  return 0;
}

function codePointUtf8Length(codePoint: number): number {
  if (codePoint <= 127) return 1;
  if (codePoint <= 2047) return 2;
  if (codePoint <= 65535) return 3;
  return 4;
}

function measureJsonString(bytes: Uint8Array, start: number): JsonStringMeasure | null {
  if (start >= bytes.length || bytes[start] !== 34) return null;
  let at = start + 1;
  let length = 0;
  while (at < bytes.length) {
    const byte = bytes[at];
    if (byte === 34) return { length, next: at + 1 };
    if (byte < 32) return null;
    if (byte !== 92) {
      const sequenceLength = utf8SequenceLength(bytes, at, bytes.length);
      if (sequenceLength === 0) return null;
      length += sequenceLength;
      at += sequenceLength;
      continue;
    }
    at += 1;
    if (at >= bytes.length) return null;
    const escape = bytes[at];
    if (escape === 34 || escape === 92 || escape === 47 || escape === 98 || escape === 102 || escape === 110 || escape === 114 || escape === 116) {
      length += 1;
      at += 1;
      continue;
    }
    if (escape !== 117) return null;
    const first = hexQuad(bytes, at + 1);
    if (first < 0) return null;
    at += 5;
    let codePoint = first;
    if (first >= 55296 && first <= 56319) {
      if (at + 6 > bytes.length || bytes[at] !== 92 || bytes[at + 1] !== 117) return null;
      const second = hexQuad(bytes, at + 2);
      if (second < 56320 || second > 57343) return null;
      codePoint = 65536 + (first - 55296) * 1024 + second - 56320;
      at += 6;
    } else if (first >= 56320 && first <= 57343) return null;
    length += codePointUtf8Length(codePoint);
  }
  return null;
}

function parseJsonString(bytes: Uint8Array, start: number): JsonStringValue | null {
  const measured = measureJsonString(bytes, start);
  if (measured === null) return null;
  const value = new Uint8Array(measured.length);
  let at = start + 1;
  let output = 0;
  while (at < measured.next - 1) {
    const byte = bytes[at];
    if (byte !== 92) {
      const sequenceLength = utf8SequenceLength(bytes, at, measured.next - 1);
      for (let index = 0; index < sequenceLength; index += 1) value[output + index] = bytes[at + index];
      output += sequenceLength;
      at += sequenceLength;
      continue;
    }
    at += 1;
    const escape = bytes[at];
    if (escape === 34 || escape === 92 || escape === 47) {
      value[output] = escape;
      output += 1;
      at += 1;
      continue;
    }
    if (escape === 98 || escape === 102 || escape === 110 || escape === 114 || escape === 116) {
      value[output] = escape === 98 ? 8 : escape === 102 ? 12 : escape === 110 ? 10 : escape === 114 ? 13 : 9;
      output += 1;
      at += 1;
      continue;
    }
    const first = hexQuad(bytes, at + 1);
    at += 5;
    let codePoint = first;
    if (first >= 55296 && first <= 56319) {
      const second = hexQuad(bytes, at + 2);
      codePoint = 65536 + (first - 55296) * 1024 + second - 56320;
      at += 6;
    }
    if (codePoint <= 127) {
      value[output] = codePoint;
      output += 1;
    } else if (codePoint <= 2047) {
      value[output] = 192 + Math.trunc(codePoint / 64);
      value[output + 1] = 128 + codePoint % 64;
      output += 2;
    } else if (codePoint <= 65535) {
      value[output] = 224 + Math.trunc(codePoint / 4096);
      value[output + 1] = 128 + Math.trunc(codePoint / 64) % 64;
      value[output + 2] = 128 + codePoint % 64;
      output += 3;
    } else {
      value[output] = 240 + Math.trunc(codePoint / 262144);
      value[output + 1] = 128 + Math.trunc(codePoint / 4096) % 64;
      value[output + 2] = 128 + Math.trunc(codePoint / 64) % 64;
      value[output + 3] = 128 + codePoint % 64;
      output += 4;
    }
  }
  return { value, next: measured.next };
}

function skipJsonNumber(bytes: Uint8Array, start: number): number | null {
  let at = start;
  if (at < bytes.length && bytes[at] === 45) at += 1;
  if (at >= bytes.length) return null;
  if (bytes[at] === 48) at += 1;
  else {
    if (bytes[at] < 49 || bytes[at] > 57) return null;
    while (at < bytes.length && bytes[at] >= 48 && bytes[at] <= 57) at += 1;
  }
  if (at < bytes.length && bytes[at] === 46) {
    at += 1;
    if (at >= bytes.length || bytes[at] < 48 || bytes[at] > 57) return null;
    while (at < bytes.length && bytes[at] >= 48 && bytes[at] <= 57) at += 1;
  }
  if (at < bytes.length && (bytes[at] === 69 || bytes[at] === 101)) {
    at += 1;
    if (at < bytes.length && (bytes[at] === 43 || bytes[at] === 45)) at += 1;
    if (at >= bytes.length || bytes[at] < 48 || bytes[at] > 57) return null;
    while (at < bytes.length && bytes[at] >= 48 && bytes[at] <= 57) at += 1;
  }
  return at;
}

function literalEnd(bytes: Uint8Array, start: number, literal: Uint8Array): number | null {
  if (start + literal.length > bytes.length) return null;
  for (let index = 0; index < literal.length; index += 1) if (bytes[start + index] !== literal[index]) return null;
  return start + literal.length;
}

function skipJsonValue(bytes: Uint8Array, start: number, depth: number): number | null {
  if (depth > 32) return null;
  let at = skipWhitespace(bytes, start);
  if (at >= bytes.length) return null;
  if (bytes[at] === 34) {
    const string = measureJsonString(bytes, at);
    return string === null ? null : string.next;
  }
  if (bytes[at] === 123) {
    at = skipWhitespace(bytes, at + 1);
    if (at < bytes.length && bytes[at] === 125) return at + 1;
    while (at < bytes.length) {
      const key = measureJsonString(bytes, at);
      if (key === null) return null;
      at = skipWhitespace(bytes, key.next);
      if (at >= bytes.length || bytes[at] !== 58) return null;
      const valueEnd = skipJsonValue(bytes, at + 1, depth + 1);
      if (valueEnd === null) return null;
      at = skipWhitespace(bytes, valueEnd);
      if (at < bytes.length && bytes[at] === 125) return at + 1;
      if (at >= bytes.length || bytes[at] !== 44) return null;
      at = skipWhitespace(bytes, at + 1);
    }
    return null;
  }
  if (bytes[at] === 91) {
    at = skipWhitespace(bytes, at + 1);
    if (at < bytes.length && bytes[at] === 93) return at + 1;
    while (at < bytes.length) {
      const valueEnd = skipJsonValue(bytes, at, depth + 1);
      if (valueEnd === null) return null;
      at = skipWhitespace(bytes, valueEnd);
      if (at < bytes.length && bytes[at] === 93) return at + 1;
      if (at >= bytes.length || bytes[at] !== 44) return null;
      at = skipWhitespace(bytes, at + 1);
    }
    return null;
  }
  if (bytes[at] === 116) return literalEnd(bytes, at, asciiBytes("true"));
  if (bytes[at] === 102) return literalEnd(bytes, at, asciiBytes("false"));
  if (bytes[at] === 110) return literalEnd(bytes, at, asciiBytes("null"));
  return skipJsonNumber(bytes, at);
}

function jsonKeyEquals(bytes: Uint8Array, start: number, end: number, expected: Uint8Array): boolean {
  let escaped = false;
  for (let index = start + 1; index < end - 1; index += 1) if (bytes[index] === 92) escaped = true;
  if (!escaped) {
    if (end - start !== expected.length + 2 || bytes[start] !== 34 || bytes[end - 1] !== 34) return false;
    for (let index = 0; index < expected.length; index += 1) if (bytes[start + index + 1] !== expected[index]) return false;
    return true;
  }
  const decoded = parseJsonString(bytes, start);
  return decoded !== null && decoded.next === end && byteEquals(decoded.value, expected);
}

function findJsonField(bytes: Uint8Array, expected: Uint8Array): JsonField | null {
  let at = skipWhitespace(bytes, 0);
  if (at >= bytes.length || bytes[at] !== 123) return null;
  at = skipWhitespace(bytes, at + 1);
  let present = false;
  let foundStart = 0;
  let foundEnd = 0;
  if (at < bytes.length && bytes[at] === 125) {
    at = skipWhitespace(bytes, at + 1);
    return at === bytes.length ? { present, start: foundStart, end: foundEnd } : null;
  }
  while (at < bytes.length) {
    const keyStart = at;
    const key = measureJsonString(bytes, at);
    if (key === null) return null;
    at = skipWhitespace(bytes, key.next);
    if (at >= bytes.length || bytes[at] !== 58) return null;
    const valueStart = skipWhitespace(bytes, at + 1);
    const valueEnd = skipJsonValue(bytes, valueStart, 0);
    if (valueEnd === null) return null;
    if (jsonKeyEquals(bytes, keyStart, key.next, expected)) {
      if (present) return null;
      present = true;
      foundStart = valueStart;
      foundEnd = valueEnd;
    }
    at = skipWhitespace(bytes, valueEnd);
    if (at < bytes.length && bytes[at] === 125) {
      at = skipWhitespace(bytes, at + 1);
      return at === bytes.length ? { present, start: foundStart, end: foundEnd } : null;
    }
    if (at >= bytes.length || bytes[at] !== 44) return null;
    at = skipWhitespace(bytes, at + 1);
  }
  return null;
}

function jsonStringField(bytes: Uint8Array, key: Uint8Array): Uint8Array | null {
  const field = findJsonField(bytes, key);
  if (field === null || !field.present) return null;
  const parsed = parseJsonString(bytes, field.start);
  if (parsed === null || parsed.next !== field.end) return null;
  return parsed.value;
}

function optionalJsonStringField(bytes: Uint8Array, key: Uint8Array): OptionalJsonString | null {
  const field = findJsonField(bytes, key);
  if (field === null) return null;
  if (!field.present) return { present: false, value: asciiBytes("") };
  const parsed = parseJsonString(bytes, field.start);
  if (parsed === null || parsed.next !== field.end) return null;
  return { present: true, value: parsed.value };
}

function jsonBooleanField(bytes: Uint8Array, key: Uint8Array): boolean | null {
  const field = findJsonField(bytes, key);
  if (field === null || !field.present) return null;
  if (field.end - field.start === 4 && bytes[field.start] === 116 && bytes[field.start + 1] === 114 && bytes[field.start + 2] === 117 && bytes[field.start + 3] === 101) return true;
  if (field.end - field.start === 5 && bytes[field.start] === 102 && bytes[field.start + 1] === 97 && bytes[field.start + 2] === 108 && bytes[field.start + 3] === 115 && bytes[field.start + 4] === 101) return false;
  return null;
}

function jsonUnsignedField(bytes: Uint8Array, key: Uint8Array): number | null {
  const field = findJsonField(bytes, key);
  if (field === null || !field.present || field.start >= field.end) return null;
  if (bytes[field.start] === 48 && field.end - field.start > 1) return null;
  let value = 0;
  for (let index = field.start; index < field.end; index += 1) {
    const byte = bytes[index];
    if (byte < 48 || byte > 57) return null;
    const digit = byte - 48;
    if (value > Math.trunc((MAX_SAFE_INTEGER - digit) / 10)) return null;
    value = value * 10 + digit;
  }
  return value;
}

export function decodeNativeMessage(bytes: Uint8Array): Uint8Array | null {
  return jsonStringField(bytes, asciiBytes("message"));
}

export function decodeTranscriptReady(bytes: Uint8Array): TranscriptReadyPayload | null {
  const sessionId = jsonUnsignedField(bytes, asciiBytes("sessionId"));
  const generation = jsonUnsignedField(bytes, asciiBytes("generation"));
  const silence = jsonBooleanField(bytes, asciiBytes("silence"));
  const text = optionalJsonStringField(bytes, asciiBytes("text"));
  if (sessionId === null || sessionId === 0 || generation === null || generation === 0 || silence === null || text === null) return null;
  if (!silence && (!text.present || text.value.length === 0)) return null;
  if (silence && text.present && text.value.length > 0) return null;
  return { sessionId: sessionId / 1, generation: generation / 1, silence, text: text.value };
}

export function decodeTranscriptionFailure(bytes: Uint8Array): TranscriptionFailurePayload | null {
  const sessionId = jsonUnsignedField(bytes, asciiBytes("sessionId"));
  const generation = jsonUnsignedField(bytes, asciiBytes("generation"));
  const retryAudioAvailable = jsonBooleanField(bytes, asciiBytes("retryAudioAvailable"));
  const message = jsonStringField(bytes, asciiBytes("message"));
  if (sessionId === null || sessionId === 0 || generation === null || generation === 0 || retryAudioAvailable === null || message === null || message.length === 0) return null;
  return { sessionId: sessionId / 1, generation: generation / 1, retryAudioAvailable, message };
}

export function decodeDeliveryResult(bytes: Uint8Array): DeliveryResultPayload | null {
  const sessionId = jsonUnsignedField(bytes, asciiBytes("sessionId"));
  const generation = jsonUnsignedField(bytes, asciiBytes("generation"));
  const kindBytes = jsonStringField(bytes, asciiBytes("kind"));
  const message = jsonStringField(bytes, asciiBytes("message"));
  const text = optionalJsonStringField(bytes, asciiBytes("text"));
  if (sessionId === null || sessionId === 0 || generation === null || generation === 0 || kindBytes === null || message === null || text === null) return null;
  const kind = byteEquals(kindBytes, asciiBytes("pasted")) ? "pasted" : byteEquals(kindBytes, asciiBytes("clipboard")) ? "clipboard" : byteEquals(kindBytes, asciiBytes("shown")) ? "shown" : null;
  if (kind === null || message.length === 0 || (kind === "shown" && (!text.present || text.value.length === 0))) return null;
  return { sessionId: sessionId / 1, generation: generation / 1, kind, message, text: text.value };
}

export function decodeDeliveryFailure(bytes: Uint8Array): DeliveryFailurePayload | null {
  const session = findJsonField(bytes, asciiBytes("sessionId"));
  const generationField = findJsonField(bytes, asciiBytes("generation"));
  const message = jsonStringField(bytes, asciiBytes("message"));
  const text = optionalJsonStringField(bytes, asciiBytes("text"));
  if (session === null || generationField === null || message === null || message.length === 0 || text === null || session.present !== generationField.present) return null;
  if (!session.present) return { hasIdentity: false, sessionId: 0 / 1, generation: 0 / 1, message, text: text.value };
  const sessionId = jsonUnsignedField(bytes, asciiBytes("sessionId"));
  const generation = jsonUnsignedField(bytes, asciiBytes("generation"));
  if (sessionId === null || sessionId === 0 || generation === null || generation === 0) return null;
  return { hasIdentity: true, sessionId: sessionId / 1, generation: generation / 1, message, text: text.value };
}

function validIdentity(value: number): boolean {
  return Number.isFinite(value) && value > 0 && value <= MAX_SAFE_INTEGER && Math.trunc(value) === value;
}

export function encodeTranscriptionRequest(sessionId: number, generation: number): Uint8Array | null {
  if (!validIdentity(sessionId) || !validIdentity(generation)) return null;
  return utf8Bytes(`session=${sessionId};generation=${generation}`);
}

export function encodeDeliveryRequest(sessionId: number, generation: number, paste: boolean): Uint8Array | null {
  if (!validIdentity(sessionId) || !validIdentity(generation)) return null;
  const pasteValue = paste ? 1 : 0;
  return utf8Bytes(`session=${sessionId};generation=${generation};paste=${pasteValue}`);
}

export function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const result = new Uint8Array(left.length + right.length);
  result.set(left, 0);
  result.set(right, left.length);
  return result;
}

export function jsonString(bytes: Uint8Array, key: Uint8Array): Uint8Array {
  // Compatibility for non-dictation payloads still using the old token-shaped
  // key. Dictation and delivery boundaries use the typed codecs above.
  if (key.length < 5 || key[0] !== 34 || key[key.length - 3] !== 34 || key[key.length - 2] !== 58 || key[key.length - 1] !== 34) return asciiBytes("");
  const fieldName = key.slice(1, key.length - 3);
  const value = jsonStringField(bytes, fieldName);
  return value === null ? asciiBytes("") : value;
}

export function parseModelRows(bytes: Uint8Array): readonly ModelRow[] {
  const models = findJsonField(bytes, asciiBytes("models"));
  const rows: ModelRow[] = [];
  if (models === null || !models.present) return rows;
  let at = skipWhitespace(bytes, models.start);
  if (at >= models.end || bytes[at] !== 91) return rows;
  at = skipWhitespace(bytes, at + 1);
  if (at < models.end && bytes[at] === 93) return rows;
  while (at < models.end) {
    const end = skipJsonValue(bytes, at, 0);
    if (end === null || end > models.end || bytes[at] !== 123) return [];
    const object = bytes.slice(at, end);
    const key = jsonUnsignedField(object, asciiBytes("modelKey"));
    const name = jsonStringField(object, asciiBytes("displayName"));
    const source = jsonStringField(object, asciiBytes("sourceLabel"));
    const license = jsonStringField(object, asciiBytes("license"));
    const languages = jsonStringField(object, asciiBytes("languageSummary"));
    const size = jsonStringField(object, asciiBytes("sizeText"));
    const managed = jsonBooleanField(object, asciiBytes("managed"));
    const active = jsonBooleanField(object, asciiBytes("active"));
    if (key === null || name === null || source === null || license === null || languages === null || size === null || managed === null || active === null) return [];
    if ((key === 1 || key >= 1000) && rows.length < MAX_MODEL_ROWS) rows[rows.length] = {
      modelKey: utf8Bytes(`${key}`),
      name,
      source,
      license,
      languages,
      size,
      managed,
      active,
    };
    at = skipWhitespace(bytes, end);
    if (at < models.end && bytes[at] === 93) return rows;
    if (at >= models.end || bytes[at] !== 44) return [];
    at = skipWhitespace(bytes, at + 1);
  }
  return [];
}
export function findPipe(bytes: Uint8Array, start: number): number {
  for (let index = start; index < bytes.length; index += 1) if (bytes[index] === 124) return index;
  return bytes.length;
}

export function parseUnsigned(bytes: Uint8Array, start: number, end: number): number {
  let value = 0;
  for (let index = start; index < end; index += 1) {
    const byte = bytes[index];
    if (byte < 48 || byte > 57) return 0;
    value = value * 10 + byte - 48;
  }
  if (!Number.isFinite(value) || value < 0 || value > 9007199254740991) return 0;
  return Math.trunc(value);
}

export function jsonInteger(bytes: Uint8Array, key: Uint8Array): number {
  if (key.length === 0 || bytes.length < key.length) return 0;
  for (let start = 0; start <= bytes.length - key.length; start += 1) {
    let match = true;
    for (let index = 0; index < key.length; index += 1) if (bytes[start + index] !== key[index]) match = false;
    if (!match) continue;
    let end = start + key.length;
    while (end < bytes.length && bytes[end] >= 48 && bytes[end] <= 57) end += 1;
    return parseUnsigned(bytes, start + key.length, end);
  }
  return 0;
}

export function groupedDigits(digits: Uint8Array): Uint8Array {
  if (digits.length === 0) return asciiBytes("0");
  let commaCount = 0;
  let remaining = digits.length;
  while (remaining > 3) {
    commaCount += 1;
    remaining -= 3;
  }
  const result = new Uint8Array(digits.length + commaCount);
  let output = 0;
  for (let index = 0; index < digits.length; index += 1) {
    if (index > 0 && (digits.length - index) % 3 === 0) {
      result[output] = 44;
      output += 1;
    }
    result[output] = digits[index];
    output += 1;
  }
  return result;
}

export function jsonIntegerLabel(bytes: Uint8Array, key: Uint8Array): Uint8Array {
  if (key.length === 0 || bytes.length < key.length) return asciiBytes("0");
  for (let start = 0; start <= bytes.length - key.length; start += 1) {
    let match = true;
    for (let index = 0; index < key.length; index += 1) if (bytes[start + index] !== key[index]) match = false;
    if (!match) continue;
    let end = start + key.length;
    while (end < bytes.length && bytes[end] >= 48 && bytes[end] <= 57) end += 1;
    return groupedDigits(bytes.slice(start + key.length, end));
  }
  return asciiBytes("0");
}

export function eventMatches(bytes: Uint8Array, prefix: Uint8Array, model: Model): boolean {
  if (!hasPrefix(bytes, prefix)) return false;
  const generationEnd = findPipe(bytes, prefix.length);
  const sessionEnd = findPipe(bytes, generationEnd + 1);
  const generation = parseUnsigned(bytes, prefix.length, generationEnd);
  const session = parseUnsigned(bytes, generationEnd + 1, sessionEnd);
  return generation === model.generation && session === model.sessionId;
}
