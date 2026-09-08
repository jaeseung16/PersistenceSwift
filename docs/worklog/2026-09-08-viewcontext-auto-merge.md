# 2026-09-08 — Auto-merge changes into the view context

Branch: `auto-merge`, off `concurrency`.

## Background

This came out of debugging LinkPiler, where an edit made on iPad was not reflected in
the running macOS app until it was restarted (or its window deactivated and
reactivated). The investigation lives in the LinkPiler repo at
`docs/worklog/2026-09-08-icloud-refresh.md`.

The cause was entirely on the consumer side: LinkPiler subscribed to
`.NSPersistentStoreRemoteChange` and called `fetchUpdates()`, but then only re-indexed
Spotlight with the returned object IDs — it never re-published its `@Published`
`links`/`tags`, so nothing in SwiftUI was invalidated. That is fixed in LinkPiler
(commit `a2622eb`). **Nothing in this package was broken**, and the change below is not
a fix for that bug.

Two package-level changes were considered during that investigation and are
re-evaluated here.

## Rejected: `shouldRefreshRefetchedObjects`

Not adopted, in either repo.

- It is a per-`NSFetchRequest` flag. This package builds no fetch requests on behalf of
  consumers (`count()` is the only one, and it is internal), so it could only ever live
  in consumer code.
- It is not the cause. LinkPiler confirmed at runtime that a plain re-fetch surfaces a
  remote edit, so `HistoryRequestHandler.processUpdates()` is already faulting the
  registered objects correctly.
- It carries a real data-loss risk. It overwrites registered objects' property values
  from the store, and consumers commonly mutate an entity and *then* await a save
  (LinkPiler's `update(link:with:)` and `summarize()` both do). A re-fetch landing in
  that window would silently discard the pending edit — and wiring remote changes to a
  UI refresh makes that window much easier to hit.

## Adopted: `viewContext.automaticallyMergesChangesFromParent = true`

`Sources/Persistence/Persistence.swift` — set in `init`, inside the existing
`viewContext.performAndWait` block that already sets `name` (the context is main-queue
confined, so this has to go through its queue like every other touch).

Rationale, on the package's own merits rather than as a bug fix:

- `init` enables `NSPersistentStoreRemoteChangeNotificationPostOptionKey` but the package
  never subscribes to the notification. Every consumer has to wire
  `.NSPersistentStoreRemoteChange` → `fetchUpdates()` itself, and a consumer that does
  not gets **no** merges into `viewContext` at all — the store updates and the view
  context never sees it. Nothing in the API signals that obligation. That is a sharp
  edge for a library, and it is the shape of the bug just chased in LinkPiler.
- It is the configuration Apple pairs with history tracking for
  `NSPersistentCloudKitContainer` (CoreDataCloudKitDemo sets both).
- Cost is low. The CloudKit import context and the history pass may merge the same
  transaction, but `mergeChanges` refreshes objects rather than accumulating, so a
  double merge is idempotent. `fetchUpdates()` still derives its `[NSManagedObjectID]`
  from history, so consumers relying on it to know *what* changed — Spotlight indexing,
  UI invalidation — are unaffected.

### Deliberately not included

- **`mergePolicy`.** Apple's sample also sets `NSMergeByPropertyObjectTrumpMergePolicy`.
  Left at the default `NSErrorMergePolicy`: silently picking a winner is a much larger
  semantic change, and consumers surface the throw to the user (LinkPiler routes it to
  `viewModel.message`).

## Verification

`swift build` clean; `swift test` — 3 tests, 0 failures. No test covers the new
behaviour: exercising it needs two contexts on one coordinator and the existing suite has
no fixture for that. Worth adding if this branch grows.

## Release note

This is a behaviour change for **every** consumer of the package, not just LinkPiler —
objects in the view context get refreshed at times they previously were not. It should
go out as a deliberate tagged release rather than a silent bump.

LinkPiler currently pins `0.2.18` (`097fbf9`); `concurrency` was already 6 commits ahead
of that tag before this branch, all unreleased. Tagging and bumping consumer pins is left
to the author.
