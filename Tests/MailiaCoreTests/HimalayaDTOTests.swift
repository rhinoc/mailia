import Foundation
import Testing
@testable import MailiaCore

@Test
func decodesObservedHimalayaAccountJSON() throws {
    let data = #"[{"name":"gmail","backend":"IMAP, None","default":true}]"#.data(using: .utf8)!

    let accounts = try JSONDecoder().decode([HimalayaAccountDTO].self, from: data)

    #expect(accounts == [HimalayaAccountDTO(name: "gmail", backend: "IMAP, None", isDefault: true)])
}

@Test
func classifiesLocalizedGmailFoldersFromDesc() {
    #expect(FolderClassifier.role(for: HimalayaFolderDTO(name: "[Gmail]/垃圾邮件", desc: "\\HasNoChildren, \\Junk")) == .junk)
    #expect(FolderClassifier.role(for: HimalayaFolderDTO(name: "[Gmail]/已发邮件", desc: "\\HasNoChildren, \\Sent")) == .sent)
    #expect(FolderClassifier.role(for: HimalayaFolderDTO(name: "[Gmail]/所有邮件", desc: "\\All, \\HasNoChildren")) == .normal)
    #expect(FolderClassifier.role(for: HimalayaFolderDTO(name: "[Gmail]/草稿", desc: "\\Drafts, \\HasNoChildren")) == .drafts)
}

@Test
func parsesObservedHimalayaEnvelopeDate() throws {
    let date = try #require(HimalayaDateParser.parse("2026-05-30 04:55+00:00"))
    let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)

    #expect(components.year == 2026)
    #expect(components.month == 5)
    #expect(components.day == 30)
    #expect(components.hour == 4)
    #expect(components.minute == 55)
}
