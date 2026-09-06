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
| Disable locking | Understand which controls still apply | Timing choices are visibly disabled while double-tap locking is off. |
| First launch | Understand what is needed and why | Four existing steps: privacy, permissions, shortcut, verified local model. Each has a clear forward action and honest blocking state. |
| Missing access | Recover the specific missing capability | Access shows each permission separately, its purpose, observed state, and direct recovery action. Color supplements the text. |
| Model management | Know what is installed and what can actually run | Active model is distinct from alternatives; metadata-only inspection is explicitly labeled; verification policy and destructive actions remain clear. |
| Failed dictation | Recover without guessing whether text was delivered | Failure detail and Retry/Copy/Dismiss remain reachable; pasted/copied/shown outcomes are truthful. |
| Discover the project | Understand Friday before reading build internals | README leads with the benefit, a real app-rendered screenshot, basic usage, privacy, and installation; engineering details live below. |

## Visual language

Use the [design system](../../docs/design-system.md): copper identity/action
accent, neutral layered surfaces, green readiness, amber attention, red live
recording. Prose uses proportional type. Headings establish hierarchy; monospace
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
