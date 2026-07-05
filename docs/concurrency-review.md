# Concurrency Review — 2026-07-05

The package compiles clean in Swift 6 language mode, so every issue below is in the
category the compiler cannot catch: Core Data queue confinement, actor reentrancy,
and CloudKit callbacks that are not `@Sendable`-annotated in the SDK.

## Findings

### 1. `DatabaseOperationHelper` — unsynchronized shared mutable state (highest risk)

`tokenCache` is a plain dictionary mutated from CloudKit operation callbacks
(`changeTokenUpdatedBlock`, `recordZoneChangeTokensUpdatedBlock`, and the result
blocks), which CloudKit invokes on its own internal queues. It is also read from
the `serverToken`/`zoneToken` computed properties on whichever thread calls
`addDatabaseChangesOperation`. That is a genuine data race on a `Dictionary` —
undefined behavior, can crash. The compiler is silent only because CloudKit's
block properties are not marked `@Sendable`.

Two adjacent problems in the same class:

- The `serverToken` getter caches into `tokenCache[.zone]` instead of `.server`
  — a copy-paste bug that corrupts the fallback token on failure.
- `NotificationTokenHelper` does uncoordinated file reads/writes to the same
  token files from those concurrent callbacks.

### 2. `HistoryRequestHandler.fetchUpdates()` — actor reentrancy duplicates work

`fetchUpdates()` awaits `context.perform` inside its transaction loop, then writes
the token afterwards. Actors are reentrant at suspension points: if
`fetchUpdates()` is called again (e.g., two remote-change notifications arrive
close together — the normal trigger), the second call runs
`fetchHistoryTransactions()` with the *old* token before the first call has
advanced it. Both calls merge the same transactions into `viewContext` and write
tokens in a nondeterministic order. Result: duplicate merges and a possibly
regressed token.

### 3. `Persistence.save(with:completionHandler:)` — racy context-name juggling plus executor blocking

The method sets `viewContext.name` (used as the transaction attribution label in
persistent history), then calls the completion-based `save`, which spawns an
unstructured `Task` to do the actual save, then restores the name in the
completion. Because the save is detached from the name-setting, two overlapping
`save(with:)` calls interleave freely: save A can commit under B's name (wrong
history attribution), and the restores race so the context can end up with a
stale name permanently.

Additionally, this method uses `performAndWait` on the main-queue `viewContext`
from the actor's executor. That blocks a cooperative-pool thread until the main
queue services the block — if the main thread is simultaneously awaiting this
actor, that is a deadlock; even when it isn't, blocking the pool violates Swift
concurrency's forward-progress contract. (`nonisolated count(_:)` has the same
blocking shape but from the caller's thread — the conventional trade-off, lower
concern.)

### 4. `Persistence.init` — confinement violation and an escaping `Task`

- `container.viewContext.name = name` touches the main-queue-confined context
  directly from whatever thread runs `init`, violating the confinement rule the
  rest of the file follows.
- The unstructured `Task { await historyRequestHandler.purgeHistory() }` has no
  ordering guarantee relative to the first `fetchUpdates()`, retains the handler
  beyond init, and cannot be cancelled.
- `init` returns before `loadPersistentStores` completes; a load failure is only
  logged, and callers can start using `viewContext` against a container with no
  store.

### 5. Smaller items

- `Subscriber` / `DatabaseOperationHelper` completion handlers are invoked on
  CloudKit's callback queues; callers get no isolation guarantee.
- `HistoryToken.setToken(nil)` sets `last = nil` but skips deleting the token
  file — so `invalidateHistoryToken()` does not survive a relaunch; the stale
  token reloads from disk. A logic bug that interacts with the token-race fixes.
- `DatabaseMigrator` is `@MainActor` yet does synchronous store migration and WAL
  checkpointing — the whole migration blocks the main thread. Also its private
  `forceWALCheckpointingForStore(at:completionHandler:)` only calls its
  completion on failure, never on success (and is unused).
- The test wraps its assertions in an unawaited `Task`, so the test method
  returns before the assertion runs — it can never fail. It also hits real
  CloudKit entitlements from a package test.

## Plan

| Phase | Scope | Status |
|---|---|---|
| 1 | Serialize `DatabaseOperationHelper` token state (lock around cache + token-file I/O), fix the `.zone`/`.server` key bug, make `NotificationTokenHelper` `Sendable` | Done |
| 2 | Coalesce concurrent `fetchUpdates()` calls onto a single in-flight task so the token read → process → write section cannot interleave; drop the unused completion-handler variant | Planned |
| 3 | Replace `save(with:)` name juggling with a single async method doing set-name → save → restore-name inside one `context.perform` block; remove `performAndWait` from actor-isolated code; keep the completion variant as a thin wrapper | Planned |
| 4 | Init hygiene: set `viewContext.name` through the context's queue; replace the fire-and-forget purge `Task` with a lazy purge on the first `fetchUpdates()` pass | Planned |
| 5 | Cleanup: delete the token file on `setToken(nil)`; remove the dead migrator checkpoint overload; rewrite the test as `async` with an in-memory, non-cloud container | Planned |

Deferred (API design decisions, not taken up here):

- Surfacing `loadPersistentStores` failure to callers (e.g., an `async throws`
  factory) instead of logging.
- Replacing the operation-based CloudKit API in `DatabaseOperationHelper` with
  the async `CKDatabase.databaseChanges(since:)` family, which would eliminate
  the callback-isolation problem entirely.
- Moving `DatabaseMigrator` off `@MainActor`; migrations typically run once at
  launch before UI, so the blocking is tolerated for now.
