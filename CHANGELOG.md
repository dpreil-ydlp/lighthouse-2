# Changelog

All notable changes to Lighthouse 2. Newest first. Versions follow the app's
`CFBundleShortVersionString`. Release notes for each version are in
[docs/release-notes/](docs/release-notes/).

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
