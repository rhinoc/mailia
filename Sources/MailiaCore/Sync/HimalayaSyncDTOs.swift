import Foundation

public extension HimalayaAccountDTO {
    var discoveredAccount: DiscoveredAccount {
        discoveredAccount(metadata: nil)
    }

    func discoveredAccount(metadata: HimalayaConfigAccountMetadata?) -> DiscoveredAccount {
        DiscoveredAccount(
            accountKey: name,
            emailAddress: metadata?.emailAddress,
            providerHint: backend,
            displayName: metadata?.displayName,
            isDefault: metadata?.isDefault ?? isDefault
        )
    }
}

public extension HimalayaFolderDTO {
    func discoveredFolder(accountKey: String) -> DiscoveredFolder {
        DiscoveredFolder(
            accountKey: accountKey,
            providerName: name,
            role: FolderClassifier.role(for: self)
        )
    }
}

public extension HimalayaEnvelopeDTO {
    func envelopeMessage(
        accountKey: String,
        folderName: String,
        folderRole: FolderRole
    ) -> EnvelopeMessage {
        EnvelopeMessage(
            accountKey: accountKey,
            folderName: folderName,
            himalayaEnvelopeID: id,
            subject: subject,
            from: from?.mailAddress,
            to: to.map { [$0.mailAddress] } ?? [],
            messageDate: date,
            direction: folderRole == .sent ? .outgoing : .incoming,
            hasAttachments: hasAttachment,
            flags: flags
        )
    }
}

public extension HimalayaAddressDTO {
    var mailAddress: MailAddress {
        MailAddress(displayName: name, emailAddress: addr)
    }
}

public extension MailAppServerAccount {
    var discoveredAccount: DiscoveredAccount {
        discoveredAccount(metadata: nil)
    }

    func discoveredAccount(metadata: HimalayaConfigAccountMetadata?) -> DiscoveredAccount {
        DiscoveredAccount(
            accountKey: name,
            emailAddress: emailAddress ?? metadata?.emailAddress,
            providerHint: backend,
            displayName: displayName ?? metadata?.displayName,
            isDefault: isDefault || (metadata?.isDefault ?? false)
        )
    }
}

public extension MailAppServerFolder {
    func discoveredFolder(accountKey: String) -> DiscoveredFolder {
        DiscoveredFolder(
            accountKey: accountKey,
            providerName: name,
            role: FolderClassifier.role(forName: name, desc: desc)
        )
    }
}

public extension MailAppServerMessageEnvelope {
    func envelopeMessage(
        accountKey: String,
        folderName: String,
        folderRole: FolderRole
    ) -> EnvelopeMessage {
        EnvelopeMessage(
            accountKey: accountKey,
            folderName: folderName,
            himalayaEnvelopeID: id,
            subject: subject,
            from: from?.mailAddress,
            to: to.map { [$0.mailAddress] } ?? [],
            messageDate: date,
            direction: folderRole == .sent ? .outgoing : .incoming,
            hasAttachments: hasAttachment,
            flags: flags
        )
    }
}

public extension MailAppServerMessageAddress {
    var mailAddress: MailAddress {
        MailAddress(displayName: name, emailAddress: addr)
    }
}
