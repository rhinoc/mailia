import AppKit
import CryptoKit
import Foundation
import MailiaCore

actor EntityBrandAvatarResolver {
    enum AvatarCacheStatus: Equatable, Sendable {
        case missing
        case dataURL(String)
    }

    struct SimpleIcon {
        var slug: String
        var color: String
        var packageVersion: String = "16.21.0"
    }

    private static let composeDraftIcon = SimpleIcon(slug: "maildotru", color: "005FF9")
    private static let missingCacheTTL: TimeInterval = 7 * 24 * 60 * 60

    private enum CacheEntry {
        case missing(Date)
        case dataURL(String)
    }

    private struct MissingDiskCacheEntry: Codable {
        var cachedAt: Date
    }

    private struct DNSJSONResponse: Decodable {
        var answer: [DNSJSONAnswer]?

        enum CodingKeys: String, CodingKey {
            case answer = "Answer"
        }
    }

    private struct DNSJSONAnswer: Decodable {
        var data: String
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlightTasks: [String: Task<String?, Never>] = [:]
    private let diskCacheDirectory: URL
    private let session: URLSession

    init(diskCacheDirectory: URL? = nil, session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }

        if let diskCacheDirectory {
            self.diskCacheDirectory = diskCacheDirectory
        } else {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.diskCacheDirectory = Self.defaultDiskCacheDirectory(baseCachesDirectory: cachesDirectory)
        }
        try? FileManager.default.createDirectory(
            at: self.diskCacheDirectory,
            withIntermediateDirectories: true
        )
    }

    static func defaultDiskCacheDirectory(baseCachesDirectory: URL? = nil) -> URL {
        let cachesDirectory = baseCachesDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory
            .appendingPathComponent("Mailia", isDirectory: true)
            .appendingPathComponent("AvatarCache", isDirectory: true)
    }

    func cacheSummary() -> MailiaCacheSummary {
        let stats = Self.directoryStats(at: diskCacheDirectory)
        return MailiaCacheSummary(
            kind: .avatars,
            itemCount: max(stats.itemCount, cache.count),
            byteSize: stats.byteSize
        )
    }

    func clearCache() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        cache.removeAll()
        try? FileManager.default.removeItem(at: diskCacheDirectory)
        try? FileManager.default.createDirectory(
            at: diskCacheDirectory,
            withIntermediateDirectories: true
        )
    }

    func avatarDataURL(forEmailAddress emailAddress: String) async -> String? {
        guard let normalizedEmailAddress = Self.normalizedEmailAddress(emailAddress),
              let domain = Self.domain(fromEmailAddress: normalizedEmailAddress)
        else {
            return nil
        }
        if Self.isPersonalMailboxDomain(domain) {
            return await gravatarDataURL(forEmailAddress: normalizedEmailAddress)
        }
        return await avatarDataURL(forDomain: domain)
    }

    func avatarDataURL(
        primaryEmailAddress: String?,
        emailAddresses: [String],
        debugLabel: String? = nil,
        forceRefresh: Bool = false
    ) async -> String? {
        let normalizedAddresses = Self.uniqueValues(
            [primaryEmailAddress].compactMap { $0 } + emailAddresses
        )
        let addressDomains = normalizedAddresses.compactMap { address -> (address: String, domain: String)? in
            guard let normalizedAddress = Self.normalizedEmailAddress(address),
                  let domain = Self.domain(fromEmailAddress: normalizedAddress)
            else {
                return nil
            }
            return (normalizedAddress, domain)
        }
        guard !addressDomains.isEmpty else {
            Self.debugLog(debugLabel, "no usable email domain primary=\(primaryEmailAddress ?? "nil") emails=\(emailAddresses)")
            return nil
        }

        let organizationDomains = Self.uniqueValues(
            addressDomains
                .map(\.domain)
                .filter { !Self.isPersonalMailboxDomain($0) }
                .flatMap { domain in
                    let rootDomain = Self.registrableDomain(domain)
                    return rootDomain == domain ? [rootDomain] : [rootDomain, domain]
                }
        )
        Self.debugLog(
            debugLabel,
            "addresses=\(addressDomains.map(\.address)) orgDomains=\(organizationDomains)"
        )
        for domain in organizationDomains {
            if let dataURL = await avatarDataURL(
                forDomain: domain,
                debugLabel: debugLabel,
                forceRefresh: forceRefresh
            ) {
                Self.debugLog(debugLabel, "resolved domain=\(domain) length=\(dataURL.count)")
                return dataURL
            }
            Self.debugLog(debugLabel, "domain failed domain=\(domain)")
        }

        for addressDomain in addressDomains where Self.isPersonalMailboxDomain(addressDomain.domain) {
            if let dataURL = await gravatarDataURL(forEmailAddress: addressDomain.address) {
                Self.debugLog(debugLabel, "resolved gravatar address=\(addressDomain.address) length=\(dataURL.count)")
                return dataURL
            }
            Self.debugLog(debugLabel, "gravatar failed address=\(addressDomain.address)")
        }

        Self.debugLog(debugLabel, "no avatar resolved")
        return nil
    }

    func cachedAvatarDataURL(
        primaryEmailAddress: String?,
        emailAddresses: [String]
    ) -> String? {
        for cacheKey in Self.avatarCacheKeys(
            primaryEmailAddress: primaryEmailAddress,
            emailAddresses: emailAddresses
        ) {
            if let dataURL = cachedDataURL(forCacheKey: cacheKey) {
                return dataURL
            }
        }

        return nil
    }

    func cachedAvatarStatus(
        primaryEmailAddress: String?,
        emailAddresses: [String]
    ) -> AvatarCacheStatus? {
        let cacheKeys = Self.avatarCacheKeys(
            primaryEmailAddress: primaryEmailAddress,
            emailAddresses: emailAddresses
        )
        guard !cacheKeys.isEmpty else { return nil }

        var hasMissingCache = false
        for cacheKey in cacheKeys {
            switch cachedEntry(forCacheKey: cacheKey) {
            case .dataURL(let dataURL):
                return .dataURL(dataURL)
            case .missing:
                hasMissingCache = true
            case nil:
                return nil
            }
        }

        return hasMissingCache ? .missing : nil
    }

    func cachedGravatarDataURL(forEmailAddress emailAddress: String) -> String? {
        guard let normalizedEmailAddress = Self.normalizedEmailAddress(emailAddress) else {
            return nil
        }
        return cachedDataURL(forCacheKey: Self.gravatarCacheKey(forEmailAddress: normalizedEmailAddress))
    }

    func composeDraftAvatarDataURL() async -> String? {
        await simpleIconAvatarDataURL(icon: Self.composeDraftIcon, cacheKey: "compose-draft-maildotru")
    }

    func gravatarDataURL(forEmailAddress emailAddress: String) async -> String? {
        guard let normalizedEmailAddress = Self.normalizedEmailAddress(emailAddress) else {
            return nil
        }
        let hash = Self.gravatarHash(forEmailAddress: normalizedEmailAddress)
        let cacheKey = Self.gravatarCacheKey(forEmailAddress: normalizedEmailAddress)

        if let cached = cachedEntry(forCacheKey: cacheKey) {
            switch cached {
            case .missing:
                return nil
            case .dataURL(let dataURL):
                return dataURL
            }
        }
        if let inFlightTask = inFlightTasks[cacheKey] {
            return await inFlightTask.value
        }

        let task = Task { [weak self] in
            await self?.resolveGravatarDataURL(hash: hash)
        }
        inFlightTasks[cacheKey] = task
        let dataURL = await task.value
        inFlightTasks[cacheKey] = nil
        cacheResolvedDataURL(dataURL, forCacheKey: cacheKey)
        return dataURL
    }

    private func avatarDataURL(
        forDomain domain: String,
        debugLabel: String? = nil,
        forceRefresh: Bool = false
    ) async -> String? {
        if let cached = cachedEntry(forCacheKey: domain, allowMissing: !forceRefresh) {
            switch cached {
            case .missing:
                Self.debugLog(debugLabel, "missing cache hit domain=\(domain)")
                return nil
            case .dataURL(let dataURL):
                Self.debugLog(debugLabel, "cache hit domain=\(domain) length=\(dataURL.count)")
                return dataURL
            }
        }
        if !forceRefresh, let inFlightTask = inFlightTasks[domain] {
            Self.debugLog(debugLabel, "join in-flight domain=\(domain)")
            return await inFlightTask.value
        }

        Self.debugLog(debugLabel, "resolve domain=\(domain) forceRefresh=\(forceRefresh)")
        if forceRefresh {
            let dataURL = await resolveAvatarDataURL(
                forDomain: domain,
                debugLabel: debugLabel,
                forceRefresh: true
            )
            cacheResolvedDataURL(dataURL, forDomain: domain, debugLabel: debugLabel)
            return dataURL
        }

        let task = Task { [weak self] in
            await self?.resolveAvatarDataURL(
                forDomain: domain,
                debugLabel: debugLabel,
                forceRefresh: forceRefresh
            )
        }
        inFlightTasks[domain] = task
        let dataURL = await task.value
        inFlightTasks[domain] = nil
        cacheResolvedDataURL(dataURL, forDomain: domain, debugLabel: debugLabel)
        return dataURL
    }

    private func resolveAvatarDataURL(
        forDomain domain: String,
        debugLabel: String? = nil,
        forceRefresh: Bool = false
    ) async -> String? {
        if let simpleIcon = await simpleIconDataURL(
            forDomain: domain,
            debugLabel: debugLabel,
            forceRefresh: forceRefresh
        ) {
            Self.debugLog(debugLabel, "simple icon ok domain=\(domain)")
            return simpleIcon
        }
        Self.debugLog(debugLabel, "simple icon miss domain=\(domain)")

        if let bimiURL = await bimiLogoURL(forDomain: domain),
           let dataURL = await imageDataURL(from: bimiURL) {
            Self.debugLog(debugLabel, "bimi ok domain=\(domain) url=\(bimiURL.absoluteString)")
            return dataURL
        }
        Self.debugLog(debugLabel, "bimi miss domain=\(domain)")

        let candidates = await faviconCandidates(forDomain: domain)
        Self.debugLog(debugLabel, "favicon candidates domain=\(domain) count=\(candidates.count)")
        for candidate in candidates {
            if let dataURL = await imageDataURL(from: candidate) {
                Self.debugLog(debugLabel, "favicon ok domain=\(domain) url=\(candidate.absoluteString)")
                return dataURL
            }
            Self.debugLog(debugLabel, "favicon miss url=\(candidate.absoluteString)")
        }

        return nil
    }

    private func resolveGravatarDataURL(hash: String) async -> String? {
        var components = URLComponents(string: "https://www.gravatar.com/avatar/\(hash)")
        components?.queryItems = [
            URLQueryItem(name: "s", value: "192"),
            URLQueryItem(name: "d", value: "404"),
            URLQueryItem(name: "r", value: "g")
        ]
        guard let url = components?.url else { return nil }

        if let dataURL = await imageDataURL(from: url) {
            return dataURL
        }
        return nil
    }

    private func simpleIconDataURL(
        forDomain domain: String,
        debugLabel: String? = nil,
        forceRefresh: Bool = false
    ) async -> String? {
        guard let icon = Self.simpleIcon(forDomain: domain) else {
            Self.debugLog(debugLabel, "simple icon mapping miss domain=\(domain)")
            return nil
        }
        Self.debugLog(
            debugLabel,
            "simple icon mapping domain=\(domain) slug=\(icon.slug) version=\(icon.packageVersion)"
        )
        return await simpleIconAvatarDataURL(
            icon: icon,
            cacheKey: domain,
            debugLabel: debugLabel,
            forceRefresh: forceRefresh
        )
    }

    private func simpleIconAvatarDataURL(
        icon: SimpleIcon,
        cacheKey: String,
        debugLabel: String? = nil,
        forceRefresh: Bool = false
    ) async -> String? {
        if let cached = cachedEntry(forCacheKey: cacheKey, allowMissing: !forceRefresh) {
            switch cached {
            case .missing:
                Self.debugLog(debugLabel, "simple icon missing cache hit key=\(cacheKey)")
                return nil
            case .dataURL(let dataURL):
                Self.debugLog(debugLabel, "simple icon cache hit key=\(cacheKey) length=\(dataURL.count)")
                return dataURL
            }
        }
        if !forceRefresh, let inFlightTask = inFlightTasks[cacheKey] {
            Self.debugLog(debugLabel, "simple icon join in-flight key=\(cacheKey)")
            return await inFlightTask.value
        }

        Self.debugLog(debugLabel, "simple icon resolve key=\(cacheKey) forceRefresh=\(forceRefresh)")
        if forceRefresh {
            let dataURL = await resolveSimpleIconAvatarDataURL(icon: icon, debugLabel: debugLabel)
            cacheResolvedDataURL(dataURL, forCacheKey: cacheKey, debugLabel: debugLabel)
            return dataURL
        }

        let task = Task { [weak self] in
            await self?.resolveSimpleIconAvatarDataURL(icon: icon, debugLabel: debugLabel)
        }
        inFlightTasks[cacheKey] = task
        let dataURL = await task.value
        inFlightTasks[cacheKey] = nil
        cacheResolvedDataURL(dataURL, forCacheKey: cacheKey, debugLabel: debugLabel)
        return dataURL
    }

    private func resolveSimpleIconAvatarDataURL(icon: SimpleIcon, debugLabel: String? = nil) async -> String? {
        guard let url = URL(string: "https://cdn.jsdelivr.net/npm/simple-icons@\(icon.packageVersion)/icons/\(icon.slug).svg")
        else {
            Self.debugLog(debugLabel, "simple icon invalid url slug=\(icon.slug)")
            return nil
        }
        Self.debugLog(debugLabel, "simple icon fetch url=\(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("Mailia/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("image/svg+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard Self.isSuccessfulHTTPResponse(response) else {
                Self.debugLog(debugLabel, "simple icon http failed status=\(Self.httpStatusCode(response))")
                return nil
            }
            guard data.count <= 200_000 else {
                Self.debugLog(debugLabel, "simple icon too large bytes=\(data.count)")
                return nil
            }
            guard let svg = String(data: data, encoding: .utf8) else {
                Self.debugLog(debugLabel, "simple icon svg decode failed bytes=\(data.count)")
                return nil
            }
            guard let avatarSVGData = Self.simpleIconAvatarSVGData(svg: svg, color: icon.color) else {
                Self.debugLog(debugLabel, "simple icon svg wrap failed slug=\(icon.slug)")
                return nil
            }
            guard let dataURL = await Self.normalizedImageDataURL(data: avatarSVGData, mimeType: "image/svg+xml") else {
                Self.debugLog(debugLabel, "simple icon rasterize failed slug=\(icon.slug)")
                return nil
            }

            Self.debugLog(debugLabel, "simple icon rasterize ok slug=\(icon.slug) length=\(dataURL.count)")
            return dataURL
        } catch {
            Self.debugLog(debugLabel, "simple icon fetch error slug=\(icon.slug) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func bimiLogoURL(forDomain domain: String) async -> URL? {
        var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")
        components?.queryItems = [
            URLQueryItem(name: "name", value: "default._bimi.\(domain)"),
            URLQueryItem(name: "type", value: "TXT")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.setValue("Mailia/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard Self.isSuccessfulHTTPResponse(response) else { return nil }
            let dnsResponse = try JSONDecoder().decode(DNSJSONResponse.self, from: data)
            let records = dnsResponse.answer?.map(\.data) ?? []
            for record in records {
                if let logoURL = Self.bimiLogoURL(fromTXTRecord: record) {
                    return logoURL
                }
            }
        } catch {}

        return nil
    }

    private func faviconCandidates(forDomain domain: String) async -> [URL] {
        var candidates: [URL] = []
        candidates += await linkedIconCandidates(forDomain: domain)

        for path in ["/apple-touch-icon.png", "/favicon.ico", "/favicon.png"] {
            if let url = URL(string: "https://\(domain)\(path)") {
                candidates.append(url)
            }
        }

        var seen: Set<String> = []
        return candidates.filter { url in
            seen.insert(url.absoluteString).inserted
        }
    }

    private func linkedIconCandidates(forDomain domain: String) async -> [URL] {
        guard let rootURL = URL(string: "https://\(domain)/") else { return [] }
        var request = URLRequest(url: rootURL)
        request.setValue("Mailia/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard Self.isSuccessfulHTTPResponse(response),
                  data.count <= 1_000_000,
                  let html = String(data: data, encoding: .utf8)
            else {
                return []
            }
            return Self.iconHREFs(fromHTML: html).compactMap { href in
                URL(string: href, relativeTo: rootURL)?.absoluteURL
            }
        } catch {
            return []
        }
    }

    private func imageDataURL(from url: URL) async -> String? {
        guard url.scheme?.lowercased() == "https" else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mailia/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/svg+xml,image/x-icon,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard Self.isSuccessfulHTTPResponse(response),
                  data.count <= 1_000_000
            else {
                return nil
            }

            let mimeType = Self.imageMIMEType(response: response, url: url, data: data)
            return await Self.normalizedImageDataURL(data: data, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    private func diskCachedDataURL(forDomain domain: String) -> String? {
        diskCachedDataURL(forCacheKey: domain)
    }

    private func diskCachedDataURL(forCacheKey cacheKey: String) -> String? {
        let url = diskCacheURL(forCacheKey: cacheKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    private func cachedDataURL(forCacheKey cacheKey: String) -> String? {
        if let cached = cache[cacheKey],
           case .dataURL(let dataURL) = cached {
            return dataURL
        }
        if let diskCached = diskCachedDataURL(forCacheKey: cacheKey) {
            cache[cacheKey] = .dataURL(diskCached)
            return diskCached
        }
        return nil
    }

    private func cachedEntry(
        forCacheKey cacheKey: String,
        allowMissing: Bool = true
    ) -> CacheEntry? {
        if let cached = cache[cacheKey] {
            switch cached {
            case .dataURL:
                return cached
            case .missing(let cachedAt):
                guard allowMissing, Self.isMissingCacheValid(cachedAt) else {
                    cache[cacheKey] = nil
                    removeDiskMissingCache(forCacheKey: cacheKey)
                    break
                }
                return cached
            }
        }

        if let diskCached = diskCachedDataURL(forCacheKey: cacheKey) {
            let entry = CacheEntry.dataURL(diskCached)
            cache[cacheKey] = entry
            return entry
        }

        guard allowMissing, let cachedAt = diskCachedMissingDate(forCacheKey: cacheKey) else {
            return nil
        }
        guard Self.isMissingCacheValid(cachedAt) else {
            removeDiskMissingCache(forCacheKey: cacheKey)
            return nil
        }
        let entry = CacheEntry.missing(cachedAt)
        cache[cacheKey] = entry
        return entry
    }

    private func cacheResolvedDataURL(_ dataURL: String?, forDomain domain: String, debugLabel: String? = nil) {
        cacheResolvedDataURL(dataURL, forCacheKey: domain, debugLabel: debugLabel)
    }

    private func cacheResolvedDataURL(_ dataURL: String?, forCacheKey cacheKey: String, debugLabel: String? = nil) {
        if let dataURL {
            cache[cacheKey] = .dataURL(dataURL)
            removeDiskMissingCache(forCacheKey: cacheKey)
            writeDiskCache(dataURL: dataURL, forCacheKey: cacheKey, debugLabel: debugLabel)
        } else {
            let cachedAt = Date()
            cache[cacheKey] = .missing(cachedAt)
            writeDiskMissingCache(cachedAt: cachedAt, forCacheKey: cacheKey, debugLabel: debugLabel)
        }
    }

    private func writeDiskCache(dataURL: String, forDomain domain: String, debugLabel: String? = nil) {
        writeDiskCache(dataURL: dataURL, forCacheKey: domain, debugLabel: debugLabel)
    }

    private func writeDiskCache(dataURL: String, forCacheKey cacheKey: String, debugLabel: String? = nil) {
        guard let data = Self.imageData(fromDataURL: dataURL) else {
            Self.debugLog(debugLabel, "disk write skipped, invalid data url key=\(cacheKey)")
            return
        }
        let url = diskCacheURL(forCacheKey: cacheKey)
        do {
            try data.write(to: url, options: [.atomic])
            Self.debugLog(debugLabel, "disk write ok key=\(cacheKey) path=\(url.path) bytes=\(data.count)")
        } catch {
            Self.debugLog(debugLabel, "disk write failed key=\(cacheKey) path=\(url.path) error=\(error.localizedDescription)")
        }
    }

    private func diskCachedMissingDate(forCacheKey cacheKey: String) -> Date? {
        let url = diskMissingCacheURL(forCacheKey: cacheKey)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(MissingDiskCacheEntry.self, from: data)
        else {
            return nil
        }
        return entry.cachedAt
    }

    private func writeDiskMissingCache(cachedAt: Date, forCacheKey cacheKey: String, debugLabel: String? = nil) {
        let url = diskMissingCacheURL(forCacheKey: cacheKey)
        do {
            let data = try JSONEncoder().encode(MissingDiskCacheEntry(cachedAt: cachedAt))
            try data.write(to: url, options: [.atomic])
            Self.debugLog(debugLabel, "missing disk write ok key=\(cacheKey) path=\(url.path)")
        } catch {
            Self.debugLog(debugLabel, "missing disk write failed key=\(cacheKey) path=\(url.path) error=\(error.localizedDescription)")
        }
    }

    private func removeDiskMissingCache(forCacheKey cacheKey: String) {
        try? FileManager.default.removeItem(at: diskMissingCacheURL(forCacheKey: cacheKey))
    }

    private func diskCacheURL(forDomain domain: String) -> URL {
        diskCacheURL(forCacheKey: domain)
    }

    private func diskCacheURL(forCacheKey cacheKey: String) -> URL {
        diskCacheURL(forCacheKey: cacheKey, fileExtension: "png")
    }

    private func diskMissingCacheURL(forCacheKey cacheKey: String) -> URL {
        diskCacheURL(forCacheKey: cacheKey, fileExtension: "missing.json")
    }

    private func diskCacheURL(forCacheKey cacheKey: String, fileExtension pathExtension: String) -> URL {
        let safeName = cacheKey.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return diskCacheDirectory.appendingPathComponent("v1-\(String(safeName)).\(pathExtension)")
    }

    private static func directoryStats(at directory: URL) -> CacheStats {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CacheStats(itemCount: 0, byteSize: 0)
        }

        var itemCount = 0
        var byteSize: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            itemCount += 1
            byteSize += Int64(values?.fileSize ?? 0)
        }
        return CacheStats(itemCount: itemCount, byteSize: byteSize)
    }

    private static func normalizedEmailAddress(_ emailAddress: String) -> String? {
        let cleaned = emailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        guard cleaned.contains("@") else { return nil }
        return cleaned
    }

    private static func domain(fromEmailAddress emailAddress: String) -> String? {
        let cleaned = emailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
        guard let atIndex = cleaned.lastIndex(of: "@") else { return nil }
        let domain = String(cleaned[cleaned.index(after: atIndex)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard domain.contains("."),
              domain.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
        else {
            return nil
        }
        return domain
    }

    private static func gravatarHash(forEmailAddress emailAddress: String) -> String {
        let digest = SHA256.hash(data: Data(emailAddress.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func gravatarCacheKey(forEmailAddress emailAddress: String) -> String {
        "gravatar-\(gravatarHash(forEmailAddress: emailAddress))"
    }

    private static func avatarCacheKeys(
        primaryEmailAddress: String?,
        emailAddresses: [String]
    ) -> [String] {
        let normalizedAddresses = uniqueValues(
            [primaryEmailAddress].compactMap { $0 } + emailAddresses
        )
        let addressDomains = normalizedAddresses.compactMap { address -> (address: String, domain: String)? in
            guard let normalizedAddress = normalizedEmailAddress(address),
                  let domain = domain(fromEmailAddress: normalizedAddress)
            else {
                return nil
            }
            return (normalizedAddress, domain)
        }

        let organizationDomains = uniqueValues(
            addressDomains
                .map(\.domain)
                .filter { !isPersonalMailboxDomain($0) }
                .flatMap { domain in
                    let rootDomain = registrableDomain(domain)
                    return rootDomain == domain ? [rootDomain] : [rootDomain, domain]
                }
        )
        let gravatarKeys = addressDomains
            .filter { isPersonalMailboxDomain($0.domain) }
            .map { gravatarCacheKey(forEmailAddress: $0.address) }

        return organizationDomains + gravatarKeys
    }

    private static func isPersonalMailboxDomain(_ domain: String) -> Bool {
        var candidate = domain
        while true {
            if personalMailboxDomains.contains(candidate) {
                return true
            }
            guard let dotIndex = candidate.firstIndex(of: ".") else {
                return false
            }
            candidate = String(candidate[candidate.index(after: dotIndex)...])
        }
    }

    private static func simpleIcon(forDomain domain: String) -> SimpleIcon? {
        var candidate = domain
        while true {
            if let icon = simpleIconsByDomain[candidate] {
                return icon
            }
            guard let dotIndex = candidate.firstIndex(of: ".") else {
                return nil
            }
            candidate = String(candidate[candidate.index(after: dotIndex)...])
        }
    }

    private static func registrableDomain(_ domain: String) -> String {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return domain }
        let suffix = labels.suffix(2).joined(separator: ".")
        if compoundPublicSuffixes.contains(suffix), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    private static func uniqueValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty,
                  seen.insert(normalized).inserted
            else {
                return nil
            }
            return normalized
        }
    }

    private static let personalMailboxDomains: Set<String> = [
        "126.com",
        "163.com",
        "aol.com",
        "fastmail.com",
        "gmail.com",
        "gmx.com",
        "gmx.de",
        "googlemail.com",
        "hey.com",
        "hotmail.com",
        "icloud.com",
        "live.com",
        "mac.com",
        "mail.com",
        "me.com",
        "msn.com",
        "outlook.com",
        "proton.me",
        "protonmail.com",
        "qq.com",
        "sina.com",
        "web.de",
        "yahoo.co.jp",
        "yahoo.com",
        "yeah.net",
        "yandex.com",
        "zoho.com"
    ]

    private static let compoundPublicSuffixes: Set<String> = [
        "com.cn",
        "net.cn",
        "org.cn",
        "edu.cn",
        "gov.cn",
        "co.uk",
        "com.au",
        "net.au",
        "co.jp",
        "ne.jp",
        "co.kr",
        "com.br",
        "com.sg",
        "com.hk",
        "com.tw"
    ]

    private static func simpleIconAvatarSVGData(svg: String, color: String) -> Data? {
        guard let firstTagEnd = svg.firstIndex(of: ">"),
              let closingRange = svg.range(of: "</svg>", options: [.caseInsensitive, .backwards])
        else {
            return nil
        }

        let inner = String(svg[svg.index(after: firstTagEnd)..<closingRange.lowerBound])
        let content = removeSVGTitle(from: inner)
            .replacingOccurrences(
                of: #"\sfill=(['"]).*?\1"#,
                with: "",
                options: .regularExpression
            )
        let avatarSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
          <circle cx="48" cy="48" r="48" fill="#\(color)"/>
          <g transform="translate(24 24) scale(2)" fill="#ffffff">
            \(content)
          </g>
        </svg>
        """
        return avatarSVG.data(using: .utf8)
    }

    private static func removeSVGTitle(from svg: String) -> String {
        svg.replacingOccurrences(
            of: #"<title\b[^>]*>.*?</title>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func bimiLogoURL(fromTXTRecord record: String) -> URL? {
        let normalized = decodeDNSTXT(record)
        guard normalized.localizedCaseInsensitiveContains("v=BIMI1") else { return nil }

        for field in normalized.split(separator: ";") {
            let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("l=") else { continue }
            let rawURL = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "https"
            else {
                return nil
            }
            return url
        }

        return nil
    }

    private static func decodeDNSTXT(_ value: String) -> String {
        var output = ""
        var isInsideQuote = false
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                if let next = iterator.next() {
                    output.append(next)
                }
                continue
            }
            if character == "\"" {
                isInsideQuote.toggle()
                continue
            }
            if isInsideQuote || !character.isWhitespace {
                output.append(character)
            }
        }
        return output
    }

    private static func iconHREFs(fromHTML html: String) -> [String] {
        guard let linkRegex = try? NSRegularExpression(
            pattern: #"<link\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return linkRegex.matches(in: html, range: nsRange).compactMap { match -> String? in
            guard let linkRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[linkRange])
            guard let rel = attribute(named: "rel", inTag: tag)?.lowercased(),
                  rel.contains("icon")
            else {
                return nil
            }
            return attribute(named: "href", inTag: tag)
        }
    }

    private static func attribute(named name: String, inTag tag: String) -> String? {
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: name))\s*=\s*(['"])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: nsRange),
              match.numberOfRanges >= 3,
              let valueRange = Range(match.range(at: 2), in: tag)
        else {
            return nil
        }
        return String(tag[valueRange])
    }

    private static func imageMIMEType(response: URLResponse, url: URL, data: Data) -> String {
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.hasPrefix("image/") {
            return mimeType
        }

        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "ico":
            return "image/x-icon"
        default:
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                return "image/png"
            }
            if data.starts(with: [0xFF, 0xD8, 0xFF]) {
                return "image/jpeg"
            }
            if data.starts(with: [0x00, 0x00, 0x01, 0x00]) {
                return "image/x-icon"
            }
            return "application/octet-stream"
        }
    }

    @MainActor
    private static func normalizedImageDataURL(data: Data, mimeType: String) -> String? {
        guard mimeType.hasPrefix("image/"),
              let image = NSImage(data: data),
              let pngData = image.mailiaCircularAvatarPNGData()
        else {
            return nil
        }

        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }

    fileprivate static func imageData(fromDataURL dataURL: String) -> Data? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let payload = dataURL[dataURL.index(after: commaIndex)...]
        return Data(base64Encoded: String(payload))
    }

    private static func isSuccessfulHTTPResponse(_ response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(httpResponse.statusCode)
    }

    private static func cacheEntry(for dataURL: String?) -> CacheEntry {
        dataURL.map(CacheEntry.dataURL) ?? .missing(Date())
    }

    private static func isMissingCacheValid(_ cachedAt: Date) -> Bool {
        Date().timeIntervalSince(cachedAt) < missingCacheTTL
    }

    private static func httpStatusCode(_ response: URLResponse) -> String {
        guard let httpResponse = response as? HTTPURLResponse else { return "non-http" }
        return String(httpResponse.statusCode)
    }

    private static func debugLog(_: String?, _: String) {}
}

extension NSImage {
    static func mailiaImage(dataURL: String) -> NSImage? {
        guard let data = EntityBrandAvatarResolver.imageData(fromDataURL: dataURL) else {
            return nil
        }
        return NSImage(data: data)
    }

    func mailiaCircularAvatarPNGData(pixelSize: CGFloat = 96) -> Data? {
        let outputSize = NSSize(width: pixelSize, height: pixelSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize),
            pixelsHigh: Int(pixelSize),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: outputSize).fill()

        let circleRect = NSRect(origin: .zero, size: outputSize)
        let circlePath = NSBezierPath(ovalIn: circleRect)
        circlePath.addClip()
        NSColor.white.setFill()
        circlePath.fill()

        draw(
            in: aspectFitRect(
                sourceSize: size,
                destinationRect: circleRect.insetBy(dx: 0, dy: 0)
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        return bitmap.representation(using: .png, properties: [:])
    }

    private func aspectFitRect(sourceSize: NSSize, destinationRect: NSRect) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return destinationRect
        }

        let scale = min(
            destinationRect.width / sourceSize.width,
            destinationRect.height / sourceSize.height
        )
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return NSRect(
            x: destinationRect.midX - width / 2,
            y: destinationRect.midY - height / 2,
            width: width,
            height: height
        )
    }
}
