---
title: Keyboard Shortcuts
date: 2026-05-08
status: implemented
---

# Keyboard Shortcuts Design

## Problem

The AoD web app has no keyboard shortcuts. Power users must reach for the mouse to submit forms, navigate between sections, and discover help. The two highest-friction spots are:

1. **New conversation page** — after typing a prompt the user must click "Start".
2. **Conversation show page** — after typing a follow-up the user must click "Send".

## Goals

- `Cmd/Ctrl+Enter` submits the active textarea form on both pages.
- Global navigation shortcuts let users jump to any main section without a mouse.
- A discoverable cheatsheet lists all shortcuts so users don't have to guess.

## Non-goals

- Per-page action shortcuts (Interrupt, Terminate, Delete) — these require confirmations and are safety-sensitive.
- Persistent shortcut preferences.

## Architecture

All JS lives inline in `root.html.heex` (the existing pattern). No new build step or npm dependency needed.

### SubmitOnCmdEnter LiveView hook

Attached via `phx-hook="SubmitOnCmdEnter"` on the `<textarea>` rendered by the `.input` component. On `keydown`, checks `(metaKey || ctrlKey) && key === "Enter"` and calls `form.requestSubmit()` on the closest ancestor `<form>`. Registered in the `Hooks` object passed to `LiveSocket`.

To support passing `phx-hook` through `.input`, the `input` component's `:rest` global attr include list gains `"phx-hook"`.

### Global keyboard listener

A `document.addEventListener("keydown", ...)` is added after `DOMContentLoaded`. All shortcuts except `Escape` and `?` are skipped when focus is inside an `input`, `textarea`, `select`, or `contenteditable` element.

**g-chord navigation** — pressing `g` sets a `gPending` flag (auto-cleared after 1.5 s). The next keypress is consumed as the chord target:

| Second key | Destination |
|------------|-------------|
| `c` | `/conversations/new` |
| `h` | `/help` |
| `a` | `/agents` |
| `e` | `/environments` |
| `v` | `/vaults` |

Navigation uses `window.location.href` so LiveView navigate events fire correctly.

### Cheatsheet modal

A `<div id="kbd-cheatsheet">` is added directly in `root.html.heex` before `{@inner_content}`. It is always present in the DOM (every page) but starts `hidden`. Toggled by:

- `?` key (when not editing, or to close when open)
- `Escape` (always closes)
- Clicking the backdrop
- Clicking the `×` close button

A small "shortcuts" button in the sidebar footer also toggles the modal, making it discoverable without knowing the `?` shortcut.

## Files changed

| File | Change |
|------|--------|
| `root.html.heex` | Add cheatsheet modal HTML + JS (hooks, global listener) |
| `core_components.ex` | Add `phx-hook` to `input` `:rest` include list |
| `conversations_live/new.ex` | Add `phx-hook="SubmitOnCmdEnter"` to prompt textarea |
| `conversations_live/show.ex` | Add `phx-hook="SubmitOnCmdEnter"` to send-prompt textarea |
| `layouts.ex` | Add sidebar shortcuts button |
