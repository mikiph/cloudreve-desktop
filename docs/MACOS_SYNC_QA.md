# macOS setup and sync acceptance test

Use the production `.app` with its embedded extension, not `cargo run`. Build
189 is the test build for the onboarding/recovery changes. Quit the installed
Cloudreve normally and close documents before replacing it. Run only one copy
of Cloudreve. Keep the production bundle identifiers stable.

For a genuinely fresh first-use permission test, use a separate macOS user
account and a disposable Cloudreve account or remote folder. This exercises
macOS consent without deleting your normal drive, database, pins or downloads.
Removing a drive does not reset macOS's remembered permissions. Do not delete
`~/Library/CloudStorage`, extension containers or SQLite files for this test.

## Start-to-finish onboarding

1. Start the app in the fresh macOS account. Connect to the server in New Drive,
   approve browser authorization, and name the disposable drive Cloudreve.
2. Confirm that the account is saved, then Finder opens the new drive directly.
   If macOS shows Allow/Enable, approve it there. If a separate file-access
   prompt appears, confirm it includes Cloudreve's explanation and approve it.
3. Onboarding must remain in Connect Finder until native domain enablement,
   connection and directory access succeed, then advance automatically. It
   must not exchange the authorization code a second time during Finder retry.
4. Open the drive from the success page. Check a remote folder and open one
   small file. Create a disposable local file and verify it reaches the server.
5. Repeat with permission denied. Success must not appear. Use Open System
   Settings to enable the File Provider or restore Files and Folders access,
   then return to onboarding and verify automatic completion. No Full Disk
   Access, Accessibility or Automation request should appear.
6. Close onboarding while approval is pending. Settings → Set up Finder must
   resume setup with the saved account. If the extension cannot register, the
   account and useful native error must remain visible.

## Recovery and activity

1. Allow the initial metadata check to finish. Verify the compact footer says
   Checking for changes while it runs. Hover the bottom-right refresh icon for
   the last successful check time. Full-check counts appear only in the tooltip.
2. Leave a nested folder open in Finder. Quit Cloudreve normally, confirm Finder
   shows the disconnected reason, and change/create/delete disposable remote
   items through the website. Relaunch the app. Confirm recovery activity is
   visible and the open folder receives the changes without navigating away.
3. Repeat with Wi-Fi disabled, with a server interruption, and after sleep/wake.
   A silently dead SSE stream may take up to 90 seconds to be detected; native
   state is updated on the next supervisor pass. The popup must not claim all
   files are up to date while disconnected or retrying recovery.
4. Reconnect again during a paged change search. A further incremental pass
   must run and capture changes from the new gap.
5. Use Check for changes for the selected drive, then All drives. Confirm the
   check starts without resetting identities, downloads or Keep Downloaded.
6. Force Quit separately. It cannot execute graceful disconnect, so record its
   behavior separately from normal Quit. Test the documented timestamp-search
   and presented-folder recovery scope, plus explicit Full check for other gaps.

## Reset, collisions and upgrades

1. On the disposable drive, set Keep Downloaded on a test folder. Make an
   unsent edit while offline, then close its editor. Run Reset Finder Integration.
   Confirm the warning explains pin/download loss. If macOS preserves dirty
   files, Settings must report their recovery path; review these copies.
2. Verify a new domain can be enumerated, only one current location remains,
   and a fresh remote change appears. Keep Downloaded must be reapplied after
   this explicit reset. Reset must not upload old clean downloads as new files.
3. Remove the test drive, then add the same account/root and same name again.
   Repeat after an upgrade from the previous production app bundle.
4. With a retained older `.dev` location using the same name, add a production
   drive. A native file-exists error should use a stable identity suffix. The
   old location and its data must remain untouched. Other native errors must
   stay visible rather than being concealed by repeated rename attempts.
5. Test a removal/registration error (for example, disable the extension).
   The account must remain available for retry; do not mark reset successful
   when the replacement registration failed. Rapid duplicate reset/add/remove
   actions must not overlap native lifecycle operations.

## Displays and Spaces

Test a Retina MacBook with a non-Retina external monitor, then swap the primary
display. Place the external display left, right and above the laptop. Click the
menu icon on each display, including a different Space and a full-screen app.
The popup must appear below that display's menu bar without switching to its
previous Space. Check edge clamping, second-click dismissal and ordinary blur.

## Upload interruption limitation

Uploads are chunked, but neither the macOS extension nor the Rust uploader
currently guarantees reuse of a saved session after failure. Disconnect during
a disposable large upload and inspect the retry/activity error. Expect Finder
to retry the operation, potentially from the beginning. Do not report this as
successful resumable-upload validation.

## Automated checks

```sh
cargo check -p cloudreve-desktop
cargo test -p cloudreve-desktop --lib popup_position_tests
cargo test -p cloudreve-sync --lib fileprovider
bash macos/scripts/test-state-database.sh
bash macos/scripts/test-presented-refresh.sh
bash macos/scripts/test-downloaded-refresh.sh
FP_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)" bash macos/scripts/test-pin-requests.sh
FP_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)" bash macos/scripts/test-file-provider-activity.sh
FP_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)" bash macos/scripts/test-reset-request.sh
npm run build --prefix ui
```

These checks do not substitute for native consent, upgrade, multi-display and
remote-change tests above. Record the OS version, app/extension build numbers,
network transitions and relevant app logs for any failure.

## Browser fixture

Run `npm run dev --prefix ui` and open
`http://127.0.0.1:5173/qa/macos.html#/add-drive` in the in-app browser.
Use `https://cloudreve.example` as the site URL. The fixture mocks OAuth,
File Provider IPC and all server requests. Finish must stop at native approval
until the fixture's Approve native access checkbox is checked. It then finishes
automatically. The Activity link and state selector exercise recovery, offline,
retry and completed states. The fixture uses no real accounts or permissions
and is not part of the production entry point.

The DOM's `data-account-saves` and `data-token-exchanges` values should both stay
at one while repeatedly checking native approval. Test onboarding at 470×630
and the popup at 370×530, matching the native window dimensions.

## Incremental checks and clock format (build 188)

- With an existing inventory and no remote changes, use the footer refresh icon.
  Requests should be a server-clock ping, two paged timestamp searches, and a
  bounded Finder refresh. There must be no host recursive folder traversal.
- Close the app, create and modify files elsewhere, then reopen it. Verify the
  changed records appear. Include a new upload with an old modification time,
  a same-size content update and a rename. Inspect `fp-search-checkpoint` without
  exposing tokens. Both searches must finish before its time advances.
- Break networking partway through pagination, then restore it. The lower bound
  must remain unchanged until delivery succeeds. Test duplicate search results,
  a server depth limit and a repeated pagination token. No absent search result
  may produce a deletion. Last checked must retain the previous success on error.
- Delete a file in a recently presented folder while offline. Its bounded
  reconciliation should remove the stale entry. For a permanently deleted item
  outside the presented set, use Settings → drive → Full check. This is an API
  limitation of routine checking. Verify full check preserves downloaded files
  and Keep Downloaded policy, and does not remove/re-register the drive.
- Routine checks must not recursively traverse a pinned root. Native initial
  enumeration, explicit Full check and Keep Downloaded policy changes may still
  enumerate pinned descendants as required by File Provider.
- At the native popup size, verify refresh sits at the bottom right and its
  tooltip shows the previous successful check during retries. The tooltip must
  work on the disabled icon while checking. No separate progress panel appears.
- In General → Time, select 12-hour and 24-hour. Reopen the popup and check tooltip
  times. Select System default, then change the macOS clock override and reopen
  the popup. Confirm it follows macOS even if Cloudreve uses another language.
  Relaunch and verify the saved setting. The browser fixture simulates the native
  preference and does not prove macOS integration.

## Delayed offline-upload recovery (build 189)

The build 188 incident found new nested folders through the server search within
seconds, but replay waited more than two minutes behind repeated presented-folder
scans. A newly discovered file then waited for native content preparation before
its metadata batch could finish. The menu reported the server search as completed
while Finder was still waiting. This is a delivery regression, separate from the
known completeness limits of timestamp searches.

- Quit the app, upload a new folder containing files and a nested folder through
  another client, then launch the app with the parent already open in Finder.
  Include files with preserved old modification dates. Check app search logs,
  journal timestamps and native enumeration logs separately. New items must be
  returned without waiting for every remembered folder or a content download.
- Repeat refresh while a large presented folder has multiple pages and another
  folder request is delayed or fails. Refresh requests must coalesce, other
  folders must get turns, and live changes must continue through the working set.
- Terminate the extension between page results. The persisted folder cursor and
  results must resume together. A failed or partial listing cannot infer missing
  children. Test a live move/delete during pagination and reuse of its old name.
- Verify online-only new files stay online-only. Existing materialized files
  must receive content updates after metadata delivery. Local upload echoes must
  not be evicted by remote-refresh preparation.
- The footer must show Checking for changes… after a server check while its journal
  target or folder-refresh results remain unacknowledged. It may become idle
  after the extension returns the metadata to macOS. That is not a guarantee
  that every content download has finished. The tooltip retains the server
  check time while this delivery is pending.

The native reopen/upload test and two-device failure tests must be run against
the installed matching app and extension. Passing isolated queue tests or the
browser fixture does not demonstrate end-to-end Finder behavior.

### Build 190 moved-folder regression

- Move a populated folder on the server while the desktop app is closed. Preserve
  child timestamps. Open the app and confirm every child appears at the new path.
- Repeat while online and while a folder check is in flight. Old-path 404s must not
  remove the moved children or their Keep Downloaded selections.
- Upgrade from build 189 after reproducing the empty moved-folder bug. The retained
  move journal must repair the affected subtree without resetting Finder.
- Refresh again. Unchanged pages must not publish duplicate metadata updates.
- The footer says Checking for changes. The refresh tooltip shows checked items
  and remaining folders, and distinguishes retrying folders.
- `test-presented-refresh.sh` covers remapping, stale pages and tombstones, replay
  ordering, paged subtree discovery, persisted identities, and upgrade repair.

Native acceptance, 2026-10-19: installed signed build 190 over 189 after
preserving the prior app and state. The server's moved
`Cloudreve/Windows/test/battery` subtree had six PDFs plus `charging`, which
contained thirteen PDFs. Finder initially had only `.DS_Store` in `battery`.
The automatic retained-move repair queued at 23:42:09, published two metadata
pages that second, and both Finder directory listings matched the server after
repair. This verifies recovery of the reported existing failure. Other move
races are covered by regression tests, not a claim of exhaustive native testing.
The queue subsequently reached zero remaining folders with its journal target
acknowledged and no pending File Provider issues. A restored nested PDF was
opened successfully through File Provider and had a valid PDF header. The normal
recent-folder pass inspected 1,686 metadata entries across 129 pages, while only
the changed subtree produced new metadata delivery pages. This is not evidence
of constant-time checks on large drives.

### Build 191 scale and concurrent-refresh tests

Run `bash macos/scripts/test-recovery-stress.sh`. It compiles optimized production
Swift sources into an isolated test executable and uses temporary SQLite with
simulated API metadata. No real server files, credentials, native domains or user
state are involved. Generated API responses have no network latency. The script
accepts `FP_TEST_SOURCE_DIR` to compare the same fixtures with a captured source
snapshot. The numbers below are observed local runs, not completion estimates
for a real Cloudreve server.

| Workload | Before scale fixes | Build 191 |
| --- | ---: | ---: |
| Routine check, 3,000 folders and 60,000 cached files | 2.608 s | 0.685 s |
| Apply 100 new entries with 63,000 existing identities | 5.725 s | 0.204 s |
| 20,000-file folder (plus a small sibling in final run) | 3.934 s | 1.428 s |
| New subtree, 3,000 folders and 6,000 files | 17.201 s | 16.619 s |

The routine case visits exactly 129 directories, reads 143 pages and inspects
5,560 metadata entries. Replay uses 56 callbacks with at most 100 metadata entries
per callback. The newly discovered subtree needs 3,015 pages and delivers 9,000
entries. The small sibling of the 20,000-file directory is delivered in the third
journal result, before the large directory finishes.

The pre-fix unrelated-event reproduction made 405 valid listing requests without
committing one page in three seconds. The fixed worker finishes the same check
in one request (0.024 s in that local run).

Regression coverage includes additions during pagination, insertion before an
already requested page, overlapping results, independently confirmed deletion,
failed-write rollback, repeated tokens, extension restart from committed cursors,
initial shallow baselines, later introduced old-timestamp subtrees, offline
stable-ID moves, fair scheduling, and completed-folder counts of 129/129, 2/2,
and 3,001/3,001. These deterministic workloads supplement native acceptance and
do not establish correctness under every server mutation or network failure.

`node --test ui/qa/recovery-progress.test.ts` checks selected-phase aggregation,
stale completed drives, large counts and a growing discovered total. The in-app
browser also verifies the counter at the native 370 by 530 popup size.

Additional build 191 edge coverage (`--edges-only`) verifies promotion of an
already paged shallow job restarts the first page, relevant in-flight edits reject
the old content entity, and final queue-save failure rolls back baseline,
membership, locations, fingerprints, journal records and membership pruning.

Native build 191 acceptance: app and extension version/signature verified after
installation. The normal queue reported 53/129 and then 115/129 completed
folders, with zero pending native issues. The earlier battery test subtree had
subsequently moved on the server; its stable identities resolved to the new
location and Finder still contained its seven immediate entries and thirteen
entries in charging. This check follows stable identities rather than assuming
the original test path remains current.

### Build 192 native suspension regression

During native build 191 acceptance, macOS invalidated the extension after 115 of
129 checks, leaving fourteen durable jobs with no active extension process.
Unchanged pages had no new journal results to trigger another wake. This exposed
an OS lifecycle case that isolated queue tests do not emulate.

Build 192 adds app-owned, throttled working-set wake requests while durable work
is pending. Test the following without opening a Finder window or producing
server events: start a check, allow macOS to invalidate the extension between
pages, and confirm saved progress resumes and reaches its total. The helper's
isolated Rust tests verify partial queue detection, result acknowledgement,
per-drive wake throttling, corrupt records, and absence of journal/checkpoint
mutations. Wakes must stop once the queue and native delivery target finish.
The pending-work helper passed all eleven recovery-status tests, including
acknowledged markers with unfinished folders, per-drive monotonic throttling,
undelivered results, corrupt records and quiet completion. The supervisor calls
it before its ordinary connected-state early return, so an unchanged connection
cannot suppress the wake-up path.
Native build 192 completed the previously stranded marker, then its startup
check reached 129/129 folders, zero remaining, 1,686 inspected entries, and a
matching native metadata acknowledgement. App-owned wakes occurred without
additional search passes beyond the normal startup/subscription searches and
ceased once the durable work finished. Build 192 app/extension versions and
strict deep signatures were verified after installation.
