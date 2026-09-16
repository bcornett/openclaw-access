# OpenClaw Access

A standalone native Mac app for reviewing pending Slack DM pairing requests in OpenClaw. Supports macOS 13 or later on Apple Silicon and Intel. The app needs no Node, Python, or Xcode runtime of its own, but requires an existing, configured OpenClaw installation and running gateway under the same Mac user.

## Install

1. Open **OpenClaw Access.dmg** and drag **OpenClaw Access** into Applications.
2. Launch it on the Mac where OpenClaw is configured.
3. Click Refresh. If needed, open Connection settings and select the OpenClaw executable or enter its profile/account.
4. Select a request and choose Approve access or Dismiss.

This build is locally ad-hoc signed, not Developer ID signed or notarized. On a transferred download, macOS may block the first launch. After trying to open it, use System Settings > Privacy & Security > Open Anyway for this app if you trust this build. A managed client Mac may require its administrator to allow it. Do not disable Gatekeeper globally.

## What the actions do

- Approve grants the Slack sender access to direct-message the bot. On current OpenClaw it does not notify the sender or make them the command owner.
- Dismiss removes that pending request. It does not permanently block the sender or revoke an existing approval. The sender may request access again.
- Older OpenClaw versions support listing and approval only. Dismiss is disabled on those versions. Legacy CLI approval may also establish the first command owner; the app warns before approving.
- Request data is fetched manually with Refresh (Command-R) and after every successful action. Failed actions clear the list so you refresh before retrying.
- Profile/account/executable settings are stored in macOS preferences. OpenClaw manages credentials. This app never asks for a Slack token and never edits OpenClaw's credential files.
- Target is the gateway resolved by the selected OpenClaw profile. Check the profile's gateway configuration before use, particularly if it points to a remote instance.

## Commands

Current gateway API, invoked using the installed CLI:

```sh
openclaw gateway call channels.pairing.list --params '{"channel":"slack"}' --json
openclaw gateway call channels.pairing.approve --params '{"channel":"slack","accountId":"ACCOUNT","requestId":"REQUEST","notify":false,"bootstrapCommandOwner":false}' --json
openclaw gateway call channels.pairing.dismiss --params '{"channel":"slack","accountId":"ACCOUNT","requestId":"REQUEST"}' --json
```

Legacy CLI:

```sh
openclaw pairing list slack --json
openclaw pairing approve slack CODE
```

There is no documented `pairing reject slack` command. Device rejection is a different access system and is not used here.

Sources checked September 16, 2026:
- https://docs.openclaw.ai/cli/pairing
- https://docs.openclaw.ai/start/pairing
- https://github.com/openclaw/openclaw/blob/main/packages/gateway-protocol/src/schema/channel-pairing.ts
- https://github.com/openclaw/openclaw/blob/main/src/gateway/server-methods/channel-pairing.ts

## Build and verification

Run `./build.sh` using the Xcode command-line tools. Run `./test.sh` for isolated CLI integration tests. Fixtures are test-only and are not packaged in the app.

Verified locally: universal binary compilation and code signature, command arguments, gateway list/approve/dismiss contracts, older-version fallback, failure handling, process timeout, and native window rendering. Live OpenClaw access changes remain unverified because OpenClaw is not installed on the build Mac. Client acceptance requires refreshing against the real installation and deliberately handling a real pending request.
