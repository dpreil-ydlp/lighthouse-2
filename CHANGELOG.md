# Changelog

All notable changes to Lighthouse 2. Newest first. Versions follow the app's
`CFBundleShortVersionString`. Release notes for each version are in
[docs/release-notes/](docs/release-notes/).

## 0.0.12 — 2026-11-03

### Changed
- Opening a project lists every thread that needs you first, each with its own
  yellow **Needs you** tag (oldest wait first), then the usual threads.
- **Needs you** tags are buttons. On a thread, the tag opens that thread in its
  app. On a project, it opens the thread when one waits, and expands the row
  when several do. The row's T3 Code ↗ button is unchanged.

## 0.0.11 — 2026-11-03

### Fixed
- The red count next to the lighthouse now shows in the menu bar. The menu bar
  shows only one image, and the count was a second image, so macOS dropped it
  (0.0.7–0.0.10). The logo and the count are now one image.

### Changed
- The menu bar icon only says whether something needs you: the lighthouse,
  plus the count in red when a thread waits for you. Usage arcs, the dimmed
  "stale" look and the filled "gone quiet" logo are gone (gone quiet still shows
  in the panel). The optional "% left" text stays a Settings choice, off by default.

## 0.0.10 — 2026-11-03

### Changed
- The menu bar is back to the lighthouse with the count next to it, now in
  red. The red diamond before the lighthouse (0.0.8) is gone.

## 0.0.9 — 2026-11-03

### Fixed
- No more Keychain prompts for Claude usage. Lighthouse now reads Claude
  Code's sign-in item through Apple's `/usr/bin/security`, the tool Claude Code
  itself uses for that item, so macOS does not ask. Before, the "Always Allow"
  was tied to Lighthouse's own signature, and every update (and some Claude
  Code token refreshes) asked again.

## 0.0.8 — 2026-11-03

### Changed
- **Needs you** is judged by what the run actually needs. With summaries on,
  the summary model also answers whether the thread can go on without you:
  a finished run, a report, or an optional offer ("install it if you like")
  is not "needs you"; a question, a choice, an approval, or a task for you
  (sign in, test, send a file) is. With summaries off, stricter wording rules
  are used (last paragraph only; quoted examples ignored). A thread where you
  wrote last never counts.
- The menu bar shows a red ◆ and the count **before** the lighthouse when
  something needs you; the panel no longer repeats it at the top. The yellow
  tag stays on each row.

### Tests
- `SummaryTests.unchangedThreadIsNeverDue` now uses a current-format summary
  (one with a judgment); summaries saved before 0.0.8 are judged once, covered
  by `summaryWithoutJudgmentIsDueOnceWhenFinished`.

## 0.0.7 — 2026-11-03

### Added
- **Needs you** now also covers agents that finish by asking you something
  ("Want me to push it?", "won't start until you say go") without raising an
  approval or input request. Lighthouse reads the end of the last agent message
  on your Mac with fixed wording rules; nothing is sent and no text is saved.
  It clears when you reply.

### Changed
- Search is a magnifier until you click it (or press ⌘F, or start typing);
  then the field slides open. Esc, or clicking away with nothing typed, folds it
  back.
- The gear closes the panel and opens Settings in front.
- The attention count is red, in the menu bar and in the panel.

## 0.0.6 — 2026-11-03

### Fixed
- The gear (and the other Settings links in the panel) now brings the Settings
  window to the front. Before, it opened behind the app you were in.
- The Open button on a project row is one short line ("T3 Code ↗"), so the row
  no longer grows when you hover it.

### Changed
- The search field is always visible at the top of the panel, beside the name.
  Typing anywhere still starts a search, and ⌘F still focuses it.
- Usage opens compact (one line per provider). Click **USAGE** for the detail
  view; the choice is saved.

## 0.0.5 — 2026-11-02

### Added
- Click **USAGE** at the top of the panel to show one line per provider (percent
  left for the session and the week). Click it again for the full view. The
  choice is saved.
- A yellow **Needs you** tag on a project whose thread or subagent waits for
  your approval or answer.

### Changed
- Each project's status (Working, Recent, No activity) now sits on the first
  line beside the app labels; the thread count is gone. Rows are shorter, so
  more projects fit.
- With many projects the panel can grow to nearly the full screen height
  (it stopped at 720 points before).

## 0.0.4 — 2026-11-02

### Fixed
- AI summaries no longer start with a format label such as "Line 1 (≤90 chars):".
  Summaries saved before this fix are cleaned when shown.
- The line under a project no longer repeats the project or thread name at its
  start ("Groove migration: 3 of 4 invites sent" shows "3 of 4 invites sent").
- With Quiet hidden and nothing recent, the shelf says "No recent activity"
  instead of "No projects yet".

## 0.0.3 — 2026-11-02

### Added
- **Recently completed** shelf group. A project whose agents stopped within the
  last 24 hours stays on the shelf, open and sorted newest first, so work left
  overnight is there the next morning.
- Settings › General › Shelf › **Keep in Recently completed for**: 4, 8, 12 or
  24 hours, or 2, 3 or 7 days. The default is 24 hours. The change applies at
  once.
- Settings › General › Shelf › **Show Quiet projects**. Off by default.
- A third line on active and recently completed project rows: the AI summary
  of the thread that matters most, or that thread's title when no summary
  exists.

### Changed
- The Quiet group is hidden by default. Search still finds its projects and
  threads.
- Projects move to Quiet only after the Recently completed window ends. Before
  this change, they moved there 15 minutes after their last activity.
- Shorter text across the app: onboarding, settings, footers, help tips, empty
  states and the T3 outage notification.

### Removed
- The AI summary icon next to summaries. The thread page caption
  "AI summary · model · age" and the accessibility labels stay.

## 0.0.2 — 2026-11-01

First public release, named Lighthouse 2
([release](https://github.com/dpreil-ydlp/lighthouse-2/releases/tag/v0.0.2)).

- Menu bar panel with Claude and Codex usage left and the pace against each
  window's reset.
- Project shelf for Claude Code, Codex and T3 Code sessions: Pinned, Active,
  Quiet, Paused, Archived and Unassigned groups, with threads and subagents
  under each project.
- Attention strip and opt-in notifications for agents that wait for you, go
  quiet or stall.
- Open button that goes to the thread in T3 Code, the ChatGPT (Codex) app or
  the Claude app.
- Optional one-line thread summaries through your own Claude or Codex CLI. Off
  by default.
- ⌃⌥Space hotkey, keyboard navigation, login item, `install.sh` installer.
