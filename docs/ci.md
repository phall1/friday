# CI runner contract

Friday is a public repository. CI uses GitHub's **standard `macos-14` ARM64
runner**, which is free for public repositories. The former `macos-14-xlarge`
label selects billed larger-runner compute. Keep the explicit OS label to
preserve Sonoma coverage and avoid an implicit OS/golden migration through
`macos-latest`.

Sources checked September 9, 2026:

- [GitHub standard runner specifications and public-repository pricing](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories)
- [macOS 14 ARM64 image and installed tools](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-arm64-Readme.md)

The standard runner has 3 M1 CPU cores and 7 GB RAM. CI still refuses Intel and
Rosetta, installs Node 24 and Zig 0.16.0, applies the pinned Native SDK patch,
builds the production ARM64 application, and runs all TypeScript/native
contracts plus all fourteen UI/accessibility/keyboard scenes. The automation
binary is separately built and inspected. Each scene failure contributes to
the final failing exit status, and diagnostics are uploaded even on failure.

The `free-v1` concurrency namespace applies only to new workflow revisions.
Running jobs are not canceled; previous queued/running jobs retain their
original runner selection. Within the new group GitHub can replace an older
pending run with a newer pending run for the same PR/ref.

## Hosted validation

The first standard-runner run must pass the complete existing workflow before
the migration is considered runtime-validated. Local static checks cannot
establish hosted GUI compatibility or whether the 45-minute timeout is enough
on the smaller machine. Inspect the job's runner architecture/image version,
production build, contract tests, and all fourteen scene results.

On UI failure, inspect `friday-ui-results` (`actual.png`, `expected.png`,
`snapshot.txt`, `capture.txt`, and `app.log`). The harness chooses the existing
1× or 2× baseline from the actual display scale and compares bytes exactly.
Diagnose rendering, accessibility, keyboard, or resource failures from those
artifacts; baseline changes require the visual review described in
[`tests/screenshots/README.md`](../tests/screenshots/README.md).

## Image lifecycle

[GitHub plans to retire macOS 14 on November 2, 2026](https://github.com/actions/runner-images/issues/13518).
Before retirement, migrate to a supported standard ARM64 image (for example,
`macos-26`) and validate the entire native/UI matrix on that image, including
review of any actual rendering differences. The current billing migration
retains macOS 14 to keep that compatibility change independently verifiable.
