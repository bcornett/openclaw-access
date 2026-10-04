# OpenClaw Access

A standalone native Mac app for reviewing pending Slack DM pairing requests in OpenClaw, and for seeing and changing when OpenClaw's scheduled jobs run. Supports macOS 13 or later on Apple Silicon and Intel. The app needs no Node, Python, or Xcode runtime of its own, but requires an existing, configured OpenClaw installation and running gateway under the same Mac user.

## Install

1. Open **OpenClaw Access.dmg** and drag **OpenClaw Access** into Applications.
2. Launch it on the Mac where OpenClaw is configured.
3. Click Refresh. If needed, open Connection settings and select the OpenClaw executable or enter its profile/account.
4. Select a request and choose Approve access or Dismiss.
5. Choose Schedules at the top to see scheduled jobs and change when they run.

This build is locally ad-hoc signed, not Developer ID signed or notarized. On a transferred download, macOS may block the first launch. After trying to open it, use System Settings > Privacy & Security > Open Anyway for this app if you trust this build. A managed client Mac may require its administrator to allow it. Do not disable Gatekeeper globally.

## What the actions do

- Approve grants the Slack sender access to direct-message the bot. On current OpenClaw it does not notify the sender or make them the command owner.
- Dismiss removes that pending request. It does not permanently block the sender or revoke an existing approval. The sender may request access again.
- Older OpenClaw versions support listing and approval only. Dismiss is disabled on those versions. Legacy CLI approval may also establish the first command owner; the app warns before approving.
- Request data is fetched manually with Refresh (Command-R) and after every successful action. Failed actions clear the list so you refresh before retrying.
- Profile/account/executable settings are stored in macOS preferences. OpenClaw manages credentials. This app never asks for a Slack token and never edits OpenClaw's credential files.
- Target is the gateway resolved by the selected OpenClaw profile. Check the profile's gateway configuration before use, particularly if it points to a remote instance.

## Schedules

The Schedules view lists every scheduled job in OpenClaw with its timing in plain words, its next run, its last result, and whether it is paused.

- Busy hours shows how many jobs start in each hour of the week. An hour with three or more starts is marked in orange. Click an hour to bring its jobs to the top of the list.
- Select a job to change it. Days and time sets the days of the week and one time of day. Advanced takes a cron expression for anything else. Jobs that run on an interval can have the interval changed.
- Before you save, the app shows the new timing in plain words and how many other jobs start in that hour, so a job can be moved to a quiet hour, for example from Monday 8:00 AM to Monday 3:00 AM.
- Every change asks for confirmation. Nothing is changed when the app opens or refreshes.
- Pause job stops a job from running until Resume job is chosen. It does not delete the job.
- Times are in the job's own time zone when it has one, otherwise the time zone of the Mac running the OpenClaw gateway. Busy hours are shown in this Mac's time zone.
- Busy hours count jobs that run at set times on days of the week. Jobs on an interval, on a day of the month, or on a schedule the app cannot read are listed but not counted, and the view says how many.
- The app does not create, delete, or run jobs, and does not edit what a job does or where it delivers. OpenClaw's own heartbeat job is shown but cannot be changed here.
- If OpenClaw rejects a change (for example a mistyped expression, or the job was edited somewhere else since the list was loaded), its message is shown and the list reloads. Nothing is saved in that case.

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

Scheduled jobs, same gateway API:

```sh
openclaw gateway call cron.list --params '{"includeDisabled":true}' --json
openclaw gateway call cron.update --params '{"id":"JOB","patch":{"schedule":{"kind":"cron","expr":"0 3 * * 1"}},"expectedConfigRevision":"REVISION"}' --json
openclaw gateway call cron.update --params '{"id":"JOB","patch":{"enabled":false}}' --json
```

A schedule change sends only the schedule. The job's time zone, stagger, and interval anchor go back unchanged unless edited. `expectedConfigRevision` is sent when the gateway reports one, so a job edited elsewhere is not overwritten. When the gateway pages the job list, the app follows `hasMore` and `nextOffset`. Changing a job needs the same OpenClaw operator permission as `openclaw cron edit`; there is no CLI fallback for schedules.

Pairing sources checked September 16, 2026:
- https://docs.openclaw.ai/cli/pairing
- https://docs.openclaw.ai/start/pairing
- https://github.com/openclaw/openclaw/blob/main/packages/gateway-protocol/src/schema/channel-pairing.ts
- https://github.com/openclaw/openclaw/blob/main/src/gateway/server-methods/channel-pairing.ts

Schedule sources checked October 4, 2026 (OpenClaw main at 2be4d4f):
- https://docs.openclaw.ai/cli/cron
- https://docs.openclaw.ai/automation/cron-jobs/schedules
- https://github.com/openclaw/openclaw/blob/main/packages/gateway-protocol/src/schema/cron.ts
- https://github.com/openclaw/openclaw/blob/main/src/gateway/server-methods/cron.ts
- https://github.com/openclaw/openclaw/blob/main/src/cron/stagger.ts

## Build and verification

Run `./build.sh` using the Xcode command-line tools. Run `./test.sh` for isolated CLI integration tests. Run `./ui.sh` to click through the views offscreen against the fixture; it writes a picture of each state to `build/ui` and shows nothing on screen. Run `./package.sh` to build the installer at `build/OpenClaw-Access.dmg`. Fixtures are test-only and are not packaged in the app.

Verified locally: universal binary compilation and code signature, command arguments, gateway list/approve/dismiss contracts, older-version fallback, failure handling, process timeout, and native window rendering. For schedules: reading and wording of schedules, busy-hour counts, job list paging, the exact schedule and pause requests, a rejected change, and a click-through of edit, confirm, save, and resume against the fixture.

Live OpenClaw changes remain unverified because OpenClaw is not installed on the build Mac. Client acceptance requires refreshing against the real installation, deliberately handling a real pending request, and deliberately moving one real scheduled job and confirming its next run in OpenClaw.
