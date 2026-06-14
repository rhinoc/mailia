import MailiaCore
import Testing
@testable import MailiaApp

@Test
func timelineWebStateSendsOnlyDisplayHTMLForCurrentOptions() {
    let variants = MailiaTimelineHTMLVariants(EmailHTMLDisplayVariants(
        remoteContentBlockedHTML: "<p>blocked</p>",
        quotedReplyHiddenHTML: "<p>quoted hidden</p>",
        quotedReplyHiddenRemoteContentBlockedHTML: "<p>quoted hidden blocked</p>"
    ))
    let item = timelineWebStateItem(htmlVariants: variants)
    let state = TimelineWebState(
        entity: nil,
        items: [item],
        isLoadingTimeline: false,
        isLoadingOlderTimeline: false,
        isLoadingNewerTimeline: false,
        hasOlderTimeline: false,
        hasNewerTimeline: false,
        bodyStates: [
            item.id: .loaded(MailiaTimelineBody(
                html: "<p>full body</p>",
                htmlVariants: variants
            ))
        ],
        attachmentDownloadStates: [:],
        scrollAnchor: nil,
        displayOptions: TimelineDisplayOptions(loadRemoteContent: false)
    )

    #expect(state.items.first?.html == "<p>blocked</p>")
    #expect(state.items.first?.htmlVariants == nil)
    if case .loaded(let body) = state.bodyStates[String(item.id)] {
        #expect(body.html == "<p>blocked</p>")
        #expect(body.htmlVariants == nil)
    } else {
        Issue.record("Expected loaded body state.")
    }
}

@Test
func timelineWebStateSendsFullHTMLWhenRemoteContentIsAllowed() {
    let variants = MailiaTimelineHTMLVariants(EmailHTMLDisplayVariants(
        remoteContentBlockedHTML: "<p>blocked</p>",
        quotedReplyHiddenHTML: "<p>quoted hidden</p>",
        quotedReplyHiddenRemoteContentBlockedHTML: "<p>quoted hidden blocked</p>"
    ))
    let item = timelineWebStateItem(htmlVariants: variants)
    let state = TimelineWebState(
        entity: nil,
        items: [item],
        isLoadingTimeline: false,
        isLoadingOlderTimeline: false,
        isLoadingNewerTimeline: false,
        hasOlderTimeline: false,
        hasNewerTimeline: false,
        bodyStates: [
            item.id: .loaded(MailiaTimelineBody(
                html: "<p>full body</p>",
                htmlVariants: variants
            ))
        ],
        attachmentDownloadStates: [:],
        scrollAnchor: nil,
        displayOptions: TimelineDisplayOptions(loadRemoteContent: true)
    )

    #expect(state.items.first?.html == "<p>full item</p>")
    #expect(state.items.first?.htmlVariants == nil)
    if case .loaded(let body) = state.bodyStates[String(item.id)] {
        #expect(body.html == "<p>full body</p>")
        #expect(body.htmlVariants == nil)
    } else {
        Issue.record("Expected loaded body state.")
    }
}

private func timelineWebStateItem(htmlVariants: MailiaTimelineHTMLVariants?) -> MailiaTimelineItem {
    MailiaTimelineItem(
        id: 10,
        entityID: 20,
        direction: .incoming,
        rfcMessageID: "<message@example.com>",
        subject: "Hello",
        preview: "Preview",
        html: "<p>full item</p>",
        htmlVariants: htmlVariants,
        date: nil,
        accountLabel: "personal",
        accountEmoji: nil,
        accountAvatarImageDataURL: nil,
        folderLabel: "Inbox",
        envelopeID: "envelope-10",
        isFlagged: false,
        from: MailAddress(displayName: "Sender", emailAddress: "sender@example.com"),
        to: [MailAddress(displayName: "Recipient", emailAddress: "recipient@example.net")],
        cc: [],
        fromLabel: "Sender",
        toLabel: "Recipient",
        hasAttachments: false
    )
}
