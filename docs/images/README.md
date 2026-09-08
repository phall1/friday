# Screenshot provenance

`friday-controls.png` is copied from the reviewed
`tests/screenshots/2x/settings-dark.png` golden. It is a 640×480 capture of Friday's
actual Native SDK canvas renderer, using the deterministic ready-state fixture
in `src/automation.ts`. The microphone format, model, shortcut, and login state
are fixture data; no user audio, text, or private settings are captured.

The image is not a mockup and does not include macOS window chrome.

To refresh after a reviewed design change on a Retina (2×) display:

```sh
mise exec -- zig build -Dtarget=aarch64-macos -Dautomation=true
FRIDAY_APP_BINARY="$PWD/zig-out/bin/friday" tests/ui-automation.sh --update settings-dark
cp tests/screenshots/2x/settings-dark.png docs/images/friday-controls.png
```

The harness preserves and restores Friday settings and refuses to race a
running copy of the app. Review the renderer image before accepting a golden.

The harness selects [display-specific goldens](../../tests/screenshots/README.md)
from the actual canvas scale. Both capture sizes are 640×480; native pixel
snapping differs between 1× and 2× displays.
