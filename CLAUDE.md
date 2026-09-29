# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Status

Shipped: the app, the widget extension and the Swift collector are implemented and released as an
unsigned DMG. [PLAN.md](PLAN.md) is now history plus the open items — read it for the design
rationale and for what is still unresolved (the widget gallery icon), not as a to-do list.

## Language

Comments, user-visible strings, error messages, and docs are in **English**. Keep that standard.

## The data contract

This widget is the only implementation in use. It started as a port of
`../ai-usage-monitor/cli/usage_monitor.py`, and comments still cite that file as the origin of the
`Provider` / `Meter` shape and the `collect*` behaviour, but the Python project is no longer
maintained. **Change the widget only** — do not mirror changes into ai-usage-monitor, and do not
treat it as authoritative when the two disagree.

## Architecture (target)

- `Packages/UsageKit` — local Swift package, two products:
  - `UsageModel` — `Provider`, `Meter`, `Snapshot`, formatting helpers. Linked by the app *and* the
    widget extension.
  - `UsageCollector` — Claude / Codex / Cursor collection, config store, accounts. Linked by the app
    only; the widget extension is sandboxed and cannot collect.
- App target — `MenuBarExtra` panel, notifications, `Settings` scene, poll loop.
- Widget extension — `TimelineProvider` reading a snapshot the app writes. It never collects.

Each `collect*` captures its own failure and returns a `Provider` with `error` filled in; it never
propagates.

## Security

Tokens, cookies, and keys never appear in the UI, in logs, or in process arguments. Config
directories are `0700`, credential files `0600`. Never copy credentials into chats, issues, or
commits.
