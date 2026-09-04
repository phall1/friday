import assert from "node:assert/strict";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { editDistance, normalizedWords, qualityReport, rawText, scoreSample, verifyQualityInputs } from "./asr-quality.ts";

const fixture = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "asr-quality");
const corpus = path.join(fixture, "corpus.json");
const baseline = path.join(fixture, "baseline.results.json");
const candidate = path.join(fixture, "candidate.results.json");

test("normalization and edit distance are deterministic for dictation text", () => {
  assert.equal(rawText("  Café\r\nFriday  "), "Café Friday");
  assert.deepEqual(normalizedWords("‘Friday’—CAFÉ 42!"), ["friday", "café", "42"]);
  assert.equal(editDistance(["leading", "word"], ["word"]), 1);
  assert.equal(editDistance([..."café"], [..."cafe"]), 1);
});

test("sample scoring covers raw/normalized errors and dictation-specific gates", () => {
  const score = scoreSample(
    { speech: true, slices: { language: "en" }, terms: [{ text: "Alice's", category: "entity" }, { text: "42", category: "number" }] },
    "Friday keeps Alice's 42 notes.",
    "friday keeps Alice's forty-two notes",
  );
  assert.equal(score.normalizedWer.errors, 2);
  assert.equal(score.rawWer.errors > score.normalizedWer.errors, true);
  assert.equal(score.leading.retained, 1);
  assert.deepEqual(score.capitalization, { matches: 3, aligned: 4 });
  assert.equal(score.terms.byCategory.entity?.matches, 1);
  assert.equal(score.terms.byCategory.number?.matches, 0);
});

test("synthetic fixture verifies and emits aggregate-only comparative reports", async () => {
  const verified = await verifyQualityInputs(corpus, [baseline, candidate]);
  assert.equal(verified.corpus.manifest.samples.length, 3);
  assert.equal(verified.candidates.length, 2);

  const report = await qualityReport(corpus, [candidate, baseline], "baseline");
  assert.equal(report.schema, "friday.asr-quality-report/v1");
  assert.deepEqual(report.privacy, { containsAudio: false, containsTranscripts: false, containsRawPaths: false, containsSampleIds: false });
  assert.equal(report.candidates[0]?.id, "baseline");
  assert.equal(report.candidates[0]?.slices.all.silence.falseAcceptRate, 1);
  assert.equal(report.candidates[1]?.slices.all.silence.falseAcceptRate, 0);
  assert.equal(report.candidates[0]?.stability.exactAgreementRate, 2 / 3);
  assert.equal(report.comparisons[0]?.normalizedWer.bootstrap95.samples, 2_000);

  const encoded = JSON.stringify(report);
  for (const privateValue of [
    "synthetic-short",
    "synthetic-noise",
    "synthetic-silence",
    "Friday keeps",
    "Leading words",
    "Thank you",
    "references/",
    "results/",
    fixture,
  ]) assert.equal(encoded.includes(privateValue), false, `aggregate report leaked ${privateValue}`);
});

test("provisioning fails closed when a pinned corpus asset changes", async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), "friday-quality-"));
  try {
    await cp(fixture, temporary, { recursive: true });
    const audioPath = path.join(temporary, "audio", "tone.wav");
    const bytes = await readFile(audioPath);
    bytes[bytes.length - 1] ^= 1;
    await writeFile(audioPath, bytes);
    await assert.rejects(verifyQualityInputs(path.join(temporary, "corpus.json")), /SHA-256 mismatch/);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
