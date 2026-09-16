# OpenClaw Access
Native SwiftUI macOS utility for managing Slack DM pairing requests using the installed OpenClaw CLI. Neutral macOS styling. No Slack tokens stored by this app.

Build: ./build.sh (universal Intel/Apple Silicon, macOS 13+).
Tests: ./test.sh (isolated CLI fixture; no live Slack changes).

Do not invent pairing reject commands or edit OpenClaw credential stores. Prefer channels.pairing gateway methods. Legacy CLI approval can bootstrap the first command owner; retain the explicit warning. Treat authentication failures as failures, never silently fall back. Pass untrusted values as process arguments. Keep BACKLOG.md current. Never include fixtures in the shipped app.
