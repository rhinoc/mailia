import Testing
@testable import MailiaCore

@Test
func mailiaTimingFormatsStableGrepFriendlyLine() {
    let line = MailiaTiming.formatLine(
        operation: "app_server.message/list",
        durationMilliseconds: 42,
        fields: [
            .label("workspace", "main"),
            .label("count", 3)
        ]
    )

    #expect(line == "MailiaTiming operation=app_server.message_list duration_ms=42 status=success workspace=main count=3")
}

@Test
func mailiaTimingRedactsPrivateIdentifiersAndPaths() {
    let line = MailiaTiming.formatLine(
        operation: "body.fetch",
        durationMilliseconds: 7,
        fields: [
            .redacted("account", "person@example.com"),
            .redacted("folder", "Personal/Archive"),
            .label("path", "/Users/example/Library/Application Support/Mailia/body.html")
        ]
    )

    #expect(line.contains("MailiaTiming operation=body.fetch duration_ms=7 status=success"))
    #expect(line.contains("account=redacted:"))
    #expect(line.contains("folder=redacted:"))
    #expect(line.contains("path=redacted:"))
    #expect(!line.contains("person@example.com"))
    #expect(!line.contains("Personal/Archive"))
    #expect(!line.contains("/Users/example"))
    #expect(!line.contains("Application Support"))
}

@Test
func mailiaTimingRedactionIsStable() {
    #expect(MailiaTiming.redactedIdentifier("work@example.com") == MailiaTiming.redactedIdentifier("work@example.com"))
    #expect(MailiaTiming.redactedIdentifier("work@example.com") != MailiaTiming.redactedIdentifier("other@example.com"))
}

@Test
func mailiaTimingUsesPersistentLogPathOutsideTests() {
    let url = MailiaTiming.persistentLogURL(environment: [:])

    #expect(url?.lastPathComponent == "mailia-timing.log")
    #expect(url?.deletingLastPathComponent().lastPathComponent == "Mailia")
}

@Test
func mailiaTimingSkipsDefaultPersistentLogPathDuringTests() {
    let url = MailiaTiming.persistentLogURL(environment: [
        "XCTestConfigurationFilePath": "/tmp/MailiaTests.xctestconfiguration"
    ])

    #expect(url == nil)
}

@Test
func mailiaTimingAllowsPersistentLogPathOverride() {
    let url = MailiaTiming.persistentLogURL(environment: [
        "XCTestConfigurationFilePath": "/tmp/MailiaTests.xctestconfiguration",
        "MAILIA_TIMING_LOG_PATH": "~/mailia-timing-test.log"
    ])

    #expect(url?.path.hasSuffix("/mailia-timing-test.log") == true)
}
