# 0053. The sync controller is tested against a fake server

Status: Accepted, 2026-11-28. Mac `SyncPasswords` and the controller's
`makeWebDAVStore`, held by `LibrarySyncControllerPassTests` (the offload,
lock, sweep and Move tests beside it) and `SyncKeychainGuardTests`.
Planned in `../SyncControllerHarnessPlan.md`.

## Context

Nothing tested the Mac's `LibrarySyncController` through a whole pass. The
offload rules of 0020–0024 are held by tests of the functions under it, and
the last thing between a source and its deletion was never run in a test:
the read-back inside `carryOutOffloads` and `isStillTheLook`, asked again
between reads. Neither was the Move. Both paths build their own
`LampWebDAVClient` and read the owner's keychain, so neither could run in a
test.

The owner's standing rule settles one constraint before any design: no test
may reach the stored WebDAV password. The controller reaches the keychain in
eleven places, and one of them deletes it.

## Decision

- **Two seams on the controller's init.**
  - `passwords: SyncPasswords` has **no default**. The app passes
    `.keychain`, and a test that leaves it out does not compile.
  - `makeWebDAVStore` defaults to `LampWebDAVClient.init` and is used at
    the three places a WebDAV store is made: a pass, an offload's read-back
    and a Move.
  - The sweep reads its setting from the controller's `defaults` and no
    longer from `.standard`. In the app the two are the same.
- **`FakeWebDAVServer`, in the Mac's test target.**
  - It holds files in memory, each with a strong ETag.
  - Conditional writes refuse as the real client does.
  - Listings are depth 1, with a share prefix.
  - Every connection and request is recorded, and a test can hook in before
    any request. That hook is how a test changes a setting between two
    read-backs.
- **One serialized suite.** `LampSyncRequest` and the editor and chat
  registries are process-wide.
- **Source scans** check two things: the controller reaches the keychain
  only through the seam, and no other test file names the keychain.

What follows: the mutation pass removed 22 guards one at a time, and each
one fails a test except these three:
- **`lastObservation = finished ? … : nil`.** The `if finished` around the
  offloads also holds it, and nothing a test can see separates the two.
- **The sweep's check for an open editor before each workspace.** The check
  before each file asks the same question before the first read-back.
- **`withConnection`'s own source-and-account check.** See below.

## Not tested, on purpose

- **The real client.** `SyncRemoteStoreForwardingTests` and core's own
  tests cover it.
- **The folder provider.** It needs a security-scoped bookmark, and offloads
  are WebDAV only (0022).
- **`withConnection` made as another account than the look's.** Between
  `offloadObservation` and `withConnection` nothing suspends, so the only way
  to reach it is a password store scripted by read count. Removing that
  guard leaves every test passing.
- **Look expiry and the hourly sweep interval.** There is no clock seam, and
  adding one only to test these isn't worth it.

## Rejected

- **A local HTTP listener, or a `URLProtocol` stub under the real client.**
  Either would exercise the client, but this change tests the controller
  logic above `LampSyncRemoteStore`. Both would also need PROPFIND XML and
  upload bodies. A `URLProtocol` handler runs on URLSession's thread, which
  makes a hook that changes main-actor state awkward.
- **A default for `passwords`.** One forgotten argument would read the
  owner's keychain, and `forgetSyncDetails` would delete it.
- **A static override of `SyncSecretStore`.** It is process-wide state in a
  suite that already has to fight process-wide state.
- **A stored handle for the Move's follow-up `Task`.** A production change
  for a one-time path. The test waits on the fake's pass count instead, with
  a twin that proves the wait is long enough.

## Found while planning

- **The Move read its password as `password ?? ""`.** An unreadable keychain
  became an empty password, and with no username that is an anonymous
  connection: the case `withConnection` already refuses. The Move now
  reads the password as a pass does, and
  `aMoveStopsWhenThePasswordCannotBeRead` holds it.
- **Join could not succeed on the Mac.** See 0054.
