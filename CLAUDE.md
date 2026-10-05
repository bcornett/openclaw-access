# OpenClaw Access
Native SwiftUI macOS utility for managing Slack DM pairing requests and scheduled-job timing using the installed OpenClaw CLI. Neutral macOS styling. No Slack tokens stored by this app.

Build: ./build.sh (universal Intel/Apple Silicon, macOS 13+).
Tests: ./test.sh (isolated CLI fixture; no live Slack changes).
UI check: ./ui.sh (clicks through the views offscreen against the fixture, writes PNGs to build/ui; update its click positions when the layout changes).
Installer: ./package.sh (build/OpenClaw-Access.dmg).

App.swift keeps logic above `@MainActor final class Model` and views below; test.sh and ui.sh cut the file at those markers.

Schedules use the cron.list, cron.update, and cron.remove gateway methods only. Change timing and enabled state, and delete a job when the user asks; never create or run jobs, edit payloads or delivery, or change or delete a job without a confirmation. Send back only schema fields (the gateway rejects unknown ones) and keep tz, staggerMs, and anchorMs unless edited. Check new fields against OpenClaw's gateway-protocol schema before using them.

Do not invent pairing reject commands or edit OpenClaw credential stores. Prefer channels.pairing gateway methods. Legacy CLI approval can bootstrap the first command owner; retain the explicit warning. Treat authentication failures as failures, never silently fall back. Pass untrusted values as process arguments. Keep BACKLOG.md current. Never include fixtures in the shipped app.
