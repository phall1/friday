# Friday design system

Friday is a small, dependable dictation instrument. Its interface should feel
precise, composed, and immediately useful: a fixed navigation rail, a clear
type scale, flat sections, and restrained color.

## Principles

1. **The daily loop comes first.** Ready → record → transcribe → delivered.
2. **Density is a usability constraint.** Normal Controls fits at 640×480. Do
   not turn a few preferences into a long form through repeated headings and
   padding. Exceptional recovery content may scroll.
3. **One status, one next action.** Do not repeat the workflow in the header,
   hero, and microphone row. A stopped microphone does not have a live meter.
4. **Reveal complexity at the point of use.** Shortcut editing has its own
   dialog. Low-frequency settings do not belong in the menu-bar quick actions.
5. **Color carries meaning, text carries certainty.** Never communicate a
   permission, recording state, or failure solely through color.

## Tokens

The Native SDK Geist register supplies control metrics, surfaces, contrast,
and focus treatment. `projectThemeState` owns Friday's cobalt accent;
`native/design.zig` layers IBM Plex Sans and tighter geometry over the live
theme. Bundled fonts and their OFL license live in `native/fonts/`.

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| `accent` | `#476fd9` | `#476fd9` | Primary action, readiness mark, slider fill |
| `accent_text` | SDK contrast-selected | SDK contrast-selected | Text on accent controls |
| `surface_subtle` | SDK neutral wash | SDK neutral wash | Window field, inset notices |
| `surface` | SDK white | SDK black | Main content field |
| `text` / `text_muted` | SDK | SDK | Primary / supporting text |
| `success` | SDK green | SDK green | Ready and granted indicators |
| `warning` | SDK amber | SDK amber | Recovery and invalid candidates |
| `destructive` | SDK red | SDK red | Live recording and deletion |

Colors in markup are token references. System appearance is followed live;
high contrast suppresses the custom accent through the SDK. Native title bars
follow macOS even when test fixtures force canvas appearance.
The cobalt is 4.62:1 against white and 4.54:1 against black. A shared accent
also remains legible while transient appearance facts rehydrate after saving
preferences; no cached OS appearance is needed to choose its color.

## Layout and typography

- Window: 640×480 default. Navigation: 148 px fixed rail, 12 px insets,
  6 px item gaps, and a 1 px vertical divider. Content: 20 px insets and
  10 px section gaps. Controls uses flat sections separated by rules.
- Navigation: SDK `tree` with four labeled, icon-bearing `treeitem` rows.
  Selection follows arrow-key focus; pointer and accessibility activation
  open the same destination. The rail never scrolls with the content.
- Wordmark: 1.6× body, SemiBold. Headline: 1.4× body, Medium.
  Body: Plex Sans Regular 14 px; supporting copy: 13 px; controls: Medium
  13 px. The native theme hook registers real Regular/Medium/SemiBold faces;
  custom span weights resolve to their companion font IDs.
- Status: 20 px semantic icon and headline beside the action; the wrapped
  explanation gets its own full-width row so recording controls cannot clip it.
- Preference labels align left; label-free, accessibly named switches align
  right. Switch tracks are monochrome with a 6 px corner and a contrasting
  thumb. Disabled controls retain native semantics and hit-testing behavior.
- Tap interval: the Geist slider primitive, 200–500 ms in 10 ms steps, with
  a live fixed-width monospace readout. Dragging and keyboard input update the
  model. A 500 ms debounce saves through the scrubbed persistence boundary;
  an active session, failure, undismissed result, shortcut editor, or another
  settings destination postpones the save. Normal Quit persists the scrubbed
  preferences before shutdown so a deferred interval survives relaunch.
  The slider's accessible name includes its live milliseconds and range.
  Turning locking off or starting dictation disables interval editing.
- Completed-session messages replace the status description; Copy/Dismiss sit
  in the footer. Do not add a second result card that forces Controls to scroll.
- Monospace: time, revision, byte telemetry; never ordinary prose.
- Controls: `size="sm"` consistently. Primary for progression, outline for
  configuration, ghost for low-emphasis actions, destructive for deletion.
- Icons: SDK vector vocabulary. Icons supplement accessible labels;
  controls retain text names.
- Shortcut dialog: 20 px padding, 12 px gap. Candidate warnings wrap. Presets
  remain one-action choices; custom candidates require confirmation.
  Use an explicit heading inside the column: the SDK's surface `text` title
  paints over content without reserving a row. Autofocus the first preset so
  Escape has a focused descendant from which to resolve the modal boundary.
  Warning prose uses primary text ink for contrast in both appearances.

The stock SDK runner accepts optional extension font registrations and a
post-resolution theme refinement hook through the checked-in SDK patch.
Friday only refines type/shape and normal-contrast switch colors. High contrast
keeps all SDK control colors, while Reduce Motion, focus strokes, and device
scale remain runtime-owned. This does not require a custom application runner.

## Menu bar

Keep the native menu and system keyboard behavior. The mark retains its
identity: red while live, dim while working, `!` only for a failure. The status
row uses one short label with no wide secondary explanation. Full state detail
remains in the tooltip and main window. Launch at Login lives in Controls.

## Capsule and icon

The nonactivating, movable native capsule remains 232×36, with system material,
meter, timer, and independent Stop/Hide/Cancel actions. It respects contrast,
transparency, and Reduce Motion. The canonical app/menu icons remain hash-pinned
by `scripts/verify-icon.sh`.

## Evidence

See [UX stories and acceptance](../specs/friday/UX.md). UI automation must assert
in-viewport bounds for everyday controls in addition to accessible names and
keyboard focus. A golden that hides Launch at Login below the fold is not an
acceptable baseline. README screenshots are actual app-renderer captures of
deterministic scenes, not drawings of a proposed UI.
