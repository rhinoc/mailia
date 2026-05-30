import Testing
@testable import MailiaCore

@Test
func serviceSenderGroupsByDomain() {
    let rules = EntityGroupingRules()

    let result = rules.group(sender: SenderIdentity(email: "notifications@github.com"))

    #expect(result.canonicalKey == "domain:github.com")
    #expect(result.displayName == "Github")
}

@Test
func personalCompanySenderDoesNotGroupByDomain() {
    let rules = EntityGroupingRules()

    let result = rules.group(sender: SenderIdentity(displayName: "Daniel", email: "daniel.z@posthog.com"))

    #expect(result.canonicalKey == "sender:daniel.z@posthog.com")
    #expect(result.displayName == "Daniel")
}
