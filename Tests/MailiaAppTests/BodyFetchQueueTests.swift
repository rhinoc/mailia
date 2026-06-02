import Testing
@testable import MailiaApp

@Test
func bodyFetchPriorityMapsWebPriorityBuckets() {
    #expect(BodyFetchPriority(webPriority: nil) == .visible)
    #expect(BodyFetchPriority(webPriority: 500) == .visible)
    #expect(BodyFetchPriority(webPriority: 499) == .nearby)
    #expect(BodyFetchPriority(webPriority: 400) == .nearby)
    #expect(BodyFetchPriority(webPriority: 399) == .selectedPage)
    #expect(BodyFetchPriority(webPriority: 300) == .selectedPage)
    #expect(BodyFetchPriority(webPriority: 299) == .entityPreview)
    #expect(BodyFetchPriority(webPriority: 200) == .entityPreview)
    #expect(BodyFetchPriority(webPriority: 199) == .background)
}
