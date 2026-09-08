//
//  ManagedObjectContextExecutor.swift
//  Persistence
//
//  Created by Jae Seung Lee on 7/5/26.
//

import CoreData

// A serial executor (SE-392) that runs an actor's jobs on a managed object
// context's queue. An actor adopting it via unownedExecutor is isolated to
// the context, so it can use the context directly without perform blocks.
// Same technique as SwiftData's ModelActor and CoreDataEvolution's
// @NSModelActor.
//
// @unchecked Sendable: the context is only used to schedule work through
// perform, which is safe to call from any thread.
final class ManagedObjectContextExecutor: SerialExecutor, @unchecked Sendable {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let unownedExecutor = asUnownedSerialExecutor()
        context.perform {
            unownedJob.runSynchronously(on: unownedExecutor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
