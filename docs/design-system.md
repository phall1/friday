# Friday Design System — Arc

Elite, restrained, instrument-grade. Less, but better.

## Principles

- One primary action per screen. Everything else is subordinate.
- Whitespace is structure. Cards breathe; rows do not compete.
- Monospace is telemetry only: time, shortcuts, revisions, byte counts.
- Color is semantic: system surfaces by default, red for live/destructive only.
- No gradients, glows, holograms, or decorative chrome.

## Layout

- Window: 640×480, fixed by harness.
- Outer content: `padding="20" gap="12"`.
- Header command bar: `padding="12" gap="8" cross="center"`.
- Sections are flat full-bleed groups: medium title row, one hairline
  `separator`, then a `padding="16" gap="12"` body. The Geist pack does not
  tint surfaces (`surface` == page), so elevation comes from the hairline,
  spacing, and type — never a tinted card. `surface` + `border-color` are
  still declared on section containers as intent; the engine paints the
  hairline where it applies.
- Floating dialogs only (unsupported gate, capsule preview): `surface`
  card, `radius="xl"` (the pack's 12 px floating surface), centered with
  `width` + spacers.
- Inner notice panels (capture/candidate/limited-mode): `surface_subtle`
  (the pack's resting wash), `border-color`, `radius="md"`, `padding="12"`.
- Separators only between groups, never between rows inside a section body.

## Typography

- Title: `<span weight="medium">`, default size.
- Body: default.
- Meta: `foreground="text_muted" wrap="true"`.
- Telemetry: `<span mono="true">` for elapsed, shortcut labels, `rev …`, byte counts, step labels.
- Never mono for prose, headings, or buttons.

## Components

- Navigation: one `toggle-group` (Controls / Models / Access / Diagnostics).
- Status instrument: one surface card with waveform, state name (medium), detail (muted, wrap), shortcut telemetry, and a single primary action.
- Sections: `Local models`, `Input`, `Trigger`, `Behavior`, `Output`, `Permissions`, `Safe export` — each one card.
- Buttons: `size="sm"`. Primary only for the single forward action. Destructive only for delete/cancel. Ghost for dismiss/secondary.
- Progress: bounded, labeled, followed by byte telemetry.
- Switches carry their own labels; no duplicate explanatory rows.

## Color and theme

- Pack: `geist`. Color scheme follows system via `appearanceOverride`.
- No hardcoded colors in markup. Dark and light both use theme tokens.
- Recording/live and destructive actions use semantic system red. Nothing else is red.
- High contrast and Reduce Motion are respected by the platform and native capsule.

## Native capsule

- Nonactivating panel, 232×36, system vibrant material, 0.5 pt separator border (1.5 pt in high contrast).
- Five-bar waveform: system red while held/locked, orange on failure, secondary label otherwise.
- Monospaced digit timer, Stop/Hide/Cancel hit targets ≥ 24 px.
- Fade only when motion is allowed. No live-reader announcements for meter updates.
- Geometry and contracts are frozen by `overlay.zig` probe tests; visual changes stay inside those bounds.

## Icon

- Hash-pinned (`scripts/verify-icon.sh`). Any redraw ships with updated hashes, 1024×1024 PNG + SVG, and reviewed goldens. Deferred.

## Accessibility

- Every scene keeps its REQUIRED strings verbatim.
- Long copy always `wrap="true"`; truncation (`…`) is a failure.
- Tab/Shift+Tab always lands on a focused control.
- All actions have accessible names; icon-only native buttons keep tooltips and key equivalents.
