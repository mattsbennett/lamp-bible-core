# Sync controller harness plan

Planned by Fable on 2026-11-28, against Mac `4991fca`. The owner asked for
a fake WebDAV harness so the Mac's `LibrarySyncController` can be tested
through a whole pass: the offloads after it, and the Move. The coordinator
checked the load-bearing claims against the code the same day (Mac
`cf2d198`).

## What is not tested today

Two paths need a server and a password, and both build their own:

- **The live offload check.** `sync` → `passAndItsAftermath` →
  `carryOutOffloads` → `offloadRequestedSources` / `offloadInactiveSources`.
  Each read-back goes through `withConnection`, and between read-backs the
  `while:` closure asks `isStillTheLook` again.
- **The Move.** `move(library:)` builds its own store, then
  `archiveToMove`, `LampSyncLibraryMigration.migrate`, `runBundlePass`, and
  a follow-up pass when offloads are waiting.

The store is built as `LampWebDAVClient(baseURL:credentials:)` in three
places (`withConnection`, `runSyncPass`, `move`). The password comes from
`SyncSecretStore`, in eleven places, and that store is the owner's real
keychain item. One of the eleven, `forgetSyncDetails`, deletes it.

## Design

Two seams on the controller's init, a fake in the test target, and one
serialized suite. No new source file, so the Xcode project,
`Verification/coverage.json` and the Lean model are unchanged.

### The seams

- **`SyncPasswords`** — `read` (throws when unreadable), `peek` (nil when
  none or unreadable) and `set`, with `.keychain` built from
  `SyncSecretStore`. The init takes `passwords:` **with no default**. The
  app passes `.keychain`, so a test that forgets the fake does not compile
  instead of reaching the keychain. Every instance site goes through it.
  The one exception is the `nonisolated static webDAVPasswordIsStored`,
  which no test may call.
- **`makeWebDAVStore: (URL, LampWebDAVCredentials?) -> any LampSyncRemoteStore`**,
  defaulting to `LampWebDAVClient.init`, at the three constructions.
- **`After.chosen(in: defaults)`** in the sweep. This is the same in the
  app, where `defaults` is `.standard`.

### The fake

`FakeWebDAVServer`, in `Tests/LampBibleMacTests`:

- **What it holds:** each path's bytes with a strong quoted ETag.
- **How it answers:**
  - Conditional writes behave like the real client's, and a refusal
    throws `remoteChanged`.
  - A listing is depth 1, with a share prefix on its entries.
  - Streamed reads, prefix reads and deletes are explicit.
- **What a test can see:** the connections it was asked for, with their
  credentials, and every request.
- **What a test can control:** another device's writes and removals,
  scripted failures, and a hook before each streamed read. A streamed read
  is what an offload's read-back is; a pass reads with `read(path:)`. The
  hook is async, so a test can change settings on the main actor in the
  middle of an offload run.

`FakeSyncPasswords` scripts reads, and counts reads and writes.

`SyncHarness` sets up a WebDAV provider at `https://lamp.invalid/dav/`, a
username and workspace sync on. It uses a library under the resolved
temporary directory. It requires the volume's identity to be trusted and
the sweep to be off unless a test turns it on. It clears `LampSyncRequest`
before and after each test.

## Order

1. Seams (production only), with the four existing controller tests moved
   to the fake passwords.
2. Fake and harness. Two tests come first, to prove the harness itself:
   - an empty library syncs and a second pass writes nothing;
   - a source goes and comes back as the same bytes.
3. Offloads:
   - a source goes when the server's copy matches;
   - it stays when the server's copy differs, is gone, or can't be read;
   - a source not yet listed waits, and `syncForOffload` gets it one more
     pass;
   - a change under a run stops the rest: username, endpoint, provider,
     workspace sync, a password that can't be read, and an anonymous flip;
   - a new password for the same account does not stop a run;
   - a busy chat holds the rest, and an open editor does not hold a
     request;
   - a pass asked for during the read-backs waits;
   - a refused pass reaches nothing;
   - a failed pass leaves the last look unused;
   - settings changed during the pass mean no offloads;
   - a connection that isn't the look's reads nothing;
   - workspace sync switched during the pass, in both directions;
   - each workspace is told its own reason.
4. The lock: each setter is refused while sources go, and they all still
   go.
5. Move, kept proportionate because it runs once:
   - an archive is offered the Move and not synced;
   - Move replaces the archive it imported, then syncs;
   - an archive written since stops it;
   - an entry the Move can't place is named first;
   - a Move does not start under a pass;
   - the follow-up pass runs only when an offload is waiting.
6. The sweep through the controller: an idle writing's sources go, an open
   editor keeps them, and setting Never part way through a sweep stops it.
7. Keychain guards, as source scans:
   - `SyncSecretStore.` appears in the controller only inside the
     `.keychain` seam and `webDAVPasswordIsStored`;
   - no test names either.
8. Mutation pass, the decision record, Codex review.

## Deliberately untested

- **The real `LampWebDAVClient`.** `SyncRemoteStoreForwardingTests` and
  core cover it.
- **Folder-provider passes and the folder Move.** They need a
  security-scoped bookmark, and offloads are WebDAV only.
- **`isTheSameLook` changing part way through a run.** It can't happen
  while `passGate` holds, and that is tested.
- **Look expiry and the hourly sweep interval.** There is no clock seam.
- **The probes.**
- **The keychain store itself.** No test may reach it, by the owner's
  directive.

## Found while planning

- **`move` read the password with `password ?? ""`.** An unreadable keychain
  became an empty password, which with an empty username is an anonymous
  connection: the case `withConnection` says must be an error. Fixed in its
  own commit with its own test (0053).
- **Join couldn't succeed on the Mac.** When the archive was kept by the
  phone, `moveOffer` is `.join`. `move` then called
  `LampSyncLibraryMigration.migrate`, which throws `notTheMacsLibrary` for
  a phone-kept archive. The owner asked for it to be fixed: Join now calls
  `LampSyncSettingsStore.migratePhoneLibrary`, as iOS does (0054).
