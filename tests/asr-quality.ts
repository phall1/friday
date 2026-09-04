import { createHash } from "node:crypto";
import { lstat, readFile, realpath, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const CORPUS_SCHEMA = "friday.asr-corpus/v1";
const RESULTS_SCHEMA = "friday.asr-results/v1";
const REPORT_SCHEMA = "friday.asr-quality-report/v1";
const NORMALIZATION = "friday-asr-v1";
const MAX_TRANSCRIPT_BYTES = 1_048_576;
const BOOTSTRAP_SAMPLES = 2_000;

type PinnedFile = { path: string; sha256: string; bytes: number };
type Term = { text: string; category: "entity" | "vocabulary" | "number" };
type CorpusSample = {
  id: string;
  audio: PinnedFile;
  reference: PinnedFile;
  speech: boolean;
  slices: Record<string, string>;
  terms: Term[];
};
type CorpusManifest = {
  schema: typeof CORPUS_SCHEMA;
  normalization: typeof NORMALIZATION;
  corpus: {
    id: string;
    version: string;
    provenance: string;
    license: { spdx: string; url: string; redistribution: "allowed" | "restricted" };
  };
  samples: CorpusSample[];
};
type Candidate = {
  id: string;
  modelSha256: string;
  runtimeSha256: string;
  recognitionPath: "friday-exact-runtime";
  mode: "offline" | "streaming";
};
type ResultSample = { sampleId: string; hypothesis: PinnedFile };
type ResultManifest = {
  schema: typeof RESULTS_SCHEMA;
  corpusManifestSha256: string;
  candidate: Candidate;
  repetitions: { id: string; samples: ResultSample[] }[];
};
type CountRate = { errors: number; referenceUnits: number; rate: number | null };
type SampleScore = {
  speech: boolean;
  slices: Record<string, string>;
  rawWer: CountRate;
  rawCer: CountRate;
  normalizedWer: CountRate;
  normalizedCer: CountRate;
  punctuation: { matches: number; reference: number; hypothesis: number };
  capitalization: { matches: number; aligned: number };
  leading: { retained: number; eligible: number };
  silenceFalseAccept: number;
  speechFalseReject: number;
  terms: { matches: number; reference: number; byCategory: Record<string, { matches: number; reference: number }> };
};
type LoadedCandidate = {
  result: ResultManifest;
  scores: SampleScore[];
  normalizedRuns: string[][][];
};

function record(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label}: expected object`);
  return value as Record<string, unknown>;
}

function string(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${label}: expected nonempty string`);
  return value;
}

function integer(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error(`${label}: expected nonnegative integer`);
  return value as number;
}

function identifier(value: unknown, label: string): string {
  const result = string(value, label);
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(result)) throw new Error(`${label}: invalid identifier`);
  return result;
}

function digest(value: unknown, label: string): string {
  const result = string(value, label);
  if (!/^[a-f0-9]{64}$/.test(result)) throw new Error(`${label}: expected lowercase SHA-256`);
  return result;
}

function pinnedFile(value: unknown, label: string): PinnedFile {
  const input = record(value, label);
  const relative = string(input.path, `${label} path`);
  const segments = relative.split("/");
  if (path.isAbsolute(relative) || relative.includes("\\") || segments.some((part) => part === "" || part === "." || part === "..")) {
    throw new Error(`${label}: path must be a canonical relative path`);
  }
  return { path: relative, sha256: digest(input.sha256, `${label} digest`), bytes: integer(input.bytes, `${label} bytes`) };
}

function parseCorpus(value: unknown): CorpusManifest {
  const input = record(value, "corpus manifest");
  if (input.schema !== CORPUS_SCHEMA) throw new Error("corpus manifest: unsupported schema");
  if (input.normalization !== NORMALIZATION) throw new Error("corpus manifest: unsupported normalization");
  const corpus = record(input.corpus, "corpus metadata");
  const license = record(corpus.license, "corpus license");
  const redistribution = string(license.redistribution, "corpus redistribution");
  if (redistribution !== "allowed" && redistribution !== "restricted") throw new Error("corpus redistribution: unsupported value");
  if (!Array.isArray(input.samples) || input.samples.length === 0) throw new Error("corpus manifest: samples must be nonempty");
  const seen = new Set<string>();
  const samples = input.samples.map((raw, index): CorpusSample => {
    const sample = record(raw, `corpus sample ${index}`);
    const id = identifier(sample.id, `corpus sample ${index} id`);
    if (seen.has(id)) throw new Error(`corpus sample ${index}: duplicate id`);
    seen.add(id);
    if (typeof sample.speech !== "boolean") throw new Error(`corpus sample ${index}: speech must be boolean`);
    const rawSlices = record(sample.slices, `corpus sample ${index} slices`);
    const slices: Record<string, string> = {};
    for (const key of Object.keys(rawSlices).sort()) {
      if (!/^[a-z][a-z0-9_-]{0,31}$/.test(key)) throw new Error(`corpus sample ${index}: invalid slice key`);
      slices[key] = identifier(rawSlices[key], `corpus sample ${index} slice value`);
    }
    const rawTerms = sample.terms === undefined ? [] : sample.terms;
    if (!Array.isArray(rawTerms)) throw new Error(`corpus sample ${index}: terms must be an array`);
    const terms = rawTerms.map((rawTerm, termIndex): Term => {
      const term = record(rawTerm, `corpus sample ${index} term ${termIndex}`);
      const category = string(term.category, `corpus sample ${index} term category`);
      if (category !== "entity" && category !== "vocabulary" && category !== "number") {
        throw new Error(`corpus sample ${index}: invalid term category`);
      }
      return { text: string(term.text, `corpus sample ${index} term text`), category };
    });
    return {
      id,
      audio: pinnedFile(sample.audio, `corpus sample ${index} audio`),
      reference: pinnedFile(sample.reference, `corpus sample ${index} reference`),
      speech: sample.speech,
      slices,
      terms,
    };
  });
  return {
    schema: CORPUS_SCHEMA,
    normalization: NORMALIZATION,
    corpus: {
      id: identifier(corpus.id, "corpus id"),
      version: identifier(corpus.version, "corpus version"),
      provenance: string(corpus.provenance, "corpus provenance"),
      license: {
        spdx: identifier(license.spdx, "corpus SPDX license"),
        url: string(license.url, "corpus license URL"),
        redistribution,
      },
    },
    samples,
  };
}

function parseResults(value: unknown): ResultManifest {
  const input = record(value, "results manifest");
  if (input.schema !== RESULTS_SCHEMA) throw new Error("results manifest: unsupported schema");
  const rawCandidate = record(input.candidate, "candidate");
  if (rawCandidate.recognitionPath !== "friday-exact-runtime") throw new Error("candidate: results are not from Friday's exact runtime path");
  if (rawCandidate.mode !== "offline" && rawCandidate.mode !== "streaming") throw new Error("candidate: invalid mode");
  if (!Array.isArray(input.repetitions) || input.repetitions.length === 0) throw new Error("results manifest: repetitions must be nonempty");
  const repetitionIds = new Set<string>();
  const repetitions = input.repetitions.map((raw, repetitionIndex) => {
    const repetition = record(raw, `repetition ${repetitionIndex}`);
    const id = identifier(repetition.id, `repetition ${repetitionIndex} id`);
    if (repetitionIds.has(id)) throw new Error(`repetition ${repetitionIndex}: duplicate id`);
    repetitionIds.add(id);
    if (!Array.isArray(repetition.samples)) throw new Error(`repetition ${repetitionIndex}: samples must be an array`);
    const sampleIds = new Set<string>();
    const samples = repetition.samples.map((rawSample, sampleIndex): ResultSample => {
      const sample = record(rawSample, `repetition ${repetitionIndex} sample ${sampleIndex}`);
      const sampleId = identifier(sample.sampleId, `repetition ${repetitionIndex} sample ${sampleIndex} id`);
      if (sampleIds.has(sampleId)) throw new Error(`repetition ${repetitionIndex} sample ${sampleIndex}: duplicate id`);
      sampleIds.add(sampleId);
      return { sampleId, hypothesis: pinnedFile(sample.hypothesis, `repetition ${repetitionIndex} sample ${sampleIndex} hypothesis`) };
    });
    return { id, samples };
  });
  return {
    schema: RESULTS_SCHEMA,
    corpusManifestSha256: digest(input.corpusManifestSha256, "results corpus digest"),
    candidate: {
      id: identifier(rawCandidate.id, "candidate id"),
      modelSha256: digest(rawCandidate.modelSha256, "candidate model digest"),
      runtimeSha256: digest(rawCandidate.runtimeSha256, "candidate runtime digest"),
      recognitionPath: "friday-exact-runtime",
      mode: rawCandidate.mode,
    },
    repetitions,
  };
}

async function sha256(bytes: Uint8Array): Promise<string> {
  return createHash("sha256").update(bytes).digest("hex");
}

async function readJson(file: string, label: string): Promise<{ bytes: Uint8Array; value: unknown }> {
  const bytes = await readFile(file).catch(() => { throw new Error(`${label}: cannot read file`); });
  try {
    return { bytes, value: JSON.parse(bytes.toString("utf8")) as unknown };
  } catch {
    throw new Error(`${label}: invalid JSON`);
  }
}

async function verifyPinned(root: string, file: PinnedFile, label: string): Promise<Uint8Array> {
  const absoluteRoot = path.resolve(root);
  const absolute = path.resolve(absoluteRoot, file.path);
  if (absolute === absoluteRoot || !absolute.startsWith(`${absoluteRoot}${path.sep}`)) throw new Error(`${label}: path escapes root`);
  const info = await lstat(absolute).catch(() => { throw new Error(`${label}: missing provisioned file`); });
  if (!info.isFile() || info.isSymbolicLink()) throw new Error(`${label}: provisioned path must be a regular file`);
  const [resolvedRoot, resolvedFile] = await Promise.all([realpath(absoluteRoot), realpath(absolute)]);
  if (!resolvedFile.startsWith(`${resolvedRoot}${path.sep}`)) throw new Error(`${label}: provisioned path escapes root through a symlink`);
  if (info.size !== file.bytes) throw new Error(`${label}: size mismatch`);
  const bytes = await readFile(absolute);
  if (await sha256(bytes) !== file.sha256) throw new Error(`${label}: SHA-256 mismatch`);
  return bytes;
}

function transcript(bytes: Uint8Array, label: string): string {
  if (bytes.byteLength > MAX_TRANSCRIPT_BYTES) throw new Error(`${label}: transcript exceeds size limit`);
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (text.includes("\0")) throw new Error(`${label}: transcript contains NUL`);
  return text.replace(/\r\n?/g, "\n").trim();
}

export function rawText(value: string): string {
  return value.normalize("NFKC").replace(/\s+/gu, " ").trim();
}

export function rawWords(value: string): string[] {
  const canonical = rawText(value);
  return canonical === "" ? [] : canonical.split(" ");
}

export function normalizedWords(value: string): string[] {
  const canonical = value.normalize("NFKC").replace(/[‘’ʼ]/gu, "'").toLowerCase();
  return canonical.match(/[\p{L}\p{M}\p{N}]+(?:'[\p{L}\p{M}\p{N}]+)*/gu) ?? [];
}

function lexicalWords(value: string): string[] {
  const canonical = value.normalize("NFKC").replace(/[‘’ʼ]/gu, "'");
  return canonical.match(/[\p{L}\p{M}\p{N}]+(?:'[\p{L}\p{M}\p{N}]+)*/gu) ?? [];
}

export function editDistance<T>(reference: readonly T[], hypothesis: readonly T[]): number {
  let previous = Array.from({ length: hypothesis.length + 1 }, (_, index) => index);
  for (let row = 1; row <= reference.length; row += 1) {
    const current = [row];
    for (let column = 1; column <= hypothesis.length; column += 1) {
      current[column] = Math.min(
        (previous[column] ?? 0) + 1,
        (current[column - 1] ?? 0) + 1,
        (previous[column - 1] ?? 0) + (reference[row - 1] === hypothesis[column - 1] ? 0 : 1),
      );
    }
    previous = current;
  }
  return previous[hypothesis.length] ?? 0;
}

function lcsMatches<T>(left: readonly T[], right: readonly T[]): number {
  let previous = new Array<number>(right.length + 1).fill(0);
  for (let row = 1; row <= left.length; row += 1) {
    const current = new Array<number>(right.length + 1).fill(0);
    for (let column = 1; column <= right.length; column += 1) {
      current[column] = left[row - 1] === right[column - 1]
        ? (previous[column - 1] ?? 0) + 1
        : Math.max(previous[column] ?? 0, current[column - 1] ?? 0);
    }
    previous = current;
  }
  return previous[right.length] ?? 0;
}

function alignedCapitalization(reference: string, hypothesis: string): { matches: number; aligned: number } {
  const referenceTokens = lexicalWords(reference);
  const hypothesisTokens = lexicalWords(hypothesis);
  const referenceNormalized = referenceTokens.map((word) => word.toLowerCase());
  const hypothesisNormalized = hypothesisTokens.map((word) => word.toLowerCase());
  const width = hypothesisTokens.length + 1;
  const costs = new Array<number>((referenceTokens.length + 1) * width).fill(0);
  for (let row = 0; row <= referenceTokens.length; row += 1) costs[row * width] = row;
  for (let column = 0; column <= hypothesisTokens.length; column += 1) costs[column] = column;
  for (let row = 1; row <= referenceTokens.length; row += 1) {
    for (let column = 1; column <= hypothesisTokens.length; column += 1) {
      costs[row * width + column] = Math.min(
        (costs[(row - 1) * width + column] ?? 0) + 1,
        (costs[row * width + column - 1] ?? 0) + 1,
        (costs[(row - 1) * width + column - 1] ?? 0) + (referenceNormalized[row - 1] === hypothesisNormalized[column - 1] ? 0 : 1),
      );
    }
  }
  let row = referenceTokens.length;
  let column = hypothesisTokens.length;
  let matches = 0;
  let aligned = 0;
  while (row > 0 && column > 0) {
    const sameLexeme = referenceNormalized[row - 1] === hypothesisNormalized[column - 1];
    const diagonal = (costs[(row - 1) * width + column - 1] ?? 0) + (sameLexeme ? 0 : 1);
    if ((costs[row * width + column] ?? 0) === diagonal) {
      if (sameLexeme) {
        aligned += 1;
        if (referenceTokens[row - 1] === hypothesisTokens[column - 1]) matches += 1;
      }
      row -= 1;
      column -= 1;
    } else if ((costs[row * width + column] ?? 0) === (costs[(row - 1) * width + column] ?? 0) + 1) {
      row -= 1;
    } else {
      column -= 1;
    }
  }
  return { matches, aligned };
}

function containsPhrase(words: string[], phrase: string[]): boolean {
  if (phrase.length === 0) return false;
  outer: for (let start = 0; start <= words.length - phrase.length; start += 1) {
    for (let offset = 0; offset < phrase.length; offset += 1) {
      if (words[start + offset] !== phrase[offset]) continue outer;
    }
    return true;
  }
  return false;
}

export function scoreSample(sample: Pick<CorpusSample, "speech" | "slices" | "terms">, reference: string, hypothesis: string): SampleScore {
  const referenceRaw = rawText(reference);
  const hypothesisRaw = rawText(hypothesis);
  const referenceNormalizedWords = normalizedWords(reference);
  const hypothesisNormalizedWords = normalizedWords(hypothesis);
  const normalizedReference = referenceNormalizedWords.join(" ");
  const normalizedHypothesis = hypothesisNormalizedWords.join(" ");
  const punctuationReference = reference.normalize("NFKC").match(/[\p{P}]/gu) ?? [];
  const punctuationHypothesis = hypothesis.normalize("NFKC").match(/[\p{P}]/gu) ?? [];
  const terms = { matches: 0, reference: sample.terms.length, byCategory: {} as Record<string, { matches: number; reference: number }> };
  for (const term of sample.terms) {
    const bucket = terms.byCategory[term.category] ?? { matches: 0, reference: 0 };
    bucket.reference += 1;
    if (containsPhrase(hypothesisNormalizedWords, normalizedWords(term.text))) {
      bucket.matches += 1;
      terms.matches += 1;
    }
    terms.byCategory[term.category] = bucket;
  }
  const countRate = (errors: number, referenceUnits: number): CountRate => ({ errors, referenceUnits, rate: referenceUnits === 0 ? null : errors / referenceUnits });
  return {
    speech: sample.speech,
    slices: sample.slices,
    rawWer: countRate(editDistance(rawWords(referenceRaw), rawWords(hypothesisRaw)), rawWords(referenceRaw).length),
    rawCer: countRate(editDistance([...referenceRaw], [...hypothesisRaw]), [...referenceRaw].length),
    normalizedWer: countRate(editDistance(referenceNormalizedWords, hypothesisNormalizedWords), referenceNormalizedWords.length),
    normalizedCer: countRate(editDistance([...normalizedReference], [...normalizedHypothesis]), [...normalizedReference].length),
    punctuation: { matches: lcsMatches(punctuationReference, punctuationHypothesis), reference: punctuationReference.length, hypothesis: punctuationHypothesis.length },
    capitalization: alignedCapitalization(reference, hypothesis),
    leading: { retained: referenceNormalizedWords.length > 0 && referenceNormalizedWords[0] === hypothesisNormalizedWords[0] ? 1 : 0, eligible: referenceNormalizedWords.length > 0 ? 1 : 0 },
    silenceFalseAccept: !sample.speech && hypothesisNormalizedWords.length > 0 ? 1 : 0,
    speechFalseReject: sample.speech && hypothesisNormalizedWords.length === 0 ? 1 : 0,
    terms,
  };
}

async function loadCorpus(manifestPath: string): Promise<{ manifest: CorpusManifest; digest: string; references: string[] }> {
  const parsed = await readJson(manifestPath, "corpus manifest");
  const manifest = parseCorpus(parsed.value);
  const root = path.dirname(path.resolve(manifestPath));
  const references: string[] = [];
  for (let index = 0; index < manifest.samples.length; index += 1) {
    const sample = manifest.samples[index]!;
    await verifyPinned(root, sample.audio, `corpus sample ${index} audio`);
    const reference = transcript(await verifyPinned(root, sample.reference, `corpus sample ${index} reference`), `corpus sample ${index} reference`);
    const referenceWords = normalizedWords(reference);
    if (sample.speech && referenceWords.length === 0) throw new Error(`corpus sample ${index}: speech reference is empty`);
    if (!sample.speech && referenceWords.length > 0) throw new Error(`corpus sample ${index}: silence reference is not empty`);
    for (let termIndex = 0; termIndex < sample.terms.length; termIndex += 1) {
      if (!containsPhrase(referenceWords, normalizedWords(sample.terms[termIndex]!.text))) throw new Error(`corpus sample ${index} term ${termIndex}: term is absent from reference`);
    }
    references.push(reference);
  }
  return { manifest, digest: await sha256(parsed.bytes), references };
}

async function loadCandidate(resultsPath: string, corpus: Awaited<ReturnType<typeof loadCorpus>>): Promise<LoadedCandidate> {
  const parsed = await readJson(resultsPath, "results manifest");
  const result = parseResults(parsed.value);
  if (result.corpusManifestSha256 !== corpus.digest) throw new Error("results manifest: corpus digest mismatch");
  const expectedIds = new Set(corpus.manifest.samples.map((sample) => sample.id));
  const root = path.dirname(path.resolve(resultsPath));
  const normalizedRuns: string[][][] = [];
  const scores: SampleScore[] = [];
  for (let repetitionIndex = 0; repetitionIndex < result.repetitions.length; repetitionIndex += 1) {
    const repetition = result.repetitions[repetitionIndex]!;
    if (repetition.samples.length !== expectedIds.size || repetition.samples.some((sample) => !expectedIds.has(sample.sampleId))) {
      throw new Error(`repetition ${repetitionIndex}: sample set does not exactly match corpus`);
    }
    const byId = new Map(repetition.samples.map((sample) => [sample.sampleId, sample]));
    const run: string[][] = [];
    for (let sampleIndex = 0; sampleIndex < corpus.manifest.samples.length; sampleIndex += 1) {
      const sample = corpus.manifest.samples[sampleIndex]!;
      const resultSample = byId.get(sample.id)!;
      const hypothesis = transcript(await verifyPinned(root, resultSample.hypothesis, `repetition ${repetitionIndex} sample ${sampleIndex} hypothesis`), `repetition ${repetitionIndex} sample ${sampleIndex} hypothesis`);
      run.push(normalizedWords(hypothesis));
      if (repetitionIndex === 0) scores.push(scoreSample(sample, corpus.references[sampleIndex]!, hypothesis));
    }
    normalizedRuns.push(run);
  }
  return { result, scores, normalizedRuns };
}

function ratio(numerator: number, denominator: number): number | null {
  return denominator === 0 ? null : numerator / denominator;
}

function aggregate(scores: SampleScore[]) {
  const qualityScores = scores.filter((score) => score.speech);
  const sumMetric = (key: "rawWer" | "rawCer" | "normalizedWer" | "normalizedCer") => {
    const errors = qualityScores.reduce((sum, score) => sum + score[key].errors, 0);
    const referenceUnits = qualityScores.reduce((sum, score) => sum + score[key].referenceUnits, 0);
    return { errors, referenceUnits, rate: ratio(errors, referenceUnits) };
  };
  const punctuation = qualityScores.reduce((sum, score) => ({
    matches: sum.matches + score.punctuation.matches,
    reference: sum.reference + score.punctuation.reference,
    hypothesis: sum.hypothesis + score.punctuation.hypothesis,
  }), { matches: 0, reference: 0, hypothesis: 0 });
  const capitalization = qualityScores.reduce((sum, score) => ({ matches: sum.matches + score.capitalization.matches, aligned: sum.aligned + score.capitalization.aligned }), { matches: 0, aligned: 0 });
  const leading = qualityScores.reduce((sum, score) => ({ retained: sum.retained + score.leading.retained, eligible: sum.eligible + score.leading.eligible }), { retained: 0, eligible: 0 });
  const speechCount = scores.filter((score) => score.speech).length;
  const silenceCount = scores.length - speechCount;
  const falseAccepts = scores.reduce((sum, score) => sum + score.silenceFalseAccept, 0);
  const falseRejects = scores.reduce((sum, score) => sum + score.speechFalseReject, 0);
  const terms = qualityScores.reduce((sum, score) => {
    sum.matches += score.terms.matches;
    sum.reference += score.terms.reference;
    for (const category of Object.keys(score.terms.byCategory).sort()) {
      const bucket = sum.byCategory[category] ?? { matches: 0, reference: 0, recall: null as number | null };
      bucket.matches += score.terms.byCategory[category]!.matches;
      bucket.reference += score.terms.byCategory[category]!.reference;
      sum.byCategory[category] = bucket;
    }
    return sum;
  }, { matches: 0, reference: 0, byCategory: {} as Record<string, { matches: number; reference: number; recall: number | null }> });
  for (const bucket of Object.values(terms.byCategory)) bucket.recall = ratio(bucket.matches, bucket.reference);
  return {
    samples: scores.length,
    raw: { wer: sumMetric("rawWer"), cer: sumMetric("rawCer") },
    normalized: { wer: sumMetric("normalizedWer"), cer: sumMetric("normalizedCer") },
    punctuation: {
      matches: punctuation.matches,
      reference: punctuation.reference,
      hypothesis: punctuation.hypothesis,
      precision: ratio(punctuation.matches, punctuation.hypothesis),
      recall: ratio(punctuation.matches, punctuation.reference),
      f1: punctuation.matches === 0 ? (punctuation.reference === 0 && punctuation.hypothesis === 0 ? null : 0) : (2 * punctuation.matches) / (punctuation.reference + punctuation.hypothesis),
    },
    capitalization: { ...capitalization, accuracy: ratio(capitalization.matches, capitalization.aligned) },
    leadingWordRetention: { ...leading, rate: ratio(leading.retained, leading.eligible) },
    silence: { samples: silenceCount, falseAccepts, falseAcceptRate: ratio(falseAccepts, silenceCount) },
    speech: { samples: speechCount, falseRejects, falseRejectRate: ratio(falseRejects, speechCount) },
    termRecall: { matches: terms.matches, reference: terms.reference, recall: ratio(terms.matches, terms.reference), byCategory: terms.byCategory },
  };
}

function sliceReport(scores: SampleScore[]): Record<string, ReturnType<typeof aggregate>> {
  const groups = new Map<string, SampleScore[]>();
  groups.set("all", scores);
  for (const score of scores) {
    for (const [key, value] of Object.entries(score.slices)) {
      const label = `${key}=${value}`;
      groups.set(label, [...(groups.get(label) ?? []), score]);
    }
  }
  return Object.fromEntries([...groups.entries()].sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0).map(([label, members]) => [label, aggregate(members)]));
}

function stability(candidate: LoadedCandidate) {
  let comparisons = 0;
  let exactAgreements = 0;
  let errors = 0;
  let referenceUnits = 0;
  const primary = candidate.normalizedRuns[0]!;
  for (let runIndex = 1; runIndex < candidate.normalizedRuns.length; runIndex += 1) {
    const run = candidate.normalizedRuns[runIndex]!;
    for (let sampleIndex = 0; sampleIndex < primary.length; sampleIndex += 1) {
      const baseline = primary[sampleIndex]!;
      const repeated = run[sampleIndex]!;
      const distance = editDistance(baseline, repeated);
      comparisons += 1;
      if (distance === 0) exactAgreements += 1;
      errors += distance;
      referenceUnits += baseline.length;
    }
  }
  return {
    repetitions: candidate.normalizedRuns.length,
    comparisons,
    exactAgreements,
    exactAgreementRate: ratio(exactAgreements, comparisons),
    normalizedDisagreement: { errors, referenceUnits, rate: ratio(errors, referenceUnits) },
  };
}

function seededRandom(seedText: string): () => number {
  let state = 2_166_136_261;
  for (const byte of new TextEncoder().encode(seedText)) state = Math.imul(state ^ byte, 16_777_619) >>> 0;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 4_294_967_296;
  };
}

function percentile(sorted: number[], probability: number): number {
  return sorted[Math.floor((sorted.length - 1) * probability)] ?? 0;
}

function pairedComparison(baseline: LoadedCandidate, candidate: LoadedCandidate) {
  const eligible = baseline.scores.map((score, index) => ({ baseline: score.normalizedWer, candidate: candidate.scores[index]!.normalizedWer })).filter((pair) => pair.baseline.referenceUnits > 0);
  const total = (key: "baseline" | "candidate", pairs = eligible) => {
    const errors = pairs.reduce((sum, pair) => sum + pair[key].errors, 0);
    const units = pairs.reduce((sum, pair) => sum + pair[key].referenceUnits, 0);
    return units === 0 ? 0 : errors / units;
  };
  const baselineRate = total("baseline");
  const candidateRate = total("candidate");
  const random = seededRandom(`${baseline.result.candidate.id}\0${candidate.result.candidate.id}`);
  const deltas: number[] = [];
  for (let iteration = 0; iteration < BOOTSTRAP_SAMPLES; iteration += 1) {
    const resampled = Array.from({ length: eligible.length }, () => eligible[Math.floor(random() * eligible.length)]!);
    deltas.push(total("candidate", resampled) - total("baseline", resampled));
  }
  deltas.sort((left, right) => left - right);
  const delta = candidateRate - baselineRate;
  return {
    baseline: baseline.result.candidate.id,
    candidate: candidate.result.candidate.id,
    pairedSpeechSamples: eligible.length,
    normalizedWer: {
      baseline: baselineRate,
      candidate: candidateRate,
      absoluteDelta: delta,
      relativeImprovement: baselineRate === 0 ? null : -delta / baselineRate,
      bootstrap95: { lower: percentile(deltas, 0.025), upper: percentile(deltas, 0.975), samples: BOOTSTRAP_SAMPLES, seed: "candidate-pair-fnv1a-xorshift32" },
    },
  };
}

export async function verifyQualityInputs(corpusPath: string, resultPaths: string[] = []) {
  const corpus = await loadCorpus(corpusPath);
  const candidates: LoadedCandidate[] = [];
  const candidateIds = new Set<string>();
  for (const resultPath of resultPaths) {
    const candidate = await loadCandidate(resultPath, corpus);
    if (candidateIds.has(candidate.result.candidate.id)) throw new Error("results manifests: duplicate candidate id");
    candidateIds.add(candidate.result.candidate.id);
    candidates.push(candidate);
  }
  return { corpus, candidates };
}

export async function qualityReport(corpusPath: string, resultPaths: string[], baselineId?: string) {
  if (resultPaths.length === 0) throw new Error("score: at least one results manifest is required");
  const { corpus, candidates } = await verifyQualityInputs(corpusPath, resultPaths);
  candidates.sort((left, right) => left.result.candidate.id < right.result.candidate.id ? -1 : left.result.candidate.id > right.result.candidate.id ? 1 : 0);
  const baseline = baselineId === undefined ? candidates[0] : candidates.find((candidate) => candidate.result.candidate.id === baselineId);
  if (baseline === undefined) throw new Error("score: baseline candidate was not provided");
  return {
    schema: REPORT_SCHEMA,
    corpus: {
      id: corpus.manifest.corpus.id,
      version: corpus.manifest.corpus.version,
      manifestSha256: corpus.digest,
      samples: corpus.manifest.samples.length,
      speechSamples: corpus.manifest.samples.filter((sample) => sample.speech).length,
      silenceSamples: corpus.manifest.samples.filter((sample) => !sample.speech).length,
    },
    privacy: { containsAudio: false, containsTranscripts: false, containsRawPaths: false, containsSampleIds: false },
    candidates: candidates.map((candidate) => ({
      id: candidate.result.candidate.id,
      modelSha256: candidate.result.candidate.modelSha256,
      runtimeSha256: candidate.result.candidate.runtimeSha256,
      recognitionPath: candidate.result.candidate.recognitionPath,
      mode: candidate.result.candidate.mode,
      slices: sliceReport(candidate.scores),
      stability: stability(candidate),
    })),
    comparisons: candidates.filter((candidate) => candidate !== baseline).map((candidate) => pairedComparison(baseline, candidate)),
  };
}

function usage(): never {
  throw new Error("usage: asr-quality.ts verify --corpus <manifest> [--results <manifest> ...] | score --corpus <manifest> --results <manifest> ... [--baseline <id>] [--output <file>]");
}

function cliArguments(argv: string[]) {
  const command = argv.shift();
  if (command !== "verify" && command !== "score") usage();
  let corpus: string | undefined;
  let baseline: string | undefined;
  let output: string | undefined;
  const results: string[] = [];
  while (argv.length > 0) {
    const flag = argv.shift();
    const value = argv.shift();
    if (value === undefined) usage();
    if (flag === "--corpus") corpus = value;
    else if (flag === "--results") results.push(value);
    else if (flag === "--baseline") baseline = value;
    else if (flag === "--output") output = value;
    else usage();
  }
  if (corpus === undefined || (command === "score" && results.length === 0)) usage();
  return { command, corpus, results, baseline, output };
}

async function main() {
  const options = cliArguments(process.argv.slice(2));
  const value = options.command === "verify"
    ? (() => verifyQualityInputs(options.corpus, options.results).then(({ corpus, candidates }) => ({
      schema: "friday.asr-quality-verification/v1",
      corpus: { id: corpus.manifest.corpus.id, version: corpus.manifest.corpus.version, manifestSha256: corpus.digest, samples: corpus.manifest.samples.length },
      candidates: candidates.map((candidate) => ({ id: candidate.result.candidate.id, repetitions: candidate.result.repetitions.length })),
      privacy: { containsAudio: false, containsTranscripts: false, containsRawPaths: false, containsSampleIds: false },
      verified: true,
    })))()
    : await qualityReport(options.corpus, options.results, options.baseline);
  const encoded = `${JSON.stringify(await value, null, 2)}\n`;
  if (options.output === undefined) process.stdout.write(encoded);
  else await writeFile(options.output, encoded, { encoding: "utf8", mode: 0o600 });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error: unknown) => {
    process.stderr.write(`ASR quality harness failed: ${error instanceof Error ? error.message : "unknown error"}\n`);
    process.exitCode = 1;
  });
}
