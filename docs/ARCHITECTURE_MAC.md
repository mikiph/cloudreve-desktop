# macOS architecture

Cloudreve Desktop uses Apple's File Provider framework on macOS. Finder owns the
visible file hierarchy and local placeholder database; the Cloudreve desktop app
and its embedded File Provider extension cooperate to supply metadata, content,
and changes. This is intentionally different from the Windows implementation,
which maintains the sync root through the Cloud Files API.

## Components

### Desktop app

The Tauri app owns long-lived work:

- drive configuration, authentication, and token refresh;
- the Cloudreve server-sent events (SSE) connection;
- the durable SQLite inventory used for missed-event recovery;
- the transactional SQLite change journal shared with the extension;
- File Provider domain registration and enumerator signalling;
- menu-bar UI, activity history, sharing, and conflict windows.

The relevant Rust code is primarily in:

- `crates/cloudreve-sync/src/drive/remote_events.rs`
- `crates/cloudreve-sync/src/drive/fileprovider_audit.rs`
- `crates/cloudreve-sync/src/fileprovider.rs`
- `crates/cloudreve-sync/src/inventory.rs`

### File Provider extension

`CloudreveFileProvider.appex` is an ExtensionKit process launched and suspended
by macOS. It must not host a permanent event listener. It handles native Finder
operations instead:

- enumerating folders and the working set;
- resolving stable item identifiers to Cloudreve URIs;
- returning placeholders and metadata;
- downloading content on demand;
- uploading Finder changes;
- renames, moves, deletes, pinning, and conflict recovery;
- replaying the change feed produced by the desktop app.

Its Swift implementation lives in `macos/fileprovider/Sources/`.

### Cloudreve server

The server remains authoritative for the remote hierarchy. SSE provides fast
notification, while ordinary list and file-info APIs provide authoritative
metadata and content. SSE is not treated as a durable replay log.

## Remote-to-Finder synchronization

The normal change path is:

1. The desktop app maintains an SSE subscription for every mounted drive.
2. A create, modify, rename, or delete event is validated and committed to
   `~/.cloudreve/fileprovider.db` before the app signals Finder. Upload receipts
   are acknowledged in that same transaction, preserving local-upload echo
   handling if a write fails.
3. The app calls `NSFileProviderManager.signalEnumerator` for the domain's
   working-set container.
4. macOS launches or wakes the extension and calls `enumerateChanges`.
5. The extension reads events after Finder's sync anchor, resolves current
   metadata through Cloudreve, and reports updates or deletions to Finder.
6. Replay reads at most 32 journal records at a time and budgets their contained
   metadata updates. `moreComing` asks macOS for the next page. A reset-marker
   index finds expired anchors without decoding the entire retained backlog.

The working-set feed is domain-wide. A change is not discarded merely because
its folder has not recently appeared in Finder. This is essential for newly
created nested folder chains. Delivering metadata does not download file
contents: files remain native on-demand placeholders until macOS requests them.

When Finder opens a folder, its ordinary enumerator lists that folder directly
from Cloudreve. Consequently, the first visit always uses current server state
even if no historical event was retained.

## Missed-event recovery

SSE connections can be interrupted while the app is stopped, the network is
unavailable, or the server requests a reconnect. Cloudreve therefore does not
assume that reconnecting SSE reveals the missing interval.

Starting with build 188, startup, confirmed subscriptions and the menu refresh
button perform incremental server searches instead of walking the remote tree.
The existing SSE connection continues to deliver live changes.

1. A `refresh_presented` journal event durably queues the root and the bounded,
   recently presented folder set. Starting with build 189, this network work
   runs outside change replay, in round-robin pages. Repeated requests coalesce.
   Page results and queue progress commit together in SQLite. Missing children
   are considered only after that folder's complete listing. This does not
   recursively walk pinned trees or delay discovered changes behind every folder.
   Missing candidates are separate indexed rows and are verified in small batches
   before deletion. The queue does not rewrite a whole folder's identity map for
   every page. Metadata fingerprints suppress unchanged results.
2. The host reads the server Date header and queries the configured root with
   `updated_gte` and `created_gte` in separate paged searches. The creation query
   also catches newly uploaded files with preserved older modification times.
3. Only the returned IDs are looked up in the indexed SQLite inventory. Stable
   ID, URI, modification time, size, type and primary entity identify changes.
   Inventory and outgoing events commit together through the existing outbox.
4. The server-time checkpoint in `fp-search-checkpoint` advances only after both
   searches and durable deliveries succeed. A two-minute overlap reduces time
   boundary gaps, but pagination is not a consistent server snapshot. Failed or truncated searches retain
   the checkpoint and report a retry. Search absence never means deletion.
5. On migration, the oldest existing inventory observation establishes the
   starting interval, translated to the server clock. New drives start at the
   current interval and get existing items through normal Finder enumeration.
   No initial whole-drive inventory walk is required.

The server check and native delivery have separate completion states. A completed
check records its journal target. The extension records `fp-applied` after
returning working-set changes to macOS. The menu shows **Checking for changes…** until
that target and any pending `fp-folder-refresh` results have been delivered.
The tooltip's last-check timestamp describes the server check. It does not prove
all content has downloaded or every uncached directory has been verified.

Metadata replay never waits for native content eviction or materialization.
Those operations can themselves depend on Finder consuming the metadata.
Materialized-content refresh runs after enumeration finishes, skips local upload
echoes, and checks local materialization before requesting content. Working-set
signals do not wait behind the native download gate. Only working-set signals
are supported by replicated File Provider extensions, so signalling individual
folder enumerators is not used as a recovery mechanism.

This is best-effort recovery within the current server API. Neither timestamp
search nor a local hash is a complete remote change log. Permanent deletions,
items moved out of the configured root, old descendants moved into a subtree,
and edits with backdated timestamps may not be returned. Live SSE covers these
when delivered while connected. Presented-folder reconciliation covers recently used locations.
The remaining offline gaps require the explicit **Full check** in drive Settings.
Do not claim that normal check completion proves the entire drive is identical.
Search work may still be substantial after a long absence or many real changes,
and the server may impose search-depth limits. It does not silently fall back
to recursive traversal when a search is unsupported or truncated.

Full check performs the previous metadata-only traversal in pages of 200. It
preserves downloads, pins and domain identity. A complete pass alone infers
missing inventory items as deletions, collapsing descendants of missing folders.
It refreshes Finder's working set and updates the incremental checkpoint after
success. An empty inventory establishes a baseline without creating activity
for every existing file. Received-share redirects are not recursively traversed.
Full check is never scheduled automatically by startup, reconnect or menu refresh.

API references: [List files](https://cloudrevev4.apifox.cn/list-files-300233178e0),
[URI search conditions](https://docs.cloudreve.org/en/api/file-uri),
[Events stream](https://cloudrevev4.apifox.cn/events-stream-413501323e0).
The Pro [file activity API](https://cloudrevev4.apifox.cn/list-file-activities-300250878e0)
is not documented as a durable drive-wide sync cursor.

Long-term recovery needs fair background verification of cached and pinned
directories beyond the presented-folder limit. Timestamp searches are an
accelerator, not a complete change journal. The upstream search implementation
also traverses folder levels on the server, so its cost is not necessarily
proportional to the number of returned changes. Local hashes cannot detect
changes in remote metadata that has not been fetched. Build 189 addresses the
observed delivery stall, and does not claim to finish this broader recovery work.

## Folder moves and targeted recovery (build 190)

A folder move now remaps every known descendant URI while retaining stable item
identifiers and pin selections. Identity snapshot writes are serialized using a
fresh snapshot, so concurrent callbacks cannot overwrite a newer mapping.
Requests already running against the previous path cannot evict moved items.
Presented-folder checks wait for pending move events, restart queued pages whose
container moved, and reject results captured at a stale location.

New and moved directories receive a durable paged subtree check. This discovers
children whose creation and modification dates did not change when their parent
moved. Unrelated trees are not traversed. Ordinary metadata changes to an already
known directory do not schedule recursive discovery. Shared redirects are excluded.
Each page publishes metadata promptly and persists newly discovered child folders
in the same transaction. Checks that produce no new journal records no longer
signal an empty working-set replay.

A one-time `fp-move-repair-v190` cursor revisits retained, previously acknowledged
move destinations. It queues affected directories, so upgrades can recover
children incorrectly removed by older builds without resetting the domain. It
cannot reconstruct moves that have already fallen outside journal retention.

The footer uses **Checking for changes…** throughout. Its refresh tooltip reports
items checked, folders remaining, and how many folders are retrying. Remaining
folder counts can grow as a new subtree is discovered. They are not percentages
or estimates of content transfer progress.

Cloudreve exposes file/upload ETags, but its public WebDAV implementation excludes
`getetag` for directories. It therefore does not provide Nextcloud's folder-ETag
contract for skipping unchanged subtrees. A local metadata fingerprint suppresses
unchanged deliveries after listing, but cannot prove that an unfetched remote
folder is unchanged. See [Cloudreve WebDAV properties](https://github.com/cloudreve/Cloudreve/blob/master/pkg/webdav/prop.go)
and [Nextcloud discovery](https://github.com/nextcloud/desktop/blob/master/src/libsync/discovery.cpp).

## Refresh scale and concurrent changes (build 191)

A routine check remains bounded to the drive root and at most 128 recently
presented directories, plus targeted newly introduced or moved subtrees. Having
3,000 existing directories does not by itself schedule 3,000 directory checks.
A new subtree with 3,000 directories does require listing those affected
directories to discover their contents. The server's timestamp-search work and
network latency are additional costs.

Page commits now examine only relevant journal changes. Unrelated live traffic
cannot repeatedly invalidate a stable directory listing. Membership changes in
the checked directory restart its pagination, including changes arriving between
pages. Metadata changes to returned items invalidate an in-flight stale result.
The validation watermark advances after each committed page, avoiding repeated
decoding of the whole earlier result backlog. Retention gaps, reset markers and
pending moves remain conservative barriers. A directory under continuous local
membership changes may require a quiet interval to complete its check, while
other directories and live event delivery continue.

Completed directory listings persist per-parent membership and stable directory
locations in SQLite. This lets a shallow listing identify an offline move or a
new child directory and queue its old-timestamp descendants. The first baseline
stays shallow. Membership, continuation, result journal and discovery jobs share
the page transaction. Promoting an existing shallow request to recursive starts
again at its first page so earlier nested directories are included.

The extension maintains an immediate-parent index for cached identities, avoiding
an entire identity-map scan for each candidate set. Metadata replay and direct
folder enumeration persist identities once per page, rather than once per item.
Those snapshots still contain the full identity map. Long-term migration of
private identity state to indexed rows would further reduce very large initial
replay costs.

The footer displays checked server items while the search runs, then completed
folders out of the current check's discovered total, for example **37/129
folders**. Totals can grow with discovery. Completed drives do not contribute
stale counters to an active drive's progress. This is a work count, not an ETA or
a claim that every directory in the drive has been audited.

See MACOS_SYNC_QA.md for measured isolated stress workloads and the remaining
recovery limits above. The hybrid of live events, timestamp searches and bounded
reconciliation is appropriate for the current API, but does not provide a durable
server change-log guarantee or eliminate the need for explicit Full check in
cold offline edge cases.

## Resuming checks after extension suspension (build 192)

macOS can invalidate the extension while its independent refresh worker still has
queued folders. Preserving the queue is insufficient unless something requests
another native enumeration. The desktop app's existing three-second connection
supervisor now checks durable work while a drive is connected. It signals only
the working set, at most once per five seconds per drive, until the folder queue
and its delivery target are complete. Quiet drives stop receiving these wakes.
No additional recovery marker, server search or folder pass is created by a wake.
This makes saved progress eligible to resume after extension suspension even
when no server change or Finder interaction occurs.

## Finder-to-remote synchronization

Finder invokes the extension for local creates, modifications, moves, renames,
and deletes. The extension performs the corresponding Cloudreve operation and
returns the authoritative item metadata and stable identity. Local upload echoes
are marked in the shared change feed so the extension can avoid treating its own
operation as an unrelated remote content replacement.

Keep Downloaded state is persisted by stable item identifier. macOS remains in
charge of eviction and materialization; Cloudreve supplies content when Finder
requests it and schedules refreshes for remotely modified materialized files.

## Identity and anchors

- A File Provider domain is registered per Cloudreve drive.
- Items prefer a stable identifier derived from the Cloudreve remote ID.
- The extension persists identifier-to-URI mappings so renames preserve Finder
  identity.
- Change anchors retain the compatible `evt-<number>` encoding. The database
  allocates increasing sequence numbers per drive, at least as large as the
  current millisecond timestamp. Legacy event timestamps are imported unchanged.
- The journal retains the latest 100,000 events per drive. Pruning and its
  minimum valid anchor are committed together. An older or future anchor
  explicitly expires; unread database errors fail enumeration instead of
  advancing an anchor. Event records and the journal head are read in one
  consistent snapshot.
- Rescan markers intentionally expire anchors when continuity is uncertain.

The recently presented-folder cache bounds routine reconciliation. Live events
and server searches are domain-wide. Offline deletions outside that bounded
set are an acknowledged API limitation and can require explicit Full check.

## Shares

Share metadata is refreshed independently from file content. The app polls share
state because current Cloudreve SSE events do not fully describe every share
addition or removal. Metadata events update Finder decorations and descriptions
without forcing content downloads. Received-share redirects are preserved as
native File Provider items and excluded from recursive recovery traversal.

## Failure behavior

- SSE uses a fresh client ID on each macOS subscription attempt and reconnects
  with bounded exponential backoff.
- An idle event stream is treated as disconnected and re-established.
- A failed recovery audit never infers deletions from a partial traversal.
  Already processed pages remain durable with their outgoing events. Audits
  retry automatically with backoff, including while SSE remains connected.
- Failed live-event journal writes retry the received batch with backoff.
- Large change sets are paged through `enumerateChanges`.
- Reset Finder Integration is a last-resort maintenance action. Normal upgrades,
  reconnects, and missed events must recover without deleting the domain.

## Persistent state and migration

`meta.db` belongs to the Rust inventory layer. `fileprovider.db` is the smaller,
versioned contract shared by the host and extension. It uses SQLite WAL mode,
FULL synchronous durability, a five-second busy timeout, and short transactions.
There is no network work inside a shared-database transaction. The canonical
schema is `macos/fileprovider/state-schema.sql`; the standalone Swift build
embeds an equivalent schema, with cross-language schema parity tests.

The shared database contains:

- `fp_event_heads` and `fp_events`: per-drive sequence, retention floor, and
  ordered event payloads;
- `fp_deliveries`: deduplication tokens for inventory outbox batches;
- `fp_records`: namespaced records for activity, pending errors, upload
  receipts, retry/pin requests, conflict metadata/actions, share baselines,
  and explicit reset requests;
- `fp_imports`: completed legacy-directory imports.

Build 189 also uses `fp-applied`, `fp-folder-refresh` and per-request candidate
namespaces for durable paged refresh and native delivery status. The additive
`idx_fp_events_rescan` index is installed for both new and existing version-1
databases by either process.

Snapshots and small request payloads retain their existing JSON encoding inside
database rows; they no longer require one file per record. Conflict read/modify/
write operations and activity updates use cross-process transactions. Pending
errors remain a snapshot of macOS-owned pending items, not a replacement queue.
Finder still owns materialization and transfer scheduling.

Legacy directories are imported once within transactions. Starting in 0.2.1 the
host removes recognized legacy metadata files after the import commits; import
markers prevent consumed requests from being re-imported. Failed imports retain
their sources and retry on a later launch. They are not active mirrors and must
not be copied over the database.
Do not run old and new app builds simultaneously during migration. A rollback
to the old file-based build cannot see new database-only requests.

Destructive reset commands are an exception: new explicit requests use
`fp-reset-requests-v2`. Historical `fp-reset` files/rows are never executed.
Build 181 incorrectly replayed those commands during import. Build 183 performs
a one-time repair for affected domains using macOS's materialized-item enumerator:
it restores identity paths from the native parent/name hierarchy, attempts to
recover pins from retained metadata, then requeues metadata received after the
accidental reset. If custom userInfo is absent but contentPolicy or the extension's
persisted `#kd` metadata marker is exposed, it restores the topmost Keep Downloaded
policy roots without promoting every inherited child to a separate pin.
On the affected macOS 27 installation, the native enumerator omitted all pin-policy
fields: identity recovery succeeded, but pins required a targeted restoration
from Finder's diagnostic `cp:keepDownloaded` state. Automatic pin recovery is
therefore best-effort, not guaranteed. Never infer pins merely from downloaded
contents. Missing parent identities are also resolved through authoritative
server metadata and published top-down before child updates in normal change
replay. This prevents new nested items from waiting indefinitely for a parent
whose guessed URI identifier differs from Finder's stable remote identifier.

The extension's private identity/pin/policy snapshots remain in its own container
in this migration; preserving them avoids changing Finder identity or resetting
the domain. Logs, icons, backups, content, and drive configuration remain files.
Unknown files, symlinks, nonempty unknown directories and manual backups are not
deleted automatically. Cleanup never recursively deletes a directory.

### Cleaning up a migrated installation

The host runs `StateDb::migrate_and_cleanup` before loading drives. It imports
record namespaces, including historical reset markers as inert recovery data,
then removes recognized source files. Inactive drives' UUID-named event logs are
also imported before removal. Historical `fp-health` records are archived in
the database but never executed. Live databases, configuration, logs, icons and
the extension's private state are outside the cleanup allowlist. Older and newer
builds must not run simultaneously.

For manual cleanup of pre-0.2.1 builds, after confirming the installed host and
extension use the database-backed build,
check `PRAGMA quick_check`, completed namespaces in `fp_imports`, and the active
drive's `fp_event_heads.imported` flag. Legacy directories can then be moved to a
dated backup outside `~/.cloudreve`; preserve unimported historical drives there
rather than treating them as current events. An empty legacy request directory
has no payload to migrate. Do not delete database import markers or re-submit
archived reset/pin requests.

The expected active directory contains:

- `drives.json`: drive configuration;
- `meta.db`: host inventory and recovery outbox;
- `fileprovider.db`: shared journal and operational records;
- `icos/` and `logs/`: icons and diagnostic logs.

SQLite may also create `-wal`, `-shm`, or journal sidecars. These are active
database files, not cleanup candidates. Never move them independently of their
database. The extension's private container and Finder's domain are not part of
this cleanup; keep their identity, pin, and policy state intact.

Legacy archive candidates are `fileprovider-activity`,
`fileprovider-download-retries`, `fileprovider-pending`,
`fileprovider-upload-receipts`, `fp-events`, `fp-health`, `fp-reset`,
`fp-share-state`, `pin-requests`, and `upload-conflicts`, plus existing manual
backups. Archiving is reversible, but restoring these files alone does not roll
back the database migration. Do not launch an older build against this cleaned
installation as a verification step.

Verify database integrity and retained Finder entries after cleanup. A fresh
remote change appearing in Finder is the end-to-end sync check; merely removing
legacy folders or seeing an existing placeholder does not prove event delivery.

Current development signing uses temporary sandbox exceptions for the shared
database and its WAL/SHM/journal sidecars, plus legacy paths needed for import.
A distributed build should move shared storage to an entitled App Group using
a configured signing team. This migration does not change the signing identity
or pretend that an App Group is available to the current ad-hoc build.

Validation includes:

```bash
bash macos/scripts/test-all.sh
cargo test -p cloudreve-sync --lib fileprovider
```

These tests use isolated temporary databases and cover migration, transaction
rollback, concurrent writers, receipt acknowledgement, outbox deduplication,
Rust/Swift interoperability, retention floors, and Finder's 100-event pages.

## Packaging and verification

The extension must be embedded in the production Tauri `.app`, and the app and
extension must share an incremented `CFBundleVersion`:

```bash
cargo tauri build --bundles app
FP_CONFIGURATION=Release FP_BUILD_NUMBER=<number> \
  ./macos/scripts/embed-into-app.sh \
  target/release/bundle/macos/Cloudreve.app
codesign --verify --deep --strict \
  target/release/bundle/macos/Cloudreve.app
```

Do not package a raw `cargo build --release` binary as the app: it lacks Tauri's
production custom-protocol configuration and attempts to load the development
server. For local handoff, provide the `.app` bundle directly rather than a ZIP.
When transferring to another Mac through Cloudreve, provide a DMG containing the
finished app rather than synchronizing the raw `.app` directory. The current
provider's `fileSystemFlags` exposes readable/writable permissions and does not
preserve executable bits or extended attributes. A raw app bundle can therefore
arrive without executable permissions. A disk image preserves the internal
filesystem metadata. Verify the image checksum, both executable permissions and
the app's deep signature after mounting it read-only. This does not add Developer
ID signing/notarization or bypass Gatekeeper.

Public releases use a DMG for installation and a separately signed `.app.tar.gz`
for the updater; both contain the same final embedded bundle. See
[`RELEASING.md`](RELEASING.md) for the required packaging and publication order.

## Production identity and updates (0.2.1)

The app uses `cloudreve.desktop` and the extension uses
`cloudreve.desktop.fileprovider`. Users upgrading from `.dev` builds must
reconnect and reapply Keep Downloaded selections; see
[`releases/0.2.1.md`](releases/0.2.1.md). This transition does not delete the old
extension container or Finder content. The old login preference is migrated to
the new LaunchAgent filename when the recognized legacy entry exists.

Settings → About checks this fork's GitHub `latest.json` over HTTPS. The host
retains the checked update and verifies its package with the pinned public key
before installation. It accepts initial download URLs only under this repository's
GitHub release path. An operation lock prevents overlapping checks/installs. The
user explicitly approves installation and is asked to save and close documents;
after installation the host shuts down its sync service and restarts. Windows
retains its existing package-managed update mechanism and Explorer integration.

Updater signatures are not Apple code-signing certificates. Current ad-hoc
releases are not notarized and cannot promise that security warnings appear only
once. No Gatekeeper or quarantine bypass is implemented.

## Connection state, setup and recovery activity (build 187)

The host reconciles native connection state against the confirmed event-stream
subscription and credential status every three seconds, retrying native errors.
It reasserts state every thirty seconds to recover after wake. A successful
registration is not a successful server connection. Settings reads the native
`isDisconnected` and `userEnabled` flags rather than treating an accepted
`signalEnumerator` request as a health check. The SSE idle timeout remains 90
seconds, so detecting a silently broken connection is bounded by that timeout,
not by the three-second native-state polling interval. Force termination cannot
run a graceful disconnect; do not claim that crash/force-quit is equivalent to
normal Quit.

Host domain operations share a lifecycle lock. Reset writes its explicit
identity/pin-reset request only after removal succeeds and the registration is
absent. Removal preserves dirty user data, and reset returns the recovered-file
location to Settings. Registration, removal and reset invalidate the host's
cached Finder root path. A native Cocoa file-exists error during registration
gets one safe retry using the configured name plus a stable eight-character
identity suffix. No other error is treated as a naming conflict, and no
CloudStorage folders or older app identities are deleted to free a name.

Onboarding persists the account first, then registers and opens its actual
Finder directory. It stays open while native approval is pending, checks
`userEnabled` and `isDisconnected`, and attempts a read-only directory listing
before reporting success. This can trigger macOS's File Provider domain access
prompt; `NSFileProviderDomainUsageDescription` explains the access. A denied
permission remains a retryable setup state, with a System Settings action.
macOS owns the Allow/Enable UI; there is no app-side auto-approval. Full Disk
Access, Accessibility and Automation permissions are not requested for this
flow. Notifications and launch-at-login preferences are separate from required
Finder setup. See Apple's [File Provider access description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfileproviderdomainusagedescription).

Recovery begins on app startup independently of SSE, and also follows confirmed
subscriptions. A reconnect during an active check queues another pass. Native
connection-state retries do not schedule duplicate recovery work. The `fp-recovery`
record stores the latest phase, counts, retry error and a separate last successful
completion time. Failed attempts do not replace the successful-check timestamp.
The footer has one small refresh icon. Its tooltip shows each selected drive's
last check, with full-check progress or retry details when applicable. There is
no separate progress panel or full-width refresh button. Completion means server
metadata was checked and delivered to the journal, while macOS schedules the
remaining enumeration and content work.

Settings offers System default, 12-hour and 24-hour clock formats. The optional
`clock_hour12` preference defaults to null for existing and new configurations.
On macOS, the effective system format comes from Foundation's localized `j`
template so a user's clock override is respected independently of app language.
Preferences update existing popup windows through an event and are reread on focus.

The menu popup is positioned while hidden, using AppKit global logical points
for both cursor and screen frames. It is then ordered on the clicked display
with all-Spaces/full-screen auxiliary behavior. No primary-display scaling is
applied to a secondary monitor.

The macOS extension chunks local/relay uploads and attempts to cancel the session
on an error. Build 193 records its own session IDs and URIs in SQLite before
uploading chunks. A local deletion cancels matching owned sessions in that
subtree only after verifying the server still reports the same session ID.
Failed cancellations remain recorded for a later deletion retry. Editor locks
and other clients’ upload sessions are never force-unlocked. The Rust uploader retries chunks but also
discards an existing saved session when restarting an upload. Neither path
currently guarantees durable byte-offset resume after interruption. SQLite
storage alone does not provide that guarantee.

For native acceptance testing, use [MACOS_SYNC_QA.md](MACOS_SYNC_QA.md).

## Pending deletions (build 193)

Native `uploadingError` covers failed outgoing metadata mutations as well as
content uploads. Before sending a deletion, the extension persists its delete
intent by drive and item identity. Pending-item snapshots and the activity UI
then report `delete`, and Retry deletion clears the native error so macOS can
retry the original operation. It must never call `requestModificationOfFields`
for content, which would request an upload of an item the user removed.
A pending delete blocks creates and content modifications in its subtree.
Ancestor delete generations also protect uploads already in flight. Success or
an already absent server item clears the intent. No domain reset is involved.

The public metadata API validates a fixed set of metadata categories and rejects
arbitrary desktop permission keys on the tested server. Do not claim that raw
app bundles preserve executable permissions or use unrelated metadata fields to
hide those permissions. Transfer installation bundles inside DMG or ZIP files.
`test-mutation-recovery.sh` covers retained sessions after failed cancellation,
drive and subtree isolation, pending delete intent, ancestor deletion races and
accurate upload-lock error messages.

## Package failures and retry history (build 194)

File Provider can hand a package directory to createItem/modifyItem as one content
item. The byte uploader rejects directory content before any network request or
upload session. It returns CannotSynchronize with ZIP instructions, so macOS
pauses the unsupported operation rather than retrying permission/timeout errors
indefinitely. This does not delete, exclude, or acknowledge the local package as
successfully uploaded. Ordinary folders still use the folder creation path.
Local modifications and extension/OS updates may cause macOS to attempt it again,
in which case the same source validation applies.

The Recent list groups native transfer attempts by drive, path and direction
across time gaps and interleaved activity. The newest outcome leads the single
row, and earlier attempts remain in expandable history. Failed rows include their
age so historical errors are not mistaken for active transfers. Transient network
errors for regular files remain retryable. No errors are silently discarded.

## Event verification, delete identity and replay speed

Measured against a Cloudreve 4.19.1-pro server: a 1,000-file upload from another
client reached the host as one SSE message with no loss, but the host then
verified each create/modify path with a serial `/file/info` call (about 25 ms each)
before Finder was signalled, and the extension replayed them serially again. Both
now use bounded concurrency (8 in flight, results applied in order). The extension
prefetches a replay page's metadata in waves of 8 unstructured `Task`s
(`FileInfoPrefetch`). Do not change this to a `withTaskGroup` whose child result is
`(String, Result<RemoteFile, Error>)`: with this toolchain's optimized build that
crashed the extension with a pure-virtual call in task completion (reproduced by
`test-file-info-prefetch.sh`, which must run optimized). After the fix a
1,000-file burst took about 5 s to reach Finder's journal (was 26 s) and about 35 s
to replay (was about 55 s); replay is now bounded by the 32-record page size.

- **Verification outcome.** A missing path (Cloudreve answers HTTP 200 with code
  40016) is the trash-restore quirk and still records a rescan marker. A failed
  lookup (offline, 5xx, rate limit) is retried three times, then the event is
  journalled as received and a bounded presented-folder refresh is requested. It no
  longer expires every sync anchor.
- **Journal `file_id`.** Journal records carry the server's stable file ID (same
  value as `/file/info` `id`, checked on 1,000 events). A replayed delete removes
  the deleted file's own identity; if a newer file now holds the same path it is
  left alone. Records written by older builds have no ID and keep path matching.
- **Not changed.** The identity map is still persisted as one JSON file. Measured
  cost is 6 ms at 5,000 identities and about 107 ms at 100,000; move it to SQLite
  rows only if drives of that size appear.
- **Open-source servers.** Community-edition source sends one SSE message per file
  into a 16-slot buffer and drops on overflow. That was not reproducible on the Pro
  server and is untested here. A periodic incremental search while connected would
  be the mitigation if community servers must be supported.

