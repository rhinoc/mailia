import Foundation
import Testing
@testable import MailiaCore

@Test
func initialSyncWindowUsesMainHistoryAndLimit() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let calculator = SyncWindowCalculator()

    let window = calculator.initialWindow(now: now, isJunk: false)

    #expect(window.pageSize == 500)
    #expect(window.startDate < now)
}

@Test
func incrementalSyncWindowUsesOverlapAndIncrementalLimit() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let lastSync = now - Duration.hours(2).timeIntervalApproximation
    let calculator = SyncWindowCalculator()

    let window = calculator.incrementalWindow(now: now, lastSuccessfulSyncAt: lastSync, isJunk: false)

    #expect(window.pageSize == 200)
    #expect(window.startDate < lastSync)
}
