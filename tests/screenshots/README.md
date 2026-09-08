# UI goldens

Each scene has an exact PNG baseline for the display scale reported by the
Native SDK's `main-canvas` snapshot:

- `1x/`: standard-density display, including GitHub's `macos-14-xlarge` runner.
- `2x/`: Retina display.

Both sets are **640×480 software-renderer captures**. Display scale still
affects layout pixel snapping, control widths, and hairlines before capture.
For example, a 42.5-point position stays at 42.5 on Retina but snaps to 43 on
a 1× display. Comparing those images with each other creates false failures.

`tests/ui-automation.sh` reads the real display scale, selects only its matching
baseline, and compares bytes exactly. Missing baselines, unsupported scales,
visual changes, accessibility failures, and keyboard failures still fail.
No image tolerance or automatic baseline update is used.

## Reviewing an update

1. Run the scene on the display scale you intend to update.
2. Review the capture and its controls, text, contrast, and layout.
3. Use `tests/ui-automation.sh --update <scene>` to accept that scale's image.
4. Review the other scale too when changing shared UI. CI artifacts contain
   `actual.png`, `expected.png`, `snapshot.txt`, `capture.txt`, and `app.log` for
   each scene. A reviewed CI capture can be copied to its matching `1x/` path.

The original `2x/` files retain the previously reviewed local goldens unchanged.
The initial `1x/` files were visually compared with those goldens and were
byte-identical across independent GitHub runs
[34057671087](https://github.com/phall1/friday/actions/runs/34057671087) and
[34057793151](https://github.com/phall1/friday/actions/runs/34057793151).
