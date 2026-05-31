import Foundation
import Testing
@testable import MailiaApp

@Test
func timelineWebAssetLocatorLoadsBundledIndex() throws {
    let indexURL = try #require(TimelineWebAssetLocator().timelineIndexURL())

    #expect(indexURL.lastPathComponent == "index.html")
    #expect(indexURL.path.contains("TimelineWeb"))
    #expect(FileManager.default.fileExists(atPath: indexURL.path))
}
