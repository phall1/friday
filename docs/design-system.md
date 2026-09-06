# Friday design system

Friday is a small, dependable dictation utility. Its interface should feel
welcoming, legible, and immediately useful.

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

The Native SDK Geist register supplies control metrics, typography, surfaces,
contrast, and focus treatment. `projectThemeState` owns Friday's copper accent:

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| `accent` | `#a1693e` | `#a1693e` | Friday wordmark, primary action, selected controls |
| `accent_text` | SDK contrast-selected | SDK contrast-selected | Text on accent controls |
| `surface_subtle` | SDK neutral wash | SDK neutral wash | Window field, inset notices |
| `surface` | SDK white | SDK black | Content groups and header |
| `text` / `text_muted` | SDK | SDK | Primary / supporting text |
| `success` | SDK green | SDK green | Ready and granted indicators |
| `warning` | SDK amber | SDK amber | Recovery and invalid candidates |
| `destructive` | SDK red | SDK red | Live recording and deletion |

Colors in markup are token references. System appearance is followed live;
high contrast suppresses the custom accent through the SDK. Native title bars
follow macOS even when test fixtures force canvas appearance.
The copper is 4.56:1 against white and 4.61:1 against black. A shared accent
also remains legible while transient appearance facts rehydrate after saving
preferences; no cached OS appearance is needed to choose its color.

## Layout and typography

- Window: 640×480 default. Main content: 12 px padding, 8 px group gap.
- Header: 12 px padding; wordmark at 1.4× body, bold; four compact text tabs.
- Status area: 12 px padding; 28 px semantic icon; 1.4× medium headline;
  small wrapped description. Primary action sits beside it.
- Settings groups: 12 px padding, 8 px row gaps, `lg` radius. Separate
  input/shortcut/lock from output/window/login preferences.
- Completed-session messages replace the status description; Copy/Dismiss sit
  in the footer. Do not add a second result card that forces Controls to scroll.
- Body: default proportional type. Supporting copy: `size="sm"`, muted.
- Monospace: time, revision, byte telemetry; never ordinary prose.
- Controls: `size="sm"` consistently. Primary for progression, outline for
  configuration, ghost for low-emphasis actions, destructive for deletion.
- Icons: SDK vector vocabulary, 20 px in settings, 14 px in the privacy footer.
  Icons supplement accessible labels; controls retain text names.
- Shortcut dialog: 20 px padding, 12 px gap. Candidate warnings wrap. Presets
  remain one-action choices; custom candidates require confirmation.
  Use an explicit heading inside the column: the SDK's surface `text` title
  paints over content without reserving a row. Autofocus the first preset so
  Escape has a focused descendant from which to resolve the modal boundary.
  Warning prose uses primary text ink for contrast in both appearances.

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
