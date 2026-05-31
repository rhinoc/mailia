import Foundation

public struct HimalayaList<Value: Decodable>: Decodable {
    public var values: [Value]

    public init(from decoder: Decoder) throws {
        if let values = try? [Value](from: decoder) {
            self.values = values
            return
        }

        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        for keyName in ["accounts", "folders", "envelopes", "messages", "items", "data"] {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            if let values = try? container.decode([Value].self, forKey: key) {
                self.values = values
                return
            }
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a JSON array or a keyed list payload"
            )
        )
    }
}

public struct DynamicCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

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
