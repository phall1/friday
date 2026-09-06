# Friday UX: a small, dependable utility

## Intent

Friday's everyday job is to turn a thought into text in the app already in use.
Its UI should answer three questions: **Can I talk? How do I start? Where did
my words go?** Configuration supports that loop; it should not dominate it.

This refines the existing [product contract](PRODUCT.md), including local-only
ASR, final-only delivery, exact-source targeting, and explicit fallback. It adds
no transcript library, assistant, or cloud dependency.

## User stories and acceptance

| Situation | User need | Acceptance |
| --- | --- | --- |
| Everyday dictation | Know Friday is ready and remember my shortcut | One prominent status area; the active shortcut is visible in Controls; Start is the only primary action at rest. |
| Menu-bar glance | Start or stop without opening a settings window | Native menu opens alone; compact status, legal Start/Stop/Cancel actions, Open Friday, Models, Access, Quit. Full explanations stay in the tooltip/window. |
| Adjust preferences | See the whole small utility at once | At 640×480, normal Controls shows input, shortcut, lock timing, paste, capsule, and login settings without scrolling, including after an ordinary clipboard result. Long exceptional messages may scroll. |
| Choose a shortcut | Try a candidate without losing the current shortcut | A focused editor contains presets, capture instructions, candidate warning, explicit confirmation, and cancellation. The active shortcut survives dismissal. |
| Tune locking | Adjust the gesture to my hand | A native slider covers 200–500 ms in 10 ms steps, with a live readout and keyboard adjustment. Saving is debounced and cannot interrupt a dictation session or erase a pending result. |
| Disable locking | Understand which controls still apply | The interval slider is visibly disabled while double-tap locking is off or dictation is active. |
| Navigate settings | Move between stable destinations | A fixed sidebar exposes Controls, Models, Access, and Diagnostics with pointer, accessibility, and arrow-key navigation. The selected section is distinct in both appearances. |
| First launch | Understand what is needed and why | Four existing steps: privacy, permissions, shortcut, verified local model. Each has a clear forward action and honest blocking state. |
| Missing access | Recover the specific missing capability | Access shows each permission separately, its purpose, observed state, and direct recovery action. Color supplements the text. |
| Model management | Know what is installed and what can actually run | Active model is distinct from alternatives; metadata-only inspection is explicitly labeled; verification policy and destructive actions remain clear. |
| Failed dictation | Recover without guessing whether text was delivered | Failure detail and Retry/Copy/Dismiss remain reachable; pasted/copied/shown outcomes are truthful. |
| Discover the project | Understand Friday before reading build internals | README leads with the benefit, a real app-rendered screenshot, basic usage, privacy, and installation; engineering details live below. |

## Visual language

Use the [design system](../../docs/design-system.md): cobalt action accent,
neutral navigation rail, flat ruled content, monochrome switches, amber
attention, and red live recording. Prose uses bundled IBM Plex Sans.
Headings establish hierarchy; monospace
is reserved for elapsed time and machine identifiers. Do not use a pretend input
meter when the microphone is not recording.

## Verification

- Compile and run core/native contract tests.
- Exercise existing deterministic UI scenes in light and dark appearances,
  including ready Controls and the completed clipboard-result state.
- Check geometry of every everyday control against the viewport, not just its
  presence in the accessibility tree. A clipped control is a failed layout.
- Verify shortcut-dialog dismissal, disabled lock timing, and menu-only opening.
- Review rendered PNGs before updating goldens. README image must come from the
  renderer and identify deterministic fixture data; no reconstructed mockup.
- Preserve user settings, model files, clipboard, and installed-app availability
  while running automation.

## Verification record — 2026-09-06

The initial compact-Controls candidate, before the sidebar/slider refinement:

- Native checker and arm64 builds passed; 58 TypeScript tests and the native
  contract-test build passed.
- All 14 reviewed renderer goldens matched byte-for-byte. Ready Controls in
  both appearances, clipboard-result Controls, and permission setup passed
  viewport/no-scroll checks. Shortcut-dialog Tab → Escape dismissed the dialog
  and retained the current shortcut.
- The signed development package passed signature and arm64-only verification.
- Packaged E2E passed setup scenes, menu navigation, real microphone capture,
  Stop → transcribing → ready, the in-process locked-recording probe, and Cancel.
  The full run stopped at the native debug contract assertion: capsule
  `keyboardContract`, `voiceOverContract`, and `terminalContract` were false.
  The same diagnostic reported false hotkey `modifierSafe`, `keyBasedSafe`, and
  `functionDownUp` facts. Later E2E stages were not reached; this run is not a
  complete E2E pass.
- In this harness the OS window reports unfocused, so AppKit suppresses widget
  focus flags. The dialog's observable Escape result is asserted regardless;
  its per-widget focus assertion also runs when an active OS window is present.

The [release checklist](../../docs/friday-release-checklist.md) remains the
authority for normal-GUI keyboard, VoiceOver, capsule, and exact-source insertion
acceptance. Renderer captures are not evidence of those platform contracts.

## Sidebar and slider verification — 2026-09-06

- All 59 TypeScript tests pass, including interval bounds, debounce behavior,
  session/result/editor preservation, and scrubbed persistence before Quit.
  Native contract tests passed for the font/theme refinement, including
  preservation of high-contrast control colors, focus strokes, and Reduce Motion.
- The final arm64 automation build passed. All 14 renderer goldens were
  reviewed and then matched byte-for-byte. Ready Controls in both appearances,
  clipboard-result Controls (including Dismiss), and permission setup passed
  in-viewport/no-scroll assertions at 640×480.
- Pointer/accessibility activation traversed all four sidebar destinations;
  Arrow Down selected Models from Controls. The interval slider passed drag
  to 440 ms, Home to 200 ms, Arrow Right to 220 ms, and End to 500 ms. Its
  accessible name reflected the live milliseconds and supported range.
  Recording disables the interval and locking controls. Shortcut-dialog
  Tab/Escape still dismisses without replacing the active shortcut.
- README uses the actual updated dark Controls capture. The release preflight
  and CI both cover all 14 scenes. Icon integrity and SDK patch reverse-check
  passed.
- Native compilation exceeded timed foreground limits; an unrestricted
  `zig build -Dtarget=aarch64-macos -Dautomation=true -j2` completed successfully.
- The full packaged E2E suite was not rerun for this visual refinement. The
  earlier capsule/hotkey contract failures above remain unresolved; the visual
  checks do not close the normal-GUI release gates.
