import Foundation
import Testing
@testable import MailiaApp

@MainActor
@Test
func listFetchQueueRunsHigherPriorityPendingJobsFirst() async {
    let queue = ListFetchQueue(maxConcurrentLoads: 1)
    var events: [String] = []
    var releaseFirst: CheckedContinuation<Void, Never>?

    queue.enqueue(id: .selectedTimeline(entityID: 1), priority: .selected) {
        events.append("first-start")
        await withCheckedContinuation { continuation in
            releaseFirst = continuation
        }
        events.append("first-end")
    }
    queue.enqueue(id: .timelinePage(direction: .older), priority: .incremental) {
        events.append("older")
    }
    queue.enqueue(id: .selectedTimeline(entityID: 2), priority: .selected) {
        events.append("selected")
    }

    await waitForQueueTest { releaseFirst != nil }
    #expect(events == ["first-start"])

    releaseFirst?.resume()
    await waitForQueueTest { events.count == 4 }
    #expect(events == ["first-start", "first-end", "selected", "older"])
}

@MainActor
@Test
func listFetchQueueReplacesPendingJobWithSameID() async {
    let queue = ListFetchQueue(maxConcurrentLoads: 1)
    var events: [String] = []
    var releaseFirst: CheckedContinuation<Void, Never>?

    queue.enqueue(id: .selectedTimeline(entityID: 1), priority: .selected) {
        events.append("first-start")
        await withCheckedContinuation { continuation in
            releaseFirst = continuation
        }
        events.append("first-end")
    }
    queue.enqueue(id: .timelinePage(direction: .older), priority: .incremental) {
        events.append("older-original")
    }
    queue.enqueue(id: .timelinePage(direction: .older), priority: .incremental) {
        events.append("older-replacement")
    }

    await waitForQueueTest { releaseFirst != nil }
    releaseFirst?.resume()
    await waitForQueueTest { events.count == 3 }
    #expect(events == ["first-start", "first-end", "older-replacement"])
}

@MainActor
private func waitForQueueTest(
    timeoutNanoseconds: UInt64 = 500_000_000,
    predicate: @escaping @MainActor () -> Bool
) async {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while !predicate(),
          DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
