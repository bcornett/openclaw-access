# OpenClaw Access

## Done
- Native SwiftUI request list, details, account/profile/executable configuration.
- Gateway approve and dismiss; no requester notification or command-owner bootstrap.
- Compatibility fallback for older servers with CLI list/approve only.
- Universal Apple Silicon/Intel build, macOS 13+.
- Isolated integration tests for command handling, failures, and timeout.
- Visual verification of missing installation, request details, and settings sheet.
- Portable DMG with Applications shortcut and installation guide.
- Published v1.0.0 at https://github.com/bcornett/openclaw-access/releases/tag/v1.0.0; unauthenticated download verified against the local installer checksum.
- v1.1.0 Schedules view (PGT card "Frank access app: restore cron schedule management"): list of OpenClaw scheduled jobs with plain timing, next run, last result, paused state; busy-hours map of job starts per weekday and hour; change days and time, cron expression, time zone, or interval; pause and resume; confirmation before every change. Uses cron.list and cron.update only.
- Tests for schedule reading and wording, busy-hour counts, paging, exact update requests, and a rejected change.
- `./ui.sh` offscreen click-through of the views against the fixture (edit, confirm, save, resume, typed input, rejected change, missing install, dark, minimum size).
- `./package.sh` builds the installer DMG.
- Published v1.1.0 at https://github.com/bcornett/openclaw-access/releases/tag/v1.1.0 (PR 1, squash 0d2314f, merged and released by PGT PO on 2026-10-04).
- v1.2.0 Delete job (asked for by Brandon on 2026-10-05, reversing the "no delete" cut): Delete job button with a confirmation, using cron.remove; the heartbeat job stays locked. Tests and click-through cover it.
- v1.2.0 fix: an unsaved edit no longer comes back when a job is selected again; the editor reopens on the job's real timing after every selection and reload.

## In progress
- v1.2.0 pull request open on branch `claude/delete-scheduled-jobs`. PGT PO merges and cuts the release with the staged DMG.

## Next
- Client Mac acceptance against its installed OpenClaw: a real pending request, and one real scheduled job moved and its next run confirmed in OpenClaw.
- On Frank's Mac after install: read the real job list in Schedules and move the Monday 8 AM jobs by hand (for example toward 3 AM). The app changes nothing on its own.
- Developer ID signing/notarization if a signing identity becomes available.

No OpenClaw installation or Developer ID signing identity is available on the build Mac. Live request approval/dismissal, live schedule changes, and live job deletion are not yet verified. The OpenClaw version, job list, and gateway time zone on Frank's Mac have not been read. No production access or schedule was changed.
