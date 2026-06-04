import Testing
@testable import MailiaCore

@Test
func organizationSenderGroupsByRootDomain() {
    let rules = EntityGroupingRules()

    let result = rules.group(sender: SenderIdentity(email: "notifications@github.com"))

    #expect(result.canonicalKey == "domain:github.com")
    #expect(result.displayName == "Github")
}

@Test
func organizationSenderIgnoresLocalPart() {
    let rules = EntityGroupingRules()

    let account = rules.group(
        sender: SenderIdentity(displayName: "TypeChat", email: "no-reply@account.typechat.com")
    )
    let mail = rules.group(
        sender: SenderIdentity(displayName: "TypeChat", email: "admin@mail.typechat.com")
    )

    #expect(account.canonicalKey == "domain:typechat.com")
    #expect(account.canonicalKey == mail.canonicalKey)
    #expect(mail.displayName == "TypeChat")
}

@Test
func organizationSenderUsesMatchingFromNameCasing() {
    let rules = EntityGroupingRules()

    let result = rules.group(
        sender: SenderIdentity(displayName: "Type Stack", email: "hello@notifications.typestack.com")
    )

    #expect(result.canonicalKey == "domain:typestack.com")
    #expect(result.displayName == "Type Stack")
}

@Test
func organizationSenderExtractsMatchingFromNameFragment() {
    let rules = EntityGroupingRules()

    let result = rules.group(
        sender: SenderIdentity(displayName: "Ryan at HELLO world", email: "bot@notifications.helloworld.dev")
    )

    #expect(result.canonicalKey == "domain:helloworld.dev")
    #expect(result.displayName == "HELLO world")
}

@Test
func organizationDisplayNameUsesFirstMatchingCandidate() {
    let rules = EntityGroupingRules()

    let displayName = rules.displayName(
        forDomain: "github.com",
        candidateDisplayNames: ["nextop-os/vibe-design", "GitHub"]
    )

    #expect(displayName == "GitHub")
}

@Test
func organizationSenderIgnoresNonMatchingFromName() {
    let rules = EntityGroupingRules()

    let result = rules.group(
        sender: SenderIdentity(displayName: "nextop-os/vibe-design", email: "notifications@github.com")
    )

    #expect(result.canonicalKey == "domain:github.com")
    #expect(result.displayName == "Github")
}

@Test
func organizationPersonalNameSenderGroupsByRootDomain() {
    let rules = EntityGroupingRules()

    let result = rules.group(sender: SenderIdentity(displayName: "Daniel", email: "daniel.z@posthog.com"))

    #expect(result.canonicalKey == "domain:posthog.com")
    #expect(result.displayName == "Posthog")
}

@Test
func organizationSenderUsesStableDomainDisplayName() {
    let rules = EntityGroupingRules()

    let result = rules.group(
        sender: SenderIdentity(displayName: "Google Accounts", email: "noreply@accounts.google.com")
    )

    #expect(result.canonicalKey == "domain:google.com")
    #expect(result.displayName == "Google")
    #expect(result.source == "organization-domain-rule")
}

@Test
func organizationSendersWithSameRootDomainMerge() {
    let rules = EntityGroupingRules()

    let accountsResult = rules.group(
        sender: SenderIdentity(displayName: "Google Accounts", email: "noreply@accounts.google.com")
    )
    let mailResult = rules.group(
        sender: SenderIdentity(displayName: "Google Accounts", email: "noreply@mail.google.com")
    )

    #expect(accountsResult.canonicalKey == mailResult.canonicalKey)
    #expect(accountsResult.canonicalKey == "domain:google.com")
}

@Test
func organizationSendersWithDifferentFromNamesStillMerge() {
    let rules = EntityGroupingRules()

    let accountsResult = rules.group(
        sender: SenderIdentity(displayName: "Google Accounts", email: "noreply@accounts.google.com")
    )
    let workspaceResult = rules.group(
        sender: SenderIdentity(displayName: "Google Workspace", email: "noreply@workspace.google.com")
    )

    #expect(accountsResult.canonicalKey == workspaceResult.canonicalKey)
}

@Test
func consumerDomainSenderStaysSeparateByEmail() {
    let rules = EntityGroupingRules()

    let alice = rules.group(sender: SenderIdentity(displayName: "Alice", email: "alice@gmail.com"))
    let bob = rules.group(sender: SenderIdentity(displayName: "Bob", email: "bob@gmail.com"))
    let mailDotCom = rules.group(sender: SenderIdentity(displayName: "Admin", email: "admin@mail.com"))
    let qq = rules.group(sender: SenderIdentity(displayName: "Private", email: "10001@qq.com"))

    #expect(alice.canonicalKey == "sender:alice@gmail.com")
    #expect(bob.canonicalKey == "sender:bob@gmail.com")
    #expect(mailDotCom.canonicalKey == "sender:admin@mail.com")
    #expect(qq.canonicalKey == "sender:10001@qq.com")
    #expect(alice.canonicalKey != bob.canonicalKey)
}

@Test
func compoundPublicSuffixKeepsRegistrantDomain() {
    let rules = EntityGroupingRules()

    let student = rules.group(sender: SenderIdentity(email: "student@stu.hit.edu.cn"))
    let notice = rules.group(sender: SenderIdentity(email: "notice@mail.hit.edu.cn"))

    #expect(student.canonicalKey == "domain:hit.edu.cn")
    #expect(student.canonicalKey == notice.canonicalKey)
}
