import Foundation
import Testing
@testable import MailiaCore

@Test
func initialSyncWindowUsesMainHistoryAndLimit() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let policy = SyncPolicy(mainHistoryWindow: .days(7), initialPerFolderLimit: 50)
    let calculator = SyncWindowCalculator(policy: policy)

    let window = calculator.initialWindow(now: now, isJunk: false)

    #expect(window.queryStart == now - Duration.days(7).timeIntervalApproximation)
    #expect(window.startDate == window.queryStart)
    #expect(window.checkpointHighWater == now)
    #expect(window.pageSize == 50)
}

@Test
func initialSyncWindowUsesJunkHistoryForJunkFolders() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let policy = SyncPolicy(junkHistoryWindow: .days(3), initialPerFolderLimit: 50)
    let calculator = SyncWindowCalculator(policy: policy)

    let window = calculator.initialWindow(now: now, isJunk: true)

    #expect(window.queryStart == now - Duration.days(3).timeIntervalApproximation)
    #expect(window.checkpointHighWater == now)
    #expect(window.pageSize == 50)
}

@Test
func incrementalSyncWindowUsesOverlapAndIncrementalLimit() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let lastSync = now - Duration.hours(2).timeIntervalApproximation
    let policy = SyncPolicy(checkpointOverlap: .minutes(30), incrementalPerFolderLimit: 25)
    let calculator = SyncWindowCalculator(policy: policy)

    let window = calculator.incrementalWindow(now: now, lastCheckpointHighWater: lastSync, isJunk: false)

    #expect(window.queryStart == lastSync - Duration.minutes(30).timeIntervalApproximation)
    #expect(window.startDate == window.queryStart)
    #expect(window.checkpointHighWater == now)
    #expect(window.pageSize == 25)
}

@Test
func incrementalSyncWindowClampsQueryStartToHistoryWindow() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let lastSync = now - Duration.days(120).timeIntervalApproximation
    let policy = SyncPolicy(
        mainHistoryWindow: .days(90),
        checkpointOverlap: .days(1),
        incrementalPerFolderLimit: 25
    )
    let calculator = SyncWindowCalculator(policy: policy)

    let window = calculator.incrementalWindow(now: now, lastCheckpointHighWater: lastSync, isJunk: false)

    #expect(window.queryStart == now - Duration.days(90).timeIntervalApproximation)
    #expect(window.checkpointHighWater == now)
}

@Test
func incrementalSyncWindowWithoutCheckpointFallsBackToInitialWindow() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let policy = SyncPolicy(mainHistoryWindow: .days(7), initialPerFolderLimit: 50)
    let calculator = SyncWindowCalculator(policy: policy)

    let window = calculator.incrementalWindow(now: now, lastCheckpointHighWater: nil, isJunk: false)

    #expect(window.queryStart == now - Duration.days(7).timeIntervalApproximation)
    #expect(window.checkpointHighWater == now)
    #expect(window.pageSize == 50)
}

@Test
func fullHistoryWindowUsesEpochQueryStartAndOptionalCheckpointHighWater() {
    let runStartedAt = Date(timeIntervalSince1970: 10_000_000)
    let policy = SyncPolicy(fullHistoryPerFolderPageSize: 125)
    let calculator = SyncWindowCalculator(policy: policy)

    let defaultWindow = calculator.fullHistoryWindow()
    let checkpointedWindow = calculator.fullHistoryWindow(checkpointHighWater: runStartedAt)

    #expect(defaultWindow.queryStart == Date(timeIntervalSince1970: 0))
    #expect(defaultWindow.checkpointHighWater == nil)
    #expect(defaultWindow.pageSize == 125)
    #expect(checkpointedWindow.queryStart == Date(timeIntervalSince1970: 0))
    #expect(checkpointedWindow.checkpointHighWater == runStartedAt)
    #expect(checkpointedWindow.pageSize == 125)
}

@Test
func defaultCheckpointOverlapKeepsIncrementalQueryStartAtLeastOneDayBehindHighWater() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let lastCheckpointHighWater = Date(timeIntervalSince1970: 9_900_000)
    let calculator = SyncWindowCalculator()

    let window = calculator.incrementalWindow(
        now: now,
        lastCheckpointHighWater: lastCheckpointHighWater,
        isJunk: false
    )

    #expect(SyncPolicy().checkpointOverlap == .hours(24))
    #expect(window.queryStart == lastCheckpointHighWater - Duration.hours(24).timeIntervalApproximation)
    #expect(window.checkpointHighWater == now)
}
