# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A Swift package (`Persistence`) wrapping Core Data + CloudKit sync for apps on Apple platforms. Swift tools 6.2 with strict concurrency; platform minimums are macOS/iOS/tvOS/watchOS 26. No external dependencies.

## Commands

```sh
swift build                                   # build
swift test                                    # run all tests
swift test --filter PersistenceTests/testExample   # run a single test
```

Tests are XCTest-based in `Tests/PersistenceTests/`.

## Architecture

Two largely independent subsystems live in `Sources/Persistence/`:

### 1. Core Data + persistent history tracking

- **`Persistence`** (actor) — the public entry point. Owns an `NSPersistentContainer` (or `NSPersistentCloudKitContainer` when `isCloud: true`) with persistent history tracking and remote-change notifications enabled. Exposes `save()`, `perform()`, `fetchUpdates()`, `count()`, and Spotlight-delegate creation.
- **`HistoryRequestHandler`** (actor) — fetches `NSPersistentHistoryTransaction`s since the last stored token, merges them into `viewContext`, and purges consumed history. Created by `Persistence` in its initializer.
- **`HistoryToken`** — persists the last-processed `NSPersistentHistoryToken` to a file under `NSPersistentContainer.defaultDirectoryURL()/<appName>/token.data` so history fetches resume across launches.

### 2. Direct CloudKit change fetching / subscriptions

- **`DatabaseOperationHelper`** — chains `CKFetchDatabaseChangesOperation` → `CKFetchRecordZoneChangesOperation`, delivering changed `CKRecord`s via a completion handler. On failure it falls back to the last in-memory token from `tokenCache`.
- **`NotificationTokenHelper`** / **`NotificationTokenType`** — archive/unarchive `CKServerChangeToken`s (`server` and `zone`) to files alongside the history token.
- **`Subscriber`** — ensures a `CKDatabaseSubscription` exists for a record type (fetch, then create if missing).

`DatabaseMigrator` (`@MainActor`) is a standalone progressive Core Data migration utility (WAL checkpoint → migrate to temp store → replace → destroy temp).

Mermaid class/sequence diagrams are in `docs/`.

## Concurrency conventions

This package is mid-migration to Swift 6 concurrency (see recent commits): async methods are the canonical API; completion-handler variants are legacy wrappers being phased out (e.g. `fetchUpdate(:completionHandler:)` was already removed).

Core Data queue confinement is enforced explicitly and matters more than the actor isolation:

- `container.viewContext` is main-queue confined — every touch (even reading `name` or `hasChanges`) goes through `context.perform { }` / `performAndWait { }`, never directly from an actor's executor.
- Background contexts (`newBackgroundContext()`) are private-queue confined — `execute(_:)` for history requests runs inside `performAndWait` on that context.
- `nonisolated(unsafe)` is used sparingly for non-`Sendable` values (e.g. `Notification`) that are created locally and handed into a `perform` block; keep such uses justified with a comment as in `HistoryRequestHandler.fetchUpdates()`.
