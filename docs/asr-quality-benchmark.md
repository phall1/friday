# Privacy-safe ASR quality benchmark

Friday's quality harness verifies a locally provisioned corpus and exact-runtime result set, then writes aggregate metrics only. Real evaluation audio, reference transcripts, hypotheses, and their local paths stay outside this repository and outside release artifacts. The checked-in `tests/fixtures/asr-quality/` corpus contains only generated 50 ms WAV data and authored synthetic text so CI can exercise the complete verifier and scorer.

The scorer does not transcribe audio. An exact-path runner must first feed each pinned WAV through Friday's 16 kHz mono conversion and in-process NeMo runtime, then write the local result manifest described below. This separation lets private material remain under the corpus owner's control. A CLI-only NeMo result must not claim `recognitionPath: "friday-exact-runtime"`.

## Run it

Run the deterministic CI fixture:

```sh
npm run --silent quality:fixture > /tmp/friday-quality-report.json
npx tsx --test tests/asr-quality.test.ts
```

Verify a locally provisioned corpus and one or more result sets without printing paths or text:

```sh
npm run --silent quality -- verify \
  --corpus "$FRIDAY_QUALITY_ROOT/corpus.json" \
  --results "$FRIDAY_QUALITY_ROOT/current.results.json"
```

Score paired candidates. The first candidate is the default baseline unless `--baseline` names another candidate:

```sh
npm run --silent quality -- score \
  --corpus "$FRIDAY_QUALITY_ROOT/corpus.json" \
  --results "$FRIDAY_QUALITY_ROOT/current.results.json" \
  --results "$FRIDAY_QUALITY_ROOT/candidate.results.json" \
  --baseline current \
  --output "$FRIDAY_QUALITY_ROOT/aggregate.json"
```

`--output` is created with mode `0600`. Without it, aggregate JSON is written to standard output. Failures identify only a manifest role and ordinal, never transcript text or a raw path.

## Corpus manifest v1

`corpus.json` is itself pinned by its SHA-256 in every result manifest. Every audio/reference entry also carries an exact lowercase SHA-256 and byte count:

```json
{
  "schema": "friday.asr-corpus/v1",
  "normalization": "friday-asr-v1",
  "corpus": {
    "id": "internal-dictation",
    "version": "2026-09-04",
    "provenance": "Internal consented recording protocol revision 3",
    "license": {
      "spdx": "LicenseRef-Internal-Consent",
      "url": "https://internal.invalid/corpus-license",
      "redistribution": "restricted"
    }
  },
  "samples": [{
    "id": "opaque-0001",
    "audio": { "path": "audio/opaque-0001.wav", "sha256": "<64 lowercase hex>", "bytes": 123456 },
    "reference": { "path": "references/opaque-0001.txt", "sha256": "<64 lowercase hex>", "bytes": 42 },
    "speech": true,
    "slices": { "language": "en", "accent": "us-west", "noise": "office", "duration": "short", "priority": "yes" },
    "terms": [{ "text": "private expected term", "category": "entity" }]
  }]
}
```

Paths must be canonical relative paths with no `.`/`..`, backslashes, absolute paths, directories, or symlinks. Verification checks the byte count and digest before any transcript is decoded. Transcript files must be UTF-8, contain no NUL, and be at most 1 MiB. Sample and slice identifiers are bounded safe identifiers; they are used for local joins but omitted from aggregate output.

Keep provenance and a reviewed license/consent record in the external manifest even when redistribution is restricted. The manifest format records that evidence; it does not grant rights or download a corpus. Corpus acquisition, speaker consent, supported-language coverage, and license review remain external release responsibilities.

Recommended slices cover:

- short, medium, and near-10-minute dictation;
- punctuation, numbers, names, and domain vocabulary through `terms`;
- supported languages and representative accents;
- clean, office, outdoor, and deliberately adverse noise;
- true silence and non-speech noise (`speech: false`);
- a small declared priority set used for no-regression decisions.

## Exact-path result manifest v1

The result manifest is local beside its hypothesis files:

```json
{
  "schema": "friday.asr-results/v1",
  "corpusManifestSha256": "<sha256 of exact corpus.json bytes>",
  "candidate": {
    "id": "parakeet-tdt-v3-current",
    "modelSha256": "<model artifact sha256>",
    "runtimeSha256": "<exact Friday/NeMo runtime artifact sha256>",
    "recognitionPath": "friday-exact-runtime",
    "mode": "offline"
  },
  "repetitions": [{
    "id": "run-1",
    "samples": [{
      "sampleId": "opaque-0001",
      "hypothesis": { "path": "hypotheses/run-1/opaque-0001.txt", "sha256": "<64 lowercase hex>", "bytes": 38 }
    }]
  }]
}
```

Each repetition must contain exactly one result for every corpus sample. Multiple repetitions measure output stability. Do not place timestamps, host paths, transcript strings, partial hypotheses, or audio in this JSON. The exact-path runner should disable network access, start from the same canonical WAV bytes for every candidate, use the release candidate's conversion/runtime configuration, and atomically write each hypothesis before hashing it.

## Deterministic metrics

The first repetition supplies quality metrics; all repetitions supply stability:

- **Raw WER/CER:** speech samples only, using NFKC text with whitespace collapsed; case and punctuation remain significant.
- **Normalized WER/CER:** NFKC, Unicode lowercase, normalized apostrophes, Unicode letter/mark/number tokens, one ASCII space between tokens. WER is token edit distance; CER is code-point edit distance over the normalized text.
- **Punctuation:** speech samples only, with precision/recall/F1 from the longest common subsequence of Unicode punctuation marks.
- **Capitalization:** exact-case accuracy for lexically aligned Unicode words.
- **Leading-word retention:** first normalized reference word equals the first hypothesis word.
- **Silence:** a normalized nonempty result on `speech: false` is a false accept; an empty result on `speech: true` is a false reject.
- **Entity/vocabulary/number recall:** an optional normalized term must occur as a contiguous token sequence.
- **Stability:** exact normalized agreement and edit disagreement of each later repetition against repetition one.
- **Slices:** the complete metric set is emitted for `all` and every `key=value` slice, sorted deterministically.
- **Paired comparison:** normalized WER absolute delta, relative improvement, and a deterministic 2,000-sample paired bootstrap 95% interval over speech samples.

Rates with no eligible denominator are JSON `null`, not an inferred pass. The report includes corpus/candidate hashes and aggregate counts, but hard-codes privacy flags and contains no audio, transcripts, hypotheses, sample IDs, or raw paths. Treat the aggregate as shareable only after independently reviewing slice labels and candidate IDs; use opaque labels if those names are sensitive.

Friday's current replacement gate remains a 5% relative aggregate WER improvement with the paired confidence interval excluding zero, no priority slice regression beyond 5% relative or 0.5 absolute WER, and no punctuation/capitalization regression. The report provides the evidence; release owners still review coverage, licensing, long-form behavior, latency, memory, energy, and privacy before changing the default.
