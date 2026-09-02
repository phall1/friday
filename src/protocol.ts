import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { Model, ModelRow } from "./core.ts";

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

export function jsonString(bytes: Uint8Array, key: Uint8Array): Uint8Array {
  if (key.length === 0 || bytes.length < key.length) return asciiBytes("");
  for (let start = 0; start <= bytes.length - key.length; start += 1) {
    let match = true;
    for (let index = 0; index < key.length; index += 1) if (bytes[start + index] !== key[index]) match = false;
    if (!match) continue;
    const valueStart = start + key.length;
    let end = valueStart;
    while (end < bytes.length && bytes[end] !== 34) end += 1;
    return bytes.slice(valueStart, end);
  }
  return asciiBytes("");
}


function findBytes(bytes: Uint8Array, needle: Uint8Array, start: number): number {
  if (needle.length === 0 || bytes.length < needle.length) return bytes.length;
  for (let offset = start; offset <= bytes.length - needle.length; offset += 1) {
    let match = true;
    for (let index = 0; index < needle.length; index += 1) if (bytes[offset + index] !== needle[index]) match = false;
    if (match) return offset;
  }
  return bytes.length;
}

export function parseModelRows(bytes: Uint8Array): readonly ModelRow[] {
  const rows: ModelRow[] = [];
  const token = asciiBytes("\"modelKey\":");
  let cursor = 0;
  while (cursor < bytes.length && rows.length < 8) {
    const keyAt = findBytes(bytes, token, cursor);
    if (keyAt >= bytes.length) return rows;
    let start = keyAt;
    while (start > 0 && bytes[start] !== 123) start -= 1;
    let end = keyAt;
    while (end < bytes.length && bytes[end] !== 125) end += 1;
    const object = bytes.slice(start, end);
    const key = jsonInteger(object, token);
    if (key === 1 || key >= 1000) rows[rows.length] = {
      modelKey: utf8Bytes(`${key}`),
      name: jsonString(object, asciiBytes("\"displayName\":\"")),
      source: jsonString(object, asciiBytes("\"sourceLabel\":\"")),
      license: jsonString(object, asciiBytes("\"license\":\"")),
      languages: jsonString(object, asciiBytes("\"languageSummary\":\"")),
      size: jsonString(object, asciiBytes("\"sizeText\":\"")),
      managed: contains(object, asciiBytes("\"managed\":true")),
      active: contains(object, asciiBytes("\"active\":true")),
    };
    cursor = end + 1;
  }
  return rows;
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
