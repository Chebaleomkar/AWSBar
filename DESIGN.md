# AWSBar popover design guidelines

Scope: the menu bar popover (`PopoverView`, `HeaderView`, `ResourcesView`). Native SwiftUI on macOS, system fonts and system colors only. Values below are what the code uses today unless marked "should".

## 1. Context and goals

The popover answers one question fast: what is running in this AWS account, and what does it cost. It is glanced at, not studied. It must feel like a native macOS panel: quiet, system-styled, adapts to light and dark mode.

Rules use "must" for non-negotiable and "should" for recommended.

## 2. Tokens and foundations

**Size.** Popover is 400 x 560 pt. Horizontal padding is 14 pt on header, tabs and footer; 8 pt on the scrolling list.

**Spacing scale (pt).** 4, 6, 8, 12, 14, 22.
- 4: row vertical padding, gap between name and detail lines (1).
- 6: row horizontal padding, section header vertical padding, header stack gap.
- 8: gap between dot, icon and text in a row.
- 14: outer gutter.
- 22: indent of rows under a section header. Rows must use it so dots line up under the section icon.

**Type (system font, Dynamic-Type styles only).** Must not use fixed point sizes.
| Role | Style |
|---|---|
| Profile name | `.title3` semibold |
| Section title | `.headline` |
| Row name, account, amounts | body (default) |
| Row detail, "last month" line | `.subheadline`, secondary |
| Region, header lines | `.callout` |
| Hints, errors, footer | `.caption` |
Numbers that change or align (counts, money, account id) must use `.monospacedDigit()`.

**Color (semantic only).** Must not use raw hex.
| Meaning | Token |
|---|---|
| Primary text | `.primary` |
| Secondary text | `.secondary` |
| Chevron, footer path | `.tertiary` |
| Row hover fill | `Color.primary.opacity(0.06)`, radius 6 |
| Footer background | `Color.primary.opacity(0.04)` |
| Warning text | `.orange` |
| Selected tab | system accent |

**Status dot.** 8 x 8 circle, `StatusDot` in `HeaderView.swift`. This is the only status indicator.
| Status | Color | Meaning |
|---|---|---|
| running | green | Live |
| stopped | red | Exists, not running |
| transitioning | orange | Starting, stopping, deploying |
| failed | red | Error or terminated |
| neutral | clear | No state (Lambda, S3, most billing rows) |

## 3. Components

### Section header
Anatomy: chevron (10 pt wide), service symbol (18 pt wide), title, count, spacer, refresh or spinner.
States: collapsed, expanded (chevron rotates 90 degrees, 0.2 s snappy), loading (mini spinner replaces refresh). Refresh shows only when expanded.

### Resource row
Anatomy: status dot, name (one line, middle truncation), detail line (one line, middle truncation), actions on the right.
- Actions (start, stop, restart) must appear only on hover or keyboard focus, never always visible.
- Hover fill as in tokens. Long names truncate in the middle so the end of an id stays visible; full text must be in `.help`.
- Destructive actions must go through the confirm row. Server stop/restart (EC2, RDS) must require typing the name.
- Busy state replaces actions with a small spinner.

### Active services row (billing)
Anatomy: optional status dot, service name (one line, tail truncation), optional "last month" line, amount right-aligned.
- Dot appears only for services whose live state the app can read (EC2, RDS, ECS). All others must show no dot and keep the same indent, so names align.
- A dot must never be inferred from billing alone. Billing says what was charged, not what is running.

### Header
Profile menu, region, refresh, account id and role, month-to-date spend. Account id selectable. Role truncates in the middle.

## 4. Accessibility

Target WCAG 2.2 AA.

**Known conflict.** Status is carried by color alone, and stopped and failed are both red. This fails "do not use color as the only means" and cannot separate two different states.
- Priority: accessibility wins over the current look.
- Should: add a text or shape cue. Cheapest path is exposing the state to VoiceOver (below), then giving failed a different shape (for example a triangle) and keeping stopped as a dot.

**Testable criteria**
1. Every `StatusDot` must have an accessibility label equal to its status text ("running", "stopped"). Today it only has `.help`, which VoiceOver does not read reliably. Check: VoiceOver reads "running" on an EC2 row.
2. Every icon-only button (refresh, start, stop, restart) must have an accessibility label. `.help` text counts only if also set as the label.
3. All controls must be reachable by Tab; hover-only actions must also appear on keyboard focus.
4. Text must keep 4.5:1 contrast in light and dark. Using `.secondary` for detail text is allowed; `.tertiary` only for non-essential text (footer path, chevron).
5. Layout must survive larger Dynamic Type: no clipped rows at the largest size, names truncate instead of wrapping.
6. Shortcuts: Cmd-R refresh, Cmd-Q quit. New shortcuts must not collide with these.

## 5. Content and tone

Concise, plain, no jargon.
- Empty: "Nothing here", "No usage this month or last month".
- Needs sign-in: "Sign in to load EC2".
- Errors: say what failed, 4 lines max, selectable.
- Confirm prompts name the target: "Stop web-prod?".
- Do: "Stopped". Don't: "Instance in stopped lifecycle state".
- Amounts use the account currency format. Always say "this month" or "last month" next to a period.

## 6. Anti-patterns

- Raw colors or fixed font sizes (use tokens above).
- A dot on a row whose state the app cannot read.
- Always-visible action buttons on every row.
- Single-click destructive actions on servers.
- Different indents between sections (breaks dot alignment).
- Wrapping names onto two lines.
- New status colors. Add a `ResourceStatus` case instead.

## 7. Migration notes

Done in the layout rework:
- Status dots have VoiceOver labels; icon-only buttons have labels.
- Failed is a red triangle, stopped is a red dot, and every row shows the status word.
- Hover actions also show when a row has keyboard focus.
- Services are grouped (Compute, Database, Storage and functions); load balancers have a provider.
- The summary strip counts running, stopped and failed. "Active services" is now "Spend by service".

Still open:
- Lambda and S3 have no state, so they never get a dot.
- Rows are focusable, but the full Tab order has not been tested with VoiceOver.

## 8. QA checklist (code review)

- [ ] No hex colors, no fixed font sizes added.
- [ ] Indents: rows 22 pt, gutter 14 pt, dot 8 pt.
- [ ] Money and counts use `.monospacedDigit()`.
- [ ] Dot only where state is readable; others align with no dot.
- [ ] `StatusDot` and icon buttons have accessibility labels.
- [ ] Hover actions also reachable by keyboard.
- [ ] Destructive server actions require typed name.
- [ ] Checked in light and dark mode.
- [ ] Checked with a 60-character service or resource name.
- [ ] Empty, loading, error and signed-out states each render.
