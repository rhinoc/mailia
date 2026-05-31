import AppKit
import CryptoKit
import Foundation

actor EntityBrandAvatarResolver {
    private struct SimpleIcon {
        var slug: String
        var color: String
        var packageVersion: String = "16.21.0"
    }

    private static let composeDraftIcon = SimpleIcon(slug: "maildotru", color: "005FF9")
    private static let missingCacheTTL: TimeInterval = 600

    private enum CacheEntry {
        case missing(Date)
        case dataURL(String)
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

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)

        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskCacheDirectory = cachesDirectory
            .appendingPathComponent("Mailia", isDirectory: true)
            .appendingPathComponent("AvatarCache", isDirectory: true)
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

        let organizationDomains = Self.uniqueValues(
            addressDomains
                .map(\.domain)
                .filter { !Self.isPersonalMailboxDomain($0) }
                .flatMap { domain in
                    let rootDomain = Self.registrableDomain(domain)
                    return rootDomain == domain ? [rootDomain] : [rootDomain, domain]
                }
        )
        for domain in organizationDomains {
            if let dataURL = cachedDataURL(forCacheKey: domain) {
                return dataURL
            }
        }

        for addressDomain in addressDomains where Self.isPersonalMailboxDomain(addressDomain.domain) {
            let cacheKey = "gravatar-\(Self.gravatarHash(forEmailAddress: addressDomain.address))"
            if let dataURL = cachedDataURL(forCacheKey: cacheKey) {
                return dataURL
            }
        }

        return nil
    }

    func composeDraftAvatarDataURL() async -> String? {
        await simpleIconAvatarDataURL(icon: Self.composeDraftIcon, cacheKey: "compose-draft-maildotru")
    }

    private func gravatarDataURL(forEmailAddress emailAddress: String) async -> String? {
        let hash = Self.gravatarHash(forEmailAddress: emailAddress)
        let cacheKey = "gravatar-\(hash)"

        if let cached = cache[cacheKey] {
            switch cached {
            case .missing(let cachedAt):
                guard Self.isMissingCacheValid(cachedAt) else {
                    cache[cacheKey] = nil
                    break
                }
                return nil
            case .dataURL(let dataURL):
                return dataURL
            }
        }
        if let diskCached = diskCachedDataURL(forCacheKey: cacheKey) {
            cache[cacheKey] = .dataURL(diskCached)
            return diskCached
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
        cache[cacheKey] = Self.cacheEntry(for: dataURL)
        if let dataURL {
            writeDiskCache(dataURL: dataURL, forCacheKey: cacheKey)
        }
        return dataURL
    }

    private func avatarDataURL(
        forDomain domain: String,
        debugLabel: String? = nil,
        forceRefresh: Bool = false
    ) async -> String? {
        if let cached = cache[domain] {
            switch cached {
            case .missing(let cachedAt):
                if !forceRefresh, Self.isMissingCacheValid(cachedAt) {
                    Self.debugLog(debugLabel, "memory missing domain=\(domain)")
                    return nil
                }
                cache[domain] = nil
            case .dataURL(let dataURL):
                Self.debugLog(debugLabel, "memory hit domain=\(domain) length=\(dataURL.count)")
                return dataURL
            }
        }
        if let diskCached = diskCachedDataURL(forDomain: domain) {
            cache[domain] = .dataURL(diskCached)
            Self.debugLog(debugLabel, "disk hit domain=\(domain) length=\(diskCached.count)")
            return diskCached
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
            cache[domain] = Self.cacheEntry(for: dataURL)
            if let dataURL {
                writeDiskCache(dataURL: dataURL, forDomain: domain, debugLabel: debugLabel)
            }
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
        cache[domain] = Self.cacheEntry(for: dataURL)
        if let dataURL {
            writeDiskCache(dataURL: dataURL, forDomain: domain, debugLabel: debugLabel)
        }
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
        if let cached = cache[cacheKey] {
            switch cached {
            case .missing(let cachedAt):
                if !forceRefresh, Self.isMissingCacheValid(cachedAt) {
                    Self.debugLog(debugLabel, "simple icon memory missing key=\(cacheKey)")
                    return nil
                }
                cache[cacheKey] = nil
            case .dataURL(let dataURL):
                Self.debugLog(debugLabel, "simple icon memory hit key=\(cacheKey) length=\(dataURL.count)")
                return dataURL
            }
        }
        if let diskCached = diskCachedDataURL(forCacheKey: cacheKey) {
            cache[cacheKey] = .dataURL(diskCached)
            Self.debugLog(debugLabel, "simple icon disk hit key=\(cacheKey) length=\(diskCached.count)")
            return diskCached
        }
        if !forceRefresh, let inFlightTask = inFlightTasks[cacheKey] {
            Self.debugLog(debugLabel, "simple icon join in-flight key=\(cacheKey)")
            return await inFlightTask.value
        }

        Self.debugLog(debugLabel, "simple icon resolve key=\(cacheKey) forceRefresh=\(forceRefresh)")
        if forceRefresh {
            let dataURL = await resolveSimpleIconAvatarDataURL(icon: icon, debugLabel: debugLabel)
            cache[cacheKey] = Self.cacheEntry(for: dataURL)
            if let dataURL {
                writeDiskCache(dataURL: dataURL, forCacheKey: cacheKey, debugLabel: debugLabel)
            }
            return dataURL
        }

        let task = Task { [weak self] in
            await self?.resolveSimpleIconAvatarDataURL(icon: icon, debugLabel: debugLabel)
        }
        inFlightTasks[cacheKey] = task
        let dataURL = await task.value
        inFlightTasks[cacheKey] = nil
        cache[cacheKey] = Self.cacheEntry(for: dataURL)
        if let dataURL {
            writeDiskCache(dataURL: dataURL, forCacheKey: cacheKey, debugLabel: debugLabel)
        }
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

    private func diskCacheURL(forDomain domain: String) -> URL {
        diskCacheURL(forCacheKey: domain)
    }

    private func diskCacheURL(forCacheKey cacheKey: String) -> URL {
        let safeName = cacheKey.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return diskCacheDirectory.appendingPathComponent("v1-\(String(safeName)).png")
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

    // Generated from simple-icons 16.21.0 source/guideline domains with domain-to-brand name checks.
    // Legacy entries pin 15.22.0 where the latest package no longer includes a commonly used icon.
    private static let simpleIconsByDomain: [String: SimpleIcon] = [
        "1001tracklists.com": SimpleIcon(slug: "1001tracklists", color: "40AEF0"),
        "1panel.cn": SimpleIcon(slug: "1panel", color: "0854C1"),
        "1password.com": SimpleIcon(slug: "1password", color: "145FE4"),
        "2fas.com": SimpleIcon(slug: "2fas", color: "EC1C24"),
        "2k.com": SimpleIcon(slug: "2k", color: "DD0700"),
        "365datascience.com": SimpleIcon(slug: "365datascience", color: "000C1F"),
        "3m.com": SimpleIcon(slug: "3m", color: "FF0000"),
        "4chan.org": SimpleIcon(slug: "4chan", color: "006600"),
        "4d.com": SimpleIcon(slug: "4d", color: "004088"),
        "500px.com": SimpleIcon(slug: "500px", color: "222222"),
        "99designs.com": SimpleIcon(slug: "99designs", color: "FE5F50"),
        "aa.com": SimpleIcon(slug: "americanairlines", color: "0078D2"),
        "abbvie.com": SimpleIcon(slug: "abbvie", color: "071D49"),
        "abdownloadmanager.com": SimpleIcon(slug: "abdownloadmanager", color: "897BFF"),
        "about.me": SimpleIcon(slug: "aboutdotme", color: "333333"),
        "abstract.com": SimpleIcon(slug: "abstract", color: "191A1B"),
        "abuse.ch": SimpleIcon(slug: "abusedotch", color: "00465B"),
        "academia.edu": SimpleIcon(slug: "academia", color: "41454A"),
        "accenture.com": SimpleIcon(slug: "accenture", color: "A100FF"),
        "accusoft.com": SimpleIcon(slug: "accusoft", color: "A9225C"),
        "accuweather.com": SimpleIcon(slug: "accuweather", color: "FF6600"),
        "acer.com": SimpleIcon(slug: "acer", color: "83B81A"),
        "acm.org": SimpleIcon(slug: "acm", color: "0085CA"),
        "activision.com": SimpleIcon(slug: "activision", color: "000000"),
        "activitypub.rocks": SimpleIcon(slug: "activitypub", color: "F1007E"),
        "acura.com": SimpleIcon(slug: "acura", color: "000000"),
        "adafruit.com": SimpleIcon(slug: "adafruit", color: "000000"),
        "adblockplus.org": SimpleIcon(slug: "adblockplus", color: "C70D2C"),
        "addy.io": SimpleIcon(slug: "addydotio", color: "19216C"),
        "adguard.com": SimpleIcon(slug: "adguard", color: "68BC71"),
        "adidas.com": SimpleIcon(slug: "adidas", color: "000000"),
        "adminer.org": SimpleIcon(slug: "adminer", color: "34567C"),
        "adonisjs.com": SimpleIcon(slug: "adonisjs", color: "5A45FF"),
        "adp.com": SimpleIcon(slug: "adp", color: "D0271D"),
        "adroll.com": SimpleIcon(slug: "adroll", color: "0DBDFF"),
        "adventofcode.com": SimpleIcon(slug: "adventofcode", color: "FFFF66"),
        "adyen.com": SimpleIcon(slug: "adyen", color: "0ABF53"),
        "aeroflot.ru": SimpleIcon(slug: "aeroflot", color: "02458D"),
        "aeromexico.com": SimpleIcon(slug: "aeromexico", color: "0B2343"),
        "afdian.com": SimpleIcon(slug: "afdian", color: "946CE6"),
        "affine.pro": SimpleIcon(slug: "affine", color: "1E96EB"),
        "aframe.io": SimpleIcon(slug: "aframe", color: "EF2D5E"),
        "afterpay.com": SimpleIcon(slug: "afterpay", color: "B2FCE4"),
        "aftership.com": SimpleIcon(slug: "aftership", color: "FF6B2B"),
        "agora.io": SimpleIcon(slug: "agora", color: "099DFD"),
        "ah.nl": SimpleIcon(slug: "albertheijn", color: "04ACE6"),
        "aib.ie": SimpleIcon(slug: "aib", color: "7F2B7B"),
        "airasia.com": SimpleIcon(slug: "airasia", color: "FF0000"),
        "airbnb.com": SimpleIcon(slug: "airbnb", color: "FF5A5F"),
        "airbus.com": SimpleIcon(slug: "airbus", color: "00205B"),
        "airbyte.com": SimpleIcon(slug: "airbyte", color: "615EFF"),
        "aircall.io": SimpleIcon(slug: "aircall", color: "00B388"),
        "aircanada.com": SimpleIcon(slug: "aircanada", color: "F01428"),
        "airchina.com.cn": SimpleIcon(slug: "airchina", color: "E30E17"),
        "airfrance.fr": SimpleIcon(slug: "airfrance", color: "002157"),
        "airindia.com": SimpleIcon(slug: "airindia", color: "DA0E29"),
        "airserbia.com": SimpleIcon(slug: "airserbia", color: "0E203F"),
        "airtable.com": SimpleIcon(slug: "airtable", color: "18BFFF"),
        "airtel.in": SimpleIcon(slug: "airtel", color: "E40000"),
        "airtransat.com": SimpleIcon(slug: "airtransat", color: "172B54"),
        "akamai.com": SimpleIcon(slug: "akamai", color: "0096D6"),
        "akasaair.com": SimpleIcon(slug: "akasaair", color: "FF6300"),
        "akaunting.com": SimpleIcon(slug: "akaunting", color: "6DA252"),
        "akiflow.com": SimpleIcon(slug: "akiflow", color: "AF38F9"),
        "alamy.com": SimpleIcon(slug: "alamy", color: "00FF7B"),
        "alchemy.com": SimpleIcon(slug: "alchemy", color: "0C0C0E"),
        "algolia.com": SimpleIcon(slug: "algolia", color: "003DFF"),
        "algorand.com": SimpleIcon(slug: "algorand", color: "000000"),
        "alipay.com": SimpleIcon(slug: "alipay", color: "1677FF"),
        "allegro.pl": SimpleIcon(slug: "allegro", color: "FF5A00"),
        "alltrails.com": SimpleIcon(slug: "alltrails", color: "142800"),
        "almalinux.org": SimpleIcon(slug: "almalinux", color: "000000"),
        "alpinejs.dev": SimpleIcon(slug: "alpinedotjs", color: "8BC0D0"),
        "alpinelinux.org": SimpleIcon(slug: "alpinelinux", color: "0D597F"),
        "alternativeto.net": SimpleIcon(slug: "alternativeto", color: "0289D5"),
        "alwaysdata.com": SimpleIcon(slug: "alwaysdata", color: "E9568E"),
        "amd.com": SimpleIcon(slug: "amd", color: "ED1C24"),
        "amp.dev": SimpleIcon(slug: "amp", color: "005AF0"),
        "amul.com": SimpleIcon(slug: "amul", color: "ED1D24"),
        "ana.co.jp": SimpleIcon(slug: "ana", color: "13448F"),
        "anaconda.com": SimpleIcon(slug: "anaconda", color: "44A833"),
        "analogue.co": SimpleIcon(slug: "analogue", color: "1A1A1A"),
        "andela.com": SimpleIcon(slug: "andela", color: "173B3F"),
        "android.com": SimpleIcon(slug: "android", color: "3DDC84"),
        "angular.dev": SimpleIcon(slug: "angular", color: "0F0F11"),
        "anichart.net": SimpleIcon(slug: "anichart", color: "41B1EA"),
        "anilist.co": SimpleIcon(slug: "anilist", color: "02A9FF"),
        "animalplanet.com": SimpleIcon(slug: "animalplanet", color: "0073FF"),
        "ankermake.com": SimpleIcon(slug: "ankermake", color: "88F387"),
        "ansible.com": SimpleIcon(slug: "ansible", color: "EE0000"),
        "answer.dev": SimpleIcon(slug: "answer", color: "0033FF"),
        "ansys.com": SimpleIcon(slug: "ansys", color: "FFB71B"),
        "anta.com": SimpleIcon(slug: "anta", color: "D70010"),
        "antena3.com": SimpleIcon(slug: "antena3", color: "FF7328"),
        "anthropic.com": SimpleIcon(slug: "anthropic", color: "191919"),
        "antv.vision": SimpleIcon(slug: "antv", color: "8B5DFF"),
        "anycubic.com": SimpleIcon(slug: "anycubic", color: "476695"),
        "anydesk.com": SimpleIcon(slug: "anydesk", color: "EF443B"),
        "apache.org": SimpleIcon(slug: "apache", color: "D22128"),
        "aparat.com": SimpleIcon(slug: "aparat", color: "ED145B"),
        "apifox.com": SimpleIcon(slug: "apifox", color: "F44A53"),
        "apmterminals.com": SimpleIcon(slug: "apmterminals", color: "FF6441"),
        "apollographql.com": SimpleIcon(slug: "apollographql", color: "311C87"),
        "appian.com": SimpleIcon(slug: "appian", color: "2322F0"),
        "appimage.org": SimpleIcon(slug: "appimage", color: "739FB9"),
        "apple.com": SimpleIcon(slug: "apple", color: "000000"),
        "appsignal.com": SimpleIcon(slug: "appsignal", color: "21375A"),
        "appsmith.com": SimpleIcon(slug: "appsmith", color: "2A2F3D"),
        "appveyor.com": SimpleIcon(slug: "appveyor", color: "00B3E0"),
        "appwrite.io": SimpleIcon(slug: "appwrite", color: "FD366E"),
        "arangodb.com": SimpleIcon(slug: "arangodb", color: "DDDF72"),
        "arc.net": SimpleIcon(slug: "arc", color: "FCBFBD"),
        "archiveofourown.org": SimpleIcon(slug: "archiveofourown", color: "990000"),
        "archlinux.org": SimpleIcon(slug: "archlinux", color: "1793D1"),
        "arduino.cc": SimpleIcon(slug: "arduino", color: "00878F"),
        "argos.co.uk": SimpleIcon(slug: "argos", color: "DA291C"),
        "arlo.com": SimpleIcon(slug: "arlo", color: "49B48A"),
        "arm.com": SimpleIcon(slug: "arm", color: "0091BD"),
        "arstechnica.com": SimpleIcon(slug: "arstechnica", color: "FF4E00"),
        "artixlinux.org": SimpleIcon(slug: "artixlinux", color: "10A0CC"),
        "artstation.com": SimpleIcon(slug: "artstation", color: "13AFF0"),
        "arxiv.org": SimpleIcon(slug: "arxiv", color: "B31B1B"),
        "asana.com": SimpleIcon(slug: "asana", color: "F06A6A"),
        "asda.com": SimpleIcon(slug: "asda", color: "68A51C"),
        "aseprite.org": SimpleIcon(slug: "aseprite", color: "7D929E"),
        "assemblyscript.org": SimpleIcon(slug: "assemblyscript", color: "007ACC"),
        "astonmartin.com": SimpleIcon(slug: "astonmartin", color: "00665E"),
        "astro.build": SimpleIcon(slug: "astro", color: "BC52EE"),
        "asus.com": SimpleIcon(slug: "asus", color: "000000"),
        "atlasos.net": SimpleIcon(slug: "atlasos", color: "1A91FF"),
        "atlassian.com": SimpleIcon(slug: "atlassian", color: "0052CC"),
        "atlassian.design": SimpleIcon(slug: "atlassian", color: "0052CC"),
        "att.com": SimpleIcon(slug: "atandt", color: "009FDB"),
        "auchan.fr": SimpleIcon(slug: "auchan", color: "D6180B"),
        "audi.com": SimpleIcon(slug: "audi", color: "BB0A30"),
        "audioboom.com": SimpleIcon(slug: "audioboom", color: "007CE2"),
        "audiomack.com": SimpleIcon(slug: "audiomack", color: "FFA200"),
        "aurelia.io": SimpleIcon(slug: "aurelia", color: "ED2B88"),
        "autentique.com.br": SimpleIcon(slug: "autentique", color: "3379F2"),
        "auth0.com": SimpleIcon(slug: "auth0", color: "EB5424"),
        "authelia.com": SimpleIcon(slug: "authelia", color: "113155"),
        "autodesk.com": SimpleIcon(slug: "autodesk", color: "000000"),
        "autohotkey.com": SimpleIcon(slug: "autohotkey", color: "334455"),
        "automattic.com": SimpleIcon(slug: "automattic", color: "3499CD"),
        "autozone.com": SimpleIcon(slug: "autozone", color: "D52B1E"),
        "avaloniaui.net": SimpleIcon(slug: "avaloniaui", color: "165BFF"),
        "avast.com": SimpleIcon(slug: "avast", color: "FF7800"),
        "avianca.com": SimpleIcon(slug: "avianca", color: "FF0000"),
        "avira.com": SimpleIcon(slug: "avira", color: "E02027"),
        "avm.de": SimpleIcon(slug: "avm", color: "E2001A"),
        "awesomewm.org": SimpleIcon(slug: "awesomewm", color: "535D6C"),
        "awwwards.com": SimpleIcon(slug: "awwwards", color: "222222"),
        "axisbank.com": SimpleIcon(slug: "axisbank", color: "971A4D"),
        "b4x.com": SimpleIcon(slug: "b4x", color: "14AECB"),
        "babelio.com": SimpleIcon(slug: "babelio", color: "FBB91E"),
        "backblaze.com": SimpleIcon(slug: "backblaze", color: "E21E29"),
        "backbone.com": SimpleIcon(slug: "backbone", color: "000000"),
        "backendless.com": SimpleIcon(slug: "backendless", color: "1D77BD"),
        "backstage.com": SimpleIcon(slug: "backstage_casting", color: "000000"),
        "backstage.io": SimpleIcon(slug: "backstage", color: "9BF0E1"),
        "badoo.com": SimpleIcon(slug: "badoo", color: "783BF9"),
        "baidu.com": SimpleIcon(slug: "baidu", color: "2932E1"),
        "bakalari.cz": SimpleIcon(slug: "bakalari", color: "00A2E2"),
        "bambulab.com": SimpleIcon(slug: "bambulab", color: "00AE42"),
        "bandcamp.com": SimpleIcon(slug: "bandcamp", color: "408294"),
        "bandlab.com": SimpleIcon(slug: "bandlab", color: "F12C18"),
        "bandsintown.com": SimpleIcon(slug: "bandsintown", color: "00CEC8"),
        "bankofamerica.com": SimpleIcon(slug: "bankofamerica", color: "012169"),
        "baremetrics.com": SimpleIcon(slug: "baremetrics", color: "6078FF"),
        "barmenia.de": SimpleIcon(slug: "barmenia", color: "009FE3"),
        "base-ui.com": SimpleIcon(slug: "baseui", color: "EDEDED"),
        "basecamp.com": SimpleIcon(slug: "basecamp", color: "1D2D35"),
        "baserow.io": SimpleIcon(slug: "baserow", color: "5190EF"),
        "bata.com": SimpleIcon(slug: "bata", color: "DD282E"),
        "battle.net": SimpleIcon(slug: "battledotnet", color: "4381C3"),
        "bazel.build": SimpleIcon(slug: "bazel", color: "43A047"),
        "beatport.com": SimpleIcon(slug: "beatport", color: "01FF95"),
        "beatsbydre.com": SimpleIcon(slug: "beatsbydre", color: "E01F3D"),
        "beatstars.world": SimpleIcon(slug: "beatstars", color: "EB0000"),
        "beekeeperstudio.io": SimpleIcon(slug: "beekeeperstudio", color: "FAD83B"),
        "behance.net": SimpleIcon(slug: "behance", color: "1769FF"),
        "bem.info": SimpleIcon(slug: "bem", color: "000000"),
        "bento.me": SimpleIcon(slug: "bento", color: "768CFF"),
        "bereal.com": SimpleIcon(slug: "bereal", color: "000000"),
        "betfair.com": SimpleIcon(slug: "betfair", color: "FFB80B"),
        "betterstack.com": SimpleIcon(slug: "betterstack", color: "000000"),
        "bigbasket.com": SimpleIcon(slug: "bigbasket", color: "A5CD39"),
        "bigbluebutton.org": SimpleIcon(slug: "bigbluebutton", color: "283274"),
        "bigcartel.com": SimpleIcon(slug: "bigcartel", color: "222222"),
        "bigcommerce.co.uk": SimpleIcon(slug: "bigcommerce", color: "121118"),
        "bilibili.com": SimpleIcon(slug: "bilibili", color: "00A1D6"),
        "billboard.com": SimpleIcon(slug: "billboard", color: "000000"),
        "binance.com": SimpleIcon(slug: "binance", color: "F0B90B"),
        "bioconductor.org": SimpleIcon(slug: "bioconductor", color: "1A81C2"),
        "bisecthosting.com": SimpleIcon(slug: "bisecthosting", color: "0D1129"),
        "bit.dev": SimpleIcon(slug: "bit", color: "592EC1"),
        "bitbucket.org": SimpleIcon(slug: "bitbucket", color: "0052CC"),
        "bitcoin.org": SimpleIcon(slug: "bitcoin", color: "F7931A"),
        "bitcoincash.org": SimpleIcon(slug: "bitcoincash", color: "0AC18E"),
        "bitcoinsv.com": SimpleIcon(slug: "bitcoinsv", color: "EAB300"),
        "bitdefender.com": SimpleIcon(slug: "bitdefender", color: "ED1C24"),
        "bitly.com": SimpleIcon(slug: "bitly", color: "EE6123"),
        "bitrise.io": SimpleIcon(slug: "bitrise", color: "683D87"),
        "bitsy.org": SimpleIcon(slug: "bitsy", color: "6767B2"),
        "bittorrent.com": SimpleIcon(slug: "bittorrent", color: "050505"),
        "bitwarden.com": SimpleIcon(slug: "bitwarden", color: "175DDC"),
        "bitwig.com": SimpleIcon(slug: "bitwig", color: "FF5A00"),
        "bk.com": SimpleIcon(slug: "burgerking", color: "D62300"),
        "blackberry.com": SimpleIcon(slug: "blackberry", color: "000000"),
        "blackmagicdesign.com": SimpleIcon(slug: "blackmagicdesign", color: "FFA200"),
        "blazemeter.com": SimpleIcon(slug: "blazemeter", color: "CA2133"),
        "blender.org": SimpleIcon(slug: "blender", color: "E87D0D"),
        "blibli.com": SimpleIcon(slug: "blibli", color: "0072FF"),
        "blockbench.net": SimpleIcon(slug: "blockbench", color: "1E93D9"),
        "blockchain.com": SimpleIcon(slug: "blockchaindotcom", color: "121D33"),
        "blogger.com": SimpleIcon(slug: "blogger", color: "FF5722"),
        "bloglovin.com": SimpleIcon(slug: "bloglovin", color: "000000"),
        "bluesound.com": SimpleIcon(slug: "bluesound", color: "0F131E"),
        "bluetooth.com": SimpleIcon(slug: "bluetooth", color: "0082FC"),
        "bmw.com": SimpleIcon(slug: "bmw", color: "0066B1"),
        "bnbchain.org": SimpleIcon(slug: "bnbchain", color: "F0B90B"),
        "boardgamegeek.com": SimpleIcon(slug: "boardgamegeek", color: "FF5100"),
        "boehringer-ingelheim.com": SimpleIcon(slug: "boehringeringelheim", color: "00E47C"),
        "bombardier.com": SimpleIcon(slug: "bombardier", color: "000000"),
        "bookalope.net": SimpleIcon(slug: "bookalope", color: "DC2829"),
        "bookbub.com": SimpleIcon(slug: "bookbub", color: "F44336"),
        "bookmeter.com": SimpleIcon(slug: "bookmeter", color: "64BC4B"),
        "bookmyshow.com": SimpleIcon(slug: "bookmyshow", color: "C4242B"),
        "boosty.to": SimpleIcon(slug: "boosty", color: "F15F2C"),
        "borgbackup.org": SimpleIcon(slug: "borgbackup", color: "00DD00"),
        "bosch.de": SimpleIcon(slug: "bosch", color: "EA0016"),
        "bose.com": SimpleIcon(slug: "bose", color: "000000"),
        "boulanger.com": SimpleIcon(slug: "boulanger", color: "FD5300"),
        "bower.io": SimpleIcon(slug: "bower", color: "EF5734"),
        "box.com": SimpleIcon(slug: "box", color: "0061D5"),
        "boxy-svg.com": SimpleIcon(slug: "boxysvg", color: "3584E3"),
        "br-automation.com": SimpleIcon(slug: "bandrautomation", color: "FF8800"),
        "brandfetch.com": SimpleIcon(slug: "brandfetch", color: "0084FF"),
        "brandfolder.com": SimpleIcon(slug: "brandfolder", color: "40D1F5"),
        "brave.com": SimpleIcon(slug: "brave", color: "FB542B"),
        "breaker.audio": SimpleIcon(slug: "breaker", color: "003DAD"),
        "brenntag.com": SimpleIcon(slug: "brenntag", color: "1A0033"),
        "brevo.com": SimpleIcon(slug: "brevo", color: "0B996E"),
        "brex.com": SimpleIcon(slug: "brex", color: "212121"),
        "britishairways.com": SimpleIcon(slug: "britishairways", color: "2E5C99"),
        "broadcom.com": SimpleIcon(slug: "broadcom", color: "E31837"),
        "bt.com": SimpleIcon(slug: "bt", color: "6400AA"),
        "buddy.works": SimpleIcon(slug: "buddy", color: "1A86FD"),
        "buffer.com": SimpleIcon(slug: "buffer", color: "231F20"),
        "bugatti.com": SimpleIcon(slug: "bugatti", color: "000000"),
        "bugcrowd.com": SimpleIcon(slug: "bugcrowd", color: "F26822"),
        "buhl.de": SimpleIcon(slug: "buhl", color: "023E84"),
        "buildkite.com": SimpleIcon(slug: "buildkite", color: "14CC80"),
        "builtbybit.com": SimpleIcon(slug: "builtbybit", color: "2D87C3"),
        "bukalapak.com": SimpleIcon(slug: "bukalapak", color: "E31E52"),
        "bukalapak.design": SimpleIcon(slug: "bukalapak", color: "E31E52"),
        "bulma.io": SimpleIcon(slug: "bulma", color: "00D1B2"),
        "bun.sh": SimpleIcon(slug: "bun", color: "000000"),
        "bungie.net": SimpleIcon(slug: "bungie", color: "0075BB"),
        "bunny.net": SimpleIcon(slug: "bunnydotnet", color: "FFAA49"),
        "bunq.com": SimpleIcon(slug: "bunq", color: "3394D7"),
        "burton.com": SimpleIcon(slug: "burton", color: "000000"),
        "buymeacoffee.com": SimpleIcon(slug: "buymeacoffee", color: "FFDD00"),
        "buysellads.com": SimpleIcon(slug: "buysellads", color: "EB4714"),
        "buzzfeed.com": SimpleIcon(slug: "buzzfeed", color: "EE3322"),
        "bvg.de": SimpleIcon(slug: "bvg", color: "F0D722"),
        "byjus.com": SimpleIcon(slug: "byjus", color: "813588"),
        "bytedance.com": SimpleIcon(slug: "bytedance", color: "3C8CFF"),
        "cadillac.com": SimpleIcon(slug: "cadillac", color: "000000"),
        "caixabank.es": SimpleIcon(slug: "caixabank", color: "007EAE"),
        "cakephp.org": SimpleIcon(slug: "cakephp", color: "D33C43"),
        "cal.com": SimpleIcon(slug: "caldotcom", color: "292929"),
        "calendly.com": SimpleIcon(slug: "calendly", color: "006BFF"),
        "campaignmonitor.com": SimpleIcon(slug: "campaignmonitor", color: "111324"),
        "camunda.com": SimpleIcon(slug: "camunda", color: "FC5D0D"),
        "cardano.org": SimpleIcon(slug: "cardano", color: "0133AD"),
        "carlsberggroup.com": SimpleIcon(slug: "carlsberggroup", color: "00321E"),
        "carrd.co": SimpleIcon(slug: "carrd", color: "596CAF"),
        "carthrottle.com": SimpleIcon(slug: "carthrottle", color: "FF9C42"),
        "carto.com": SimpleIcon(slug: "carto", color: "EB1510"),
        "castbox.fm": SimpleIcon(slug: "castbox", color: "F55B23"),
        "castorama.fr": SimpleIcon(slug: "castorama", color: "0078D7"),
        "cbc.ca": SimpleIcon(slug: "cbc", color: "E60505"),
        "cbs.com": SimpleIcon(slug: "cbs", color: "033963"),
        "ccleaner.com": SimpleIcon(slug: "ccleaner", color: "CB2D29"),
        "cdprojekt.com": SimpleIcon(slug: "cdprojekt", color: "DC0D15"),
        "celestron.com": SimpleIcon(slug: "celestron", color: "F47216"),
        "centos.org": SimpleIcon(slug: "centos", color: "262577"),
        "cesium.com": SimpleIcon(slug: "cesium", color: "6CADDF"),
        "chainguard.dev": SimpleIcon(slug: "chainguard", color: "4445E7"),
        "changedetection.io": SimpleIcon(slug: "changedetection", color: "3056D3"),
        "channel4.com": SimpleIcon(slug: "channel4", color: "AAFF89"),
        "chartjs.org": SimpleIcon(slug: "chartdotjs", color: "FF6384"),
        "chartmogul.com": SimpleIcon(slug: "chartmogul", color: "13324B"),
        "chatbot.design": SimpleIcon(slug: "chatbot", color: "0066FF"),
        "chatwoot.com": SimpleIcon(slug: "chatwoot", color: "1F93FF"),
        "checkio.org": SimpleIcon(slug: "checkio", color: "008DB6"),
        "checkmarx.com": SimpleIcon(slug: "checkmarx", color: "54B848"),
        "checkmk.com": SimpleIcon(slug: "checkmk", color: "15D1A0"),
        "chedraui.com.mx": SimpleIcon(slug: "chedraui", color: "E0832F"),
        "chef.io": SimpleIcon(slug: "chef", color: "F09820"),
        "chess.com": SimpleIcon(slug: "chessdotcom", color: "81B64C"),
        "chevrolet.com": SimpleIcon(slug: "chevrolet", color: "CD9834"),
        "chocolatey.org": SimpleIcon(slug: "chocolatey", color: "80B5E3"),
        "chromatic.com": SimpleIcon(slug: "chromatic", color: "FC521F"),
        "chupachups.co.uk": SimpleIcon(slug: "chupachups", color: "CF103E"),
        "cinny.in": SimpleIcon(slug: "cinny", color: "000000"),
        "circle.com": SimpleIcon(slug: "circle", color: "8669AE"),
        "circleci.com": SimpleIcon(slug: "circleci", color: "343434"),
        "circuitverse.org": SimpleIcon(slug: "circuitverse", color: "42B883"),
        "cirrus-ci.org": SimpleIcon(slug: "cirrusci", color: "4051B5"),
        "cisco.com": SimpleIcon(slug: "cisco", color: "1BA0D7"),
        "citrix.com": SimpleIcon(slug: "citrix", color: "452170"),
        "civicrm.org": SimpleIcon(slug: "civicrm", color: "81C459"),
        "civo.com": SimpleIcon(slug: "civo", color: "239DFF"),
        "clarifai.com": SimpleIcon(slug: "clarifai", color: "1955FF"),
        "claris.com": SimpleIcon(slug: "claris", color: "000000"),
        "clarivate.com": SimpleIcon(slug: "clarivate", color: "93FF9E"),
        "claude.ai": SimpleIcon(slug: "claude", color: "D97757"),
        "clerk.com": SimpleIcon(slug: "clerk", color: "6C47FF"),
        "clever-cloud.com": SimpleIcon(slug: "clevercloud", color: "171C36"),
        "clickup.com": SimpleIcon(slug: "clickup", color: "7B68EE"),
        "cline.bot": SimpleIcon(slug: "cline", color: "18181B"),
        "clockify.me": SimpleIcon(slug: "clockify", color: "03A9F4"),
        "cloud66.com": SimpleIcon(slug: "cloud66", color: "3C72B9"),
        "cloudbees.com": SimpleIcon(slug: "cloudbees", color: "1997B5"),
        "cloudcannon.com": SimpleIcon(slug: "cloudcannon", color: "407AFC"),
        "cloudera.com": SimpleIcon(slug: "cloudera", color: "F96702"),
        "cloudflare.com": SimpleIcon(slug: "cloudflare", color: "F38020"),
        "cloudfoundry.org": SimpleIcon(slug: "cloudfoundry", color: "0C9ED5"),
        "cloudinary.com": SimpleIcon(slug: "cloudinary", color: "3448C5"),
        "cloudron.io": SimpleIcon(slug: "cloudron", color: "03A9F4"),
        "cloudsmith.com": SimpleIcon(slug: "cloudsmith", color: "2A6FE1"),
        "cloudways.com": SimpleIcon(slug: "cloudways", color: "2C39BD"),
        "clubforce.com": SimpleIcon(slug: "clubforce", color: "191176"),
        "clubhouse.com": SimpleIcon(slug: "clubhouse", color: "FFE450"),
        "clyp.it": SimpleIcon(slug: "clyp", color: "3CBDB1"),
        "cnb.cool": SimpleIcon(slug: "cloudnativebuild", color: "F76945"),
        "cncf.io": SimpleIcon(slug: "cncf", color: "231F20"),
        "cnet.com": SimpleIcon(slug: "cnet", color: "E71D1D"),
        "cnn.com": SimpleIcon(slug: "cnn", color: "CC0000"),
        "cobalt.tools": SimpleIcon(slug: "cobalt", color: "FFFFFF"),
        "cockroachlabs.com": SimpleIcon(slug: "cockroachlabs", color: "6933FF"),
        "cocos.com": SimpleIcon(slug: "cocos", color: "55C2E1"),
        "coda.io": SimpleIcon(slug: "coda", color: "F46A54"),
        "codacy.com": SimpleIcon(slug: "codacy", color: "222F29"),
        "codeberg.org": SimpleIcon(slug: "codeberg", color: "2185D0"),
        "codeblocks.org": SimpleIcon(slug: "codeblocks", color: "41AD48"),
        "codecademy.com": SimpleIcon(slug: "codecademy", color: "1F4056"),
        "codechef.com": SimpleIcon(slug: "codechef", color: "5B4638"),
        "codeclimate.com": SimpleIcon(slug: "codeclimate", color: "000000"),
        "codecov.io": SimpleIcon(slug: "codecov", color: "F01F7A"),
        "codefactor.io": SimpleIcon(slug: "codefactor", color: "F44A6A"),
        "codeforces.com": SimpleIcon(slug: "codeforces", color: "1F8ACB"),
        "codefresh.io": SimpleIcon(slug: "codefresh", color: "08B1AB"),
        "codeigniter.com": SimpleIcon(slug: "codeigniter", color: "EF4223"),
        "codemagic.io": SimpleIcon(slug: "codemagic", color: "F45E3F"),
        "codementor.io": SimpleIcon(slug: "codementor", color: "003648"),
        "codenewbie.org": SimpleIcon(slug: "codenewbie", color: "9013FE"),
        "codeproject.com": SimpleIcon(slug: "codeproject", color: "FF9900"),
        "coder.com": SimpleIcon(slug: "coder", color: "090B0B"),
        "coderabbit.ai": SimpleIcon(slug: "coderabbit", color: "FF570A"),
        "codersrank.io": SimpleIcon(slug: "codersrank", color: "67A4AC"),
        "codesandbox.io": SimpleIcon(slug: "codesandbox", color: "151515"),
        "codeship.com": SimpleIcon(slug: "codeship", color: "004466"),
        "codesignal.com": SimpleIcon(slug: "codesignal", color: "1062FB"),
        "codestream.com": SimpleIcon(slug: "codestream", color: "008C99"),
        "codingame.com": SimpleIcon(slug: "codingame", color: "F2BB13"),
        "codingninjas.com": SimpleIcon(slug: "codingninjas", color: "DD6620"),
        "codio.com": SimpleIcon(slug: "codio", color: "4574E0"),
        "coffeescript.org": SimpleIcon(slug: "coffeescript", color: "2F2625"),
        "coggle.it": SimpleIcon(slug: "coggle", color: "9ED56B"),
        "coinbase.com": SimpleIcon(slug: "coinbase", color: "0052FF"),
        "coinmarketcap.com": SimpleIcon(slug: "coinmarketcap", color: "17181B"),
        "collaboraonline.com": SimpleIcon(slug: "collaboraonline", color: "5C2983"),
        "comicfury.com": SimpleIcon(slug: "comicfury", color: "79BD42"),
        "comma.ai": SimpleIcon(slug: "comma", color: "51FF00"),
        "commodore.inc": SimpleIcon(slug: "commodore", color: "1E2A4E"),
        "comptia.org": SimpleIcon(slug: "comptia", color: "C8202F"),
        "comsol.com": SimpleIcon(slug: "comsol", color: "368CCB"),
        "conan.io": SimpleIcon(slug: "conan", color: "6699CB"),
        "conekta.com": SimpleIcon(slug: "conekta", color: "0A1837"),
        "contabo.com": SimpleIcon(slug: "contabo", color: "00AAEB"),
        "contao.org": SimpleIcon(slug: "contao", color: "F47C00"),
        "contentful.com": SimpleIcon(slug: "contentful", color: "2478CC"),
        "contentstack.com": SimpleIcon(slug: "contentstack", color: "E74C3D"),
        "continente.pt": SimpleIcon(slug: "continente", color: "E31E24"),
        "contributor-covenant.org": SimpleIcon(slug: "contributorcovenant", color: "5E0D73"),
        "conventionalcommits.org": SimpleIcon(slug: "conventionalcommits", color: "FE5196"),
        "convertio.co": SimpleIcon(slug: "convertio", color: "FF3333"),
        "convex.dev": SimpleIcon(slug: "convex", color: "EE342F"),
        "coolermaster.com": SimpleIcon(slug: "coolermaster", color: "1E1E28"),
        "coppel.com": SimpleIcon(slug: "coppel", color: "0266AE"),
        "cora.fr": SimpleIcon(slug: "cora", color: "E61845"),
        "coreboot.org": SimpleIcon(slug: "coreboot", color: "000000"),
        "coreldraw.com": SimpleIcon(slug: "coreldraw", color: "000000"),
        "corona-renderer.com": SimpleIcon(slug: "coronarenderer", color: "E6502A"),
        "corsair.com": SimpleIcon(slug: "corsair", color: "231F20"),
        "couchbase.com": SimpleIcon(slug: "couchbase", color: "EA2328"),
        "counter-strike.net": SimpleIcon(slug: "counterstrike", color: "000000"),
        "coursera.org": SimpleIcon(slug: "coursera", color: "0056D2"),
        "coveralls.io": SimpleIcon(slug: "coveralls", color: "3F5767"),
        "coze.com": SimpleIcon(slug: "coze", color: "4D53E8"),
        "cpanel.net": SimpleIcon(slug: "cpanel", color: "FF6C2C"),
        "craftcms.com": SimpleIcon(slug: "craftcms", color: "E5422B"),
        "craftsman.com": SimpleIcon(slug: "craftsman", color: "D6001C"),
        "crayon.com": SimpleIcon(slug: "crayon", color: "FF6A4C"),
        "creality.com": SimpleIcon(slug: "creality", color: "000000"),
        "creativecommons.org": SimpleIcon(slug: "creativecommons", color: "ED592F"),
        "credly.com": SimpleIcon(slug: "credly", color: "FF6B00"),
        "crehana.com": SimpleIcon(slug: "crehana", color: "4B22F4"),
        "crew-united.com": SimpleIcon(slug: "crewunited", color: "000000"),
        "crowdin.com": SimpleIcon(slug: "crowdin", color: "2E3340"),
        "crunchbase.com": SimpleIcon(slug: "crunchbase", color: "0288D1"),
        "crunchyroll.com": SimpleIcon(slug: "crunchyroll", color: "FF5E00"),
        "cryengine.com": SimpleIcon(slug: "cryengine", color: "000000"),
        "cryptpad.org": SimpleIcon(slug: "cryptpad", color: "0087FF"),
        "csdn.net": SimpleIcon(slug: "csdn", color: "FC5531"),
        "cssdesignawards.com": SimpleIcon(slug: "cssdesignawards", color: "280FEE"),
        "csswizardry.com": SimpleIcon(slug: "csswizardry", color: "F43059"),
        "cucumber.io": SimpleIcon(slug: "cucumber", color: "23D96C"),
        "cultura.com": SimpleIcon(slug: "cultura", color: "1D2C54"),
        "curseforge.com": SimpleIcon(slug: "curseforge", color: "F16436"),
        "cursor.com": SimpleIcon(slug: "cursor", color: "000000"),
        "customink.com": SimpleIcon(slug: "customink", color: "FA3C00"),
        "cyberdefenders.org": SimpleIcon(slug: "cyberdefenders", color: "335EEA"),
        "cycling74.com": SimpleIcon(slug: "cycling74", color: "111111"),
        "cypress.io": SimpleIcon(slug: "cypress", color: "69D3A7"),
        "daf.com": SimpleIcon(slug: "daf", color: "00529B"),
        "daily.dev": SimpleIcon(slug: "dailydotdev", color: "CE3DF3"),
        "dailymotion.com": SimpleIcon(slug: "dailymotion", color: "0A0A0A"),
        "daisyui.com": SimpleIcon(slug: "daisyui", color: "FFC63A"),
        "darty.com": SimpleIcon(slug: "darty", color: "EB1B23"),
        "dash.org": SimpleIcon(slug: "dash", color: "008DE4"),
        "dash0.com": SimpleIcon(slug: "dash0", color: "EA3D3B"),
        "data.ai": SimpleIcon(slug: "datadotai", color: "000000"),
        "databricks.com": SimpleIcon(slug: "databricks", color: "FF3621"),
        "datacamp.com": SimpleIcon(slug: "datacamp", color: "03EF62"),
        "dataiku.com": SimpleIcon(slug: "dataiku", color: "2AB1AC"),
        "datastax.com": SimpleIcon(slug: "datastax", color: "000000"),
        "date-fns.org": SimpleIcon(slug: "datefns", color: "770C56"),
        "datocms.com": SimpleIcon(slug: "datocms", color: "FF7751"),
        "datto.com": SimpleIcon(slug: "datto", color: "199ED9"),
        "dazn.com": SimpleIcon(slug: "dazn", color: "F8F8F5"),
        "db.com": SimpleIcon(slug: "deutschebank", color: "0018A8"),
        "dbeaver.com": SimpleIcon(slug: "dbeaver", color: "382923"),
        "dblp.org": SimpleIcon(slug: "dblp", color: "004F9F"),
        "debian.org": SimpleIcon(slug: "debian", color: "A81D33"),
        "debrid-link.com": SimpleIcon(slug: "debridlink", color: "264E70"),
        "decentraland.org": SimpleIcon(slug: "decentraland", color: "FF2D55"),
        "deepcool.com": SimpleIcon(slug: "deepcool", color: "068584"),
        "deepgram.com": SimpleIcon(slug: "deepgram", color: "13EF93"),
        "deepl.com": SimpleIcon(slug: "deepl", color: "0F2B46"),
        "deepmind.google": SimpleIcon(slug: "deepmind", color: "4285F4"),
        "deepnote.com": SimpleIcon(slug: "deepnote", color: "3793EF"),
        "deepseek.com": SimpleIcon(slug: "deepseek", color: "5786FE"),
        "deliveroo.com": SimpleIcon(slug: "deliveroo", color: "00CCBC"),
        "dell.com": SimpleIcon(slug: "dell", color: "007DB8"),
        "delonghi.com": SimpleIcon(slug: "delonghi", color: "072240"),
        "delta.com": SimpleIcon(slug: "delta", color: "003366"),
        "deno.com": SimpleIcon(slug: "deno", color: "000000"),
        "denon.com": SimpleIcon(slug: "denon", color: "0B131A"),
        "dependabot.com": SimpleIcon(slug: "dependabot", color: "025E8C"),
        "depositphotos.com": SimpleIcon(slug: "depositphotos", color: "000000"),
        "deutschepost.de": SimpleIcon(slug: "deutschepost", color: "FFCC00"),
        "dev.to": SimpleIcon(slug: "devdotto", color: "0A0A0A"),
        "devexpress.com": SimpleIcon(slug: "devexpress", color: "FF7200"),
        "deviantart.com": SimpleIcon(slug: "deviantart", color: "05CC47"),
        "devrant.com": SimpleIcon(slug: "devrant", color: "F99A66"),
        "devuan.org": SimpleIcon(slug: "devuan", color: "004489"),
        "dgraph.io": SimpleIcon(slug: "dgraph", color: "E50695"),
        "dictionary.com": SimpleIcon(slug: "dictionarydotcom", color: "0049D7"),
        "dify.ai": SimpleIcon(slug: "dify", color: "0033FF"),
        "digg.com": SimpleIcon(slug: "digg", color: "000000"),
        "digitalocean.com": SimpleIcon(slug: "digitalocean", color: "0080FF"),
        "dinersclub.com": SimpleIcon(slug: "dinersclub", color: "004C97"),
        "dior.com": SimpleIcon(slug: "dior", color: "000000"),
        "directus.io": SimpleIcon(slug: "directus", color: "263238"),
        "discogs.com": SimpleIcon(slug: "discogs", color: "333333"),
        "discord.com": SimpleIcon(slug: "discord", color: "5865F2"),
        "discourse.org": SimpleIcon(slug: "discourse", color: "000000"),
        "disqus.com": SimpleIcon(slug: "disqus", color: "2E9FFF"),
        "disroot.org": SimpleIcon(slug: "disroot", color: "50162D"),
        "distrokid.com": SimpleIcon(slug: "distrokid", color: "231F20"),
        "dji.com": SimpleIcon(slug: "dji", color: "000000"),
        "dm.de": SimpleIcon(slug: "dm", color: "002878"),
        "docker.com": SimpleIcon(slug: "docker", color: "2496ED"),
        "docs.rs": SimpleIcon(slug: "docsdotrs", color: "000000"),
        "dodopayments.com": SimpleIcon(slug: "dodopayments", color: "C6FE1E"),
        "doi.org": SimpleIcon(slug: "doi", color: "FAB70C"),
        "dolby.com": SimpleIcon(slug: "dolby", color: "000000"),
        "doordash.com": SimpleIcon(slug: "doordash", color: "FF3008"),
        "douban.com": SimpleIcon(slug: "douban", color: "2D963D"),
        "dovetail.com": SimpleIcon(slug: "dovetail", color: "190041"),
        "downdetector.com": SimpleIcon(slug: "downdetector", color: "FF160A"),
        "dpd.com": SimpleIcon(slug: "dpd", color: "DC0032"),
        "dragonframe.com": SimpleIcon(slug: "dragonframe", color: "D4911E"),
        "dreamstime.com": SimpleIcon(slug: "dreamstime", color: "50A901"),
        "dribbble.com": SimpleIcon(slug: "dribbble", color: "EA4C89"),
        "drizzle.team": SimpleIcon(slug: "drizzle", color: "C5F74F"),
        "drooble.com": SimpleIcon(slug: "drooble", color: "19C4BE"),
        "dropbox.com": SimpleIcon(slug: "dropbox", color: "0061FF"),
        "drupal.org": SimpleIcon(slug: "drupal", color: "0678BE"),
        "duckdb.org": SimpleIcon(slug: "duckdb", color: "FFF000"),
        "duckduckgo.com": SimpleIcon(slug: "duckduckgo", color: "DE5833"),
        "dunked.com": SimpleIcon(slug: "dunked", color: "2DA9D7"),
        "dunzo.com": SimpleIcon(slug: "dunzo", color: "00D290"),
        "duolingo.com": SimpleIcon(slug: "duolingo", color: "58CC02"),
        "duplicati.com": SimpleIcon(slug: "duplicati", color: "1E3A8A"),
        "dw.com": SimpleIcon(slug: "deutschewelle", color: "05B2FC"),
        "dynatrace.com": SimpleIcon(slug: "dynatrace", color: "1496FF"),
        "e.foundation": SimpleIcon(slug: "e", color: "000000"),
        "e.leclerc": SimpleIcon(slug: "edotleclerc", color: "0066CC"),
        "ea.com": SimpleIcon(slug: "ea", color: "000000"),
        "eagle.cool": SimpleIcon(slug: "eagle", color: "0072EF"),
        "easyeda.com": SimpleIcon(slug: "easyeda", color: "1765F6"),
        "easyjet.com": SimpleIcon(slug: "easyjet", color: "FF6600"),
        "ebay.com": SimpleIcon(slug: "ebay", color: "E53238"),
        "ebox.ca": SimpleIcon(slug: "ebox", color: "BE2323"),
        "ecosia.org": SimpleIcon(slug: "ecosia", color: "008009"),
        "ecovacs.com": SimpleIcon(slug: "ecovacs", color: "1E384B"),
        "edeka.de": SimpleIcon(slug: "edeka", color: "1B66B3"),
        "edgeimpulse.com": SimpleIcon(slug: "edgeimpulse", color: "3B47C2"),
        "editorconfig.org": SimpleIcon(slug: "editorconfig", color: "FEFEFE"),
        "educative.io": SimpleIcon(slug: "educative", color: "4951F5"),
        "edx.org": SimpleIcon(slug: "edx", color: "02262B"),
        "effect.website": SimpleIcon(slug: "effect", color: "FFFFFF"),
        "egghead.io": SimpleIcon(slug: "egghead", color: "FCFBFA"),
        "egnyte.com": SimpleIcon(slug: "egnyte", color: "00968F"),
        "eightsleep.com": SimpleIcon(slug: "eightsleep", color: "262729"),
        "elastic.co": SimpleIcon(slug: "elastic", color: "005571"),
        "elavon.com": SimpleIcon(slug: "elavon", color: "0C2074"),
        "elegoo.com": SimpleIcon(slug: "elegoo", color: "2C3A83"),
        "element.io": SimpleIcon(slug: "element", color: "0DBD8B"),
        "elementary.io": SimpleIcon(slug: "elementary", color: "64BAFF"),
        "elementor.com": SimpleIcon(slug: "elementor", color: "92003B"),
        "elevenlabs.io": SimpleIcon(slug: "elevenlabs", color: "000000"),
        "elgato.com": SimpleIcon(slug: "elgato", color: "101010"),
        "elsevier.com": SimpleIcon(slug: "elsevier", color: "FF6C00"),
        "embarcadero.com": SimpleIcon(slug: "embarcadero", color: "ED1F35"),
        "emberjs.com": SimpleIcon(slug: "emberdotjs", color: "E04E39"),
        "emby.media": SimpleIcon(slug: "emby", color: "52B54B"),
        "emirates.com": SimpleIcon(slug: "emirates", color: "D71921"),
        "emlakjet.com": SimpleIcon(slug: "emlakjet", color: "0AE524"),
        "enpass.io": SimpleIcon(slug: "enpass", color: "0D47A1"),
        "ens.domains": SimpleIcon(slug: "ens", color: "0080BC"),
        "ente.io": SimpleIcon(slug: "ente", color: "00BC45"),
        "enterprisedb.com": SimpleIcon(slug: "enterprisedb", color: "FF3E00"),
        "envato.com": SimpleIcon(slug: "envato", color: "87E64B"),
        "epicgames.com": SimpleIcon(slug: "epicgames", color: "313131"),
        "epson.com": SimpleIcon(slug: "epson", color: "003399"),
        "eraser.io": SimpleIcon(slug: "eraser", color: "EC2C40"),
        "ericsson.com": SimpleIcon(slug: "ericsson", color: "0082F0"),
        "ericsson.net": SimpleIcon(slug: "ericsson", color: "0082F0"),
        "esea.net": SimpleIcon(slug: "esea", color: "0E9648"),
        "eslgaming.com": SimpleIcon(slug: "eslgaming", color: "FFFF09"),
        "eslint.org": SimpleIcon(slug: "eslint", color: "4B32C3"),
        "esotericsoftware.com": SimpleIcon(slug: "esotericsoftware", color: "3FA9F5"),
        "espressif.com": SimpleIcon(slug: "espressif", color: "E7352C"),
        "esri.com": SimpleIcon(slug: "esri", color: "000000"),
        "ethereum.org": SimpleIcon(slug: "ethereum", color: "3C3C3D"),
        "ethers.org": SimpleIcon(slug: "ethers", color: "2535A0"),
        "ethiopianairlines.com": SimpleIcon(slug: "ethiopianairlines", color: "648B1A"),
        "etsy.com": SimpleIcon(slug: "etsy", color: "F16521"),
        "evernote.com": SimpleIcon(slug: "evernote", color: "00A82D"),
        "every.org": SimpleIcon(slug: "everydotorg", color: "2BD7B0"),
        "excalidraw.com": SimpleIcon(slug: "excalidraw", color: "6965DB"),
        "exordo.com": SimpleIcon(slug: "exordo", color: "DAA449"),
        "exoscale.com": SimpleIcon(slug: "exoscale", color: "DA291C"),
        "expensify.com": SimpleIcon(slug: "expensify", color: "0185FF"),
        "experts-exchange.com": SimpleIcon(slug: "expertsexchange", color: "00AAE7"),
        "expo.dev": SimpleIcon(slug: "expo", color: "1C2024"),
        "express.com": SimpleIcon(slug: "expressdotcom", color: "000000"),
        "expressvpn.com": SimpleIcon(slug: "expressvpn", color: "DA3940"),
        "eyeem.com": SimpleIcon(slug: "eyeem", color: "000000"),
        "f-droid.org": SimpleIcon(slug: "fdroid", color: "1976D2"),
        "f5.com": SimpleIcon(slug: "f5", color: "E4002B"),
        "facebook.com": SimpleIcon(slug: "facebook", color: "0866FF"),
        "faceit.com": SimpleIcon(slug: "faceit", color: "FF5500"),
        "facepunch.com": SimpleIcon(slug: "facepunch", color: "EC1C24"),
        "fairphone.com": SimpleIcon(slug: "fairphone", color: "4495D1"),
        "falco.org": SimpleIcon(slug: "falco", color: "00AEC7"),
        "fampay.in": SimpleIcon(slug: "fampay", color: "FFAD00"),
        "fandango.com": SimpleIcon(slug: "fandango", color: "FF7300"),
        "fanfou.com": SimpleIcon(slug: "fanfou", color: "00CCFF"),
        "fantom.foundation": SimpleIcon(slug: "fantom", color: "0928FF"),
        "farcaster.xyz": SimpleIcon(slug: "farcaster", color: "855DCD"),
        "fareharbor.com": SimpleIcon(slug: "fareharbor", color: "0A6ECE"),
        "farfetch.com": SimpleIcon(slug: "farfetch", color: "000000"),
        "fastly.com": SimpleIcon(slug: "fastly", color: "FF282D"),
        "fauna.com": SimpleIcon(slug: "fauna", color: "3A1AB6"),
        "favro.com": SimpleIcon(slug: "favro", color: "512DA8"),
        "fcc.gov": SimpleIcon(slug: "fcc", color: "1C3664"),
        "fedex.com": SimpleIcon(slug: "fedex", color: "4D148C"),
        "feedly.com": SimpleIcon(slug: "feedly", color: "2BB24C"),
        "ferrari.com": SimpleIcon(slug: "ferrari", color: "D40000"),
        "fi.money": SimpleIcon(slug: "fi", color: "00B899"),
        "fidoalliance.org": SimpleIcon(slug: "fidoalliance", color: "FFBF3B"),
        "fig.io": SimpleIcon(slug: "fig", color: "000000"),
        "figma.com": SimpleIcon(slug: "figma", color: "F24E1E"),
        "fila.com": SimpleIcon(slug: "fila", color: "002D62"),
        "file.io": SimpleIcon(slug: "filedotio", color: "3D3C9D"),
        "fillout.com": SimpleIcon(slug: "fillout", color: "FFC738"),
        "fing.com": SimpleIcon(slug: "fing", color: "009AEE"),
        "firefly-iii.org": SimpleIcon(slug: "fireflyiii", color: "CD5029"),
        "fitbit.com": SimpleIcon(slug: "fitbit", color: "00B0B9"),
        "fivem.net": SimpleIcon(slug: "fivem", color: "F40552"),
        "fiverr.com": SimpleIcon(slug: "fiverr", color: "1DBF73"),
        "fizz.ca": SimpleIcon(slug: "fizz", color: "00D672"),
        "flashforge.com": SimpleIcon(slug: "flashforge", color: "000000"),
        "flathub.org": SimpleIcon(slug: "flathub", color: "000000"),
        "flatpak.org": SimpleIcon(slug: "flatpak", color: "4A90D9"),
        "flickr.com": SimpleIcon(slug: "flickr", color: "0063DC"),
        "flightaware.com": SimpleIcon(slug: "flightaware", color: "19315B"),
        "flipboard.com": SimpleIcon(slug: "flipboard", color: "E12828"),
        "floatplane.com": SimpleIcon(slug: "floatplane", color: "00AEEF"),
        "flood.io": SimpleIcon(slug: "flood", color: "4285F4"),
        "flower.ai": SimpleIcon(slug: "flower", color: "F2B705"),
        "fluentd.org": SimpleIcon(slug: "fluentd", color: "0E83C8"),
        "fluke.com": SimpleIcon(slug: "fluke", color: "FFC20E"),
        "flutter.dev": SimpleIcon(slug: "flutter", color: "02569B"),
        "fluxer.app": SimpleIcon(slug: "fluxer", color: "4641D9"),
        "fly.io": SimpleIcon(slug: "flydotio", color: "24175B"),
        "fmod.com": SimpleIcon(slug: "fmod", color: "000000"),
        "fnac.com": SimpleIcon(slug: "fnac", color: "E1A925"),
        "fonoma.com": SimpleIcon(slug: "fonoma", color: "02B78F"),
        "fontawesome.com": SimpleIcon(slug: "fontawesome", color: "538DD7"),
        "fontforge.org": SimpleIcon(slug: "fontforge", color: "F2712B"),
        "foodpanda.com": SimpleIcon(slug: "foodpanda", color: "D70F64"),
        "ford.com": SimpleIcon(slug: "ford", color: "00274E"),
        "formbricks.com": SimpleIcon(slug: "formbricks", color: "00C4B8"),
        "formik.org": SimpleIcon(slug: "formik", color: "2563EB"),
        "formspree.io": SimpleIcon(slug: "formspree", color: "E5122E"),
        "formstack.com": SimpleIcon(slug: "formstack", color: "21B573"),
        "fortinet.com": SimpleIcon(slug: "fortinet", color: "EE3124"),
        "fortnite.com": SimpleIcon(slug: "fortnite", color: "000000"),
        "fossa.com": SimpleIcon(slug: "fossa", color: "289E6D"),
        "fossil-scm.org": SimpleIcon(slug: "fossilscm", color: "548294"),
        "foursquare.com": SimpleIcon(slug: "foursquare", color: "3333FF"),
        "fox.com": SimpleIcon(slug: "fox", color: "000000"),
        "foxtel.com.au": SimpleIcon(slug: "foxtel", color: "EB5205"),
        "fozzy.com": SimpleIcon(slug: "fozzy", color: "F15B29"),
        "framer.com": SimpleIcon(slug: "framer", color: "0055FF"),
        "franprix.fr": SimpleIcon(slug: "franprix", color: "EC6237"),
        "freecad.org": SimpleIcon(slug: "freecad", color: "418FDE"),
        "freecodecamp.org": SimpleIcon(slug: "freecodecamp", color: "0A0A23"),
        "freelancer.com": SimpleIcon(slug: "freelancer", color: "29B2FE"),
        "freelancermap.de": SimpleIcon(slug: "freelancermap", color: "00CFD6"),
        "freenet.ag": SimpleIcon(slug: "freenet", color: "84BC34"),
        "freshrss.org": SimpleIcon(slug: "freshrss", color: "0062BE"),
        "frigate.video": SimpleIcon(slug: "frigate", color: "000000"),
        "fritz.com": SimpleIcon(slug: "fritz", color: "E2001A"),
        "frontendmentor.io": SimpleIcon(slug: "frontendmentor", color: "3F54A3"),
        "frontify.com": SimpleIcon(slug: "frontify", color: "2D3232"),
        "fsharp.org": SimpleIcon(slug: "fsharp", color: "378BBA"),
        "fubo.tv": SimpleIcon(slug: "fubo", color: "C83D1E"),
        "fueler.io": SimpleIcon(slug: "fueler", color: "09C9E3"),
        "fujifilm.com": SimpleIcon(slug: "fujifilm", color: "FB0020"),
        "fujitsu.com": SimpleIcon(slug: "fujitsu", color: "FF0000"),
        "furaffinity.net": SimpleIcon(slug: "furaffinity", color: "36566F"),
        "furrynetwork.com": SimpleIcon(slug: "furrynetwork", color: "2E75B4"),
        "fusionauth.io": SimpleIcon(slug: "fusionauth", color: "F58320"),
        "futurelearn.com": SimpleIcon(slug: "futurelearn", color: "DE00A5"),
        "g2.com": SimpleIcon(slug: "g2", color: "FF492C"),
        "g2a.co": SimpleIcon(slug: "g2a", color: "F05F00"),
        "galaxus.de": SimpleIcon(slug: "galaxus", color: "000000"),
        "gamebanana.com": SimpleIcon(slug: "gamebanana", color: "FCEF40"),
        "gamedeveloper.com": SimpleIcon(slug: "gamedeveloper", color: "E60012"),
        "gamejolt.com": SimpleIcon(slug: "gamejolt", color: "CCFF00"),
        "gameloft.com": SimpleIcon(slug: "gameloft", color: "000000"),
        "gamemaker.io": SimpleIcon(slug: "gamemaker", color: "000000"),
        "gandi.net": SimpleIcon(slug: "gandi", color: "6640FE"),
        "garmin.com": SimpleIcon(slug: "garmin", color: "000000"),
        "gatling.io": SimpleIcon(slug: "gatling", color: "FF9E2A"),
        "gcore.com": SimpleIcon(slug: "gcore", color: "FF4C00"),
        "ge.com": SimpleIcon(slug: "generalelectric", color: "0870D8"),
        "geeksforgeeks.org": SimpleIcon(slug: "geeksforgeeks", color: "2F8D46"),
        "genius.com": SimpleIcon(slug: "genius", color: "FFFF64"),
        "gentoo.org": SimpleIcon(slug: "gentoo", color: "54487A"),
        "geocaching.com": SimpleIcon(slug: "geocaching", color: "00874D"),
        "geopandas.org": SimpleIcon(slug: "geopandas", color: "139C5A"),
        "ghost.org": SimpleIcon(slug: "ghost", color: "15171A"),
        "ghostery.com": SimpleIcon(slug: "ghostery", color: "00AEF0"),
        "giphy.com": SimpleIcon(slug: "giphy", color: "FF6666"),
        "gitbook.com": SimpleIcon(slug: "gitbook", color: "BBDDE5"),
        "gitcode.com": SimpleIcon(slug: "gitcode", color: "DA203E"),
        "gitconnected.com": SimpleIcon(slug: "gitconnected", color: "2E69AE"),
        "gitee.com": SimpleIcon(slug: "gitee", color: "C71D23"),
        "github.com": SimpleIcon(slug: "github", color: "181717"),
        "gitignore.io": SimpleIcon(slug: "gitignoredotio", color: "204ECF"),
        "gitkraken.com": SimpleIcon(slug: "gitkraken", color: "179287"),
        "gitlab.com": SimpleIcon(slug: "gitlab", color: "FC6D26"),
        "gitpod.io": SimpleIcon(slug: "gitpod", color: "FFAE33"),
        "gitter.im": SimpleIcon(slug: "gitter", color: "ED1965"),
        "gl-inet.com": SimpleIcon(slug: "gldotinet", color: "636363"),
        "glassdoor.com": SimpleIcon(slug: "glassdoor", color: "00A162"),
        "gleam.run": SimpleIcon(slug: "gleam", color: "FFAFF3"),
        "glide.page": SimpleIcon(slug: "glide", color: "18BED4"),
        "glitch.com": SimpleIcon(slug: "glitch", color: "3333FF"),
        "globus.de": SimpleIcon(slug: "globus", color: "CA6201"),
        "gm.com": SimpleIcon(slug: "generalmotors", color: "0170CE"),
        "gmail.com": SimpleIcon(slug: "gmail", color: "EA4335"),
        "gnome.org": SimpleIcon(slug: "gnome", color: "4A86CF"),
        "gnu.org": SimpleIcon(slug: "gnu", color: "A42E2B"),
        "gocd.org": SimpleIcon(slug: "gocd", color: "94399E"),
        "godaddy.net": SimpleIcon(slug: "godaddy", color: "1BDBDB"),
        "godotengine.org": SimpleIcon(slug: "godotengine", color: "478CBF"),
        "gofundme.com": SimpleIcon(slug: "gofundme", color: "00B964"),
        "gojek.com": SimpleIcon(slug: "gojek", color: "00AA13"),
        "gojek.design": SimpleIcon(slug: "gojek", color: "00AA13"),
        "goodreads.com": SimpleIcon(slug: "goodreads", color: "1E1914"),
        "google.com": SimpleIcon(slug: "google", color: "4285F4"),
        "gotomeeting.com": SimpleIcon(slug: "gotomeeting", color: "F68D2E"),
        "gradio.app": SimpleIcon(slug: "gradio", color: "F97316"),
        "gradle.com": SimpleIcon(slug: "gradle", color: "02303A"),
        "grafana.com": SimpleIcon(slug: "grafana", color: "F46800"),
        "grammarly.com": SimpleIcon(slug: "grammarly", color: "027E6F"),
        "grandfrais.com": SimpleIcon(slug: "grandfrais", color: "ED2D2F"),
        "graphite.art": SimpleIcon(slug: "graphite_editor", color: "473A3A"),
        "graphite.dev": SimpleIcon(slug: "graphite", color: "000000"),
        "graphql.org": SimpleIcon(slug: "graphql", color: "E10098"),
        "graylog.org": SimpleIcon(slug: "graylog", color: "FF3633"),
        "greenhouse.io": SimpleIcon(slug: "greenhouse", color: "24A47F"),
        "greensock.com": SimpleIcon(slug: "greensock", color: "88CE02"),
        "gridsome.org": SimpleIcon(slug: "gridsome", color: "00A672"),
        "groupme.com": SimpleIcon(slug: "groupme", color: "00AFF0"),
        "groupon.com": SimpleIcon(slug: "groupon", color: "53A318"),
        "gs.com": SimpleIcon(slug: "goldmansachs", color: "7399C6"),
        "gsap.com": SimpleIcon(slug: "gsap", color: "0AE448"),
        "gsma.com": SimpleIcon(slug: "gsma", color: "DC002B"),
        "gsmarena.com": SimpleIcon(slug: "gsmarenadotcom", color: "D50000"),
        "guilded.gg": SimpleIcon(slug: "guilded", color: "F5C400"),
        "guitar-pro.com": SimpleIcon(slug: "guitarpro", color: "569FFF"),
        "gumroad.com": SimpleIcon(slug: "gumroad", color: "FF90E8"),
        "gumtree.com": SimpleIcon(slug: "gumtree", color: "72EF36"),
        "gurobi.com": SimpleIcon(slug: "gurobi", color: "EE3524"),
        "gusto.com": SimpleIcon(slug: "gusto", color: "F45D48"),
        "habr.com": SimpleIcon(slug: "habr", color: "65A3BE"),
        "hackaday.com": SimpleIcon(slug: "hackaday", color: "1A1A1A"),
        "hackclub.com": SimpleIcon(slug: "hackclub", color: "EC3750"),
        "hackerearth.com": SimpleIcon(slug: "hackerearth", color: "2C3454"),
        "hackernoon.com": SimpleIcon(slug: "hackernoon", color: "00FE00"),
        "hackerone.com": SimpleIcon(slug: "hackerone", color: "494649"),
        "hackerrank.com": SimpleIcon(slug: "hackerrank", color: "00EA64"),
        "hackmd.io": SimpleIcon(slug: "hackmd", color: "453AFF"),
        "hackster.io": SimpleIcon(slug: "hackster", color: "2E9FE6"),
        "hackthebox.com": SimpleIcon(slug: "hackthebox", color: "9FEF00"),
        "hacs.xyz": SimpleIcon(slug: "homeassistantcommunitystore", color: "41BDF5"),
        "handshake.org": SimpleIcon(slug: "handshake_protocol", color: "000000"),
        "happycow.net": SimpleIcon(slug: "happycow", color: "7C4EC4"),
        "harmonyos.com": SimpleIcon(slug: "harmonyos", color: "000000"),
        "hashcat.net": SimpleIcon(slug: "hashcat", color: "FFFFFF"),
        "hashicorp.com": SimpleIcon(slug: "hashicorp", color: "000000"),
        "hashnode.com": SimpleIcon(slug: "hashnode", color: "2962FF"),
        "haskell.org": SimpleIcon(slug: "haskell", color: "5D4F85"),
        "havells.com": SimpleIcon(slug: "havells", color: "ED1C24"),
        "haxe.org": SimpleIcon(slug: "haxe", color: "EA8220"),
        "hbo.com": SimpleIcon(slug: "hbo", color: "000000"),
        "hcl.com": SimpleIcon(slug: "hcl", color: "006BB6"),
        "headlessui.dev": SimpleIcon(slug: "headlessui", color: "66E3FF"),
        "headphonezone.in": SimpleIcon(slug: "headphonezone", color: "3C07FF"),
        "headspace.com": SimpleIcon(slug: "headspace", color: "F47D31"),
        "hearthis.at": SimpleIcon(slug: "hearthisdotat", color: "000000"),
        "hedera.com": SimpleIcon(slug: "hedera", color: "222222"),
        "helium.com": SimpleIcon(slug: "helium", color: "0ACF83"),
        "hellyhansen.com": SimpleIcon(slug: "hellyhansen", color: "DA2128"),
        "helm.sh": SimpleIcon(slug: "helm", color: "0F1689"),
        "helpdesk.design": SimpleIcon(slug: "helpdesk", color: "2FC774"),
        "helpscout.com": SimpleIcon(slug: "helpscout", color: "1292EE"),
        "hepsiemlak.com": SimpleIcon(slug: "hepsiemlak", color: "E1251B"),
        "here.com": SimpleIcon(slug: "here", color: "00AFAA"),
        "heroku.com": SimpleIcon(slug: "heroku", color: "430098", packageVersion: "15.22.0"),
        "heroui.com": SimpleIcon(slug: "heroui", color: "000000"),
        "hetzner.com": SimpleIcon(slug: "hetzner", color: "D50C2D"),
        "hexlet.io": SimpleIcon(slug: "hexlet", color: "116EF5"),
        "hexo.io": SimpleIcon(slug: "hexo", color: "0E83CD"),
        "hey.com": SimpleIcon(slug: "hey", color: "5522FA"),
        "hibernate.org": SimpleIcon(slug: "hibernate", color: "59666C"),
        "hibob.com": SimpleIcon(slug: "hibob", color: "E42C51"),
        "hilton.com": SimpleIcon(slug: "hilton", color: "231F20"),
        "hive.io": SimpleIcon(slug: "hive_blockchain", color: "E31337"),
        "hivemq.com": SimpleIcon(slug: "hivemq", color: "FFC000"),
        "hm.com": SimpleIcon(slug: "handm", color: "E50010"),
        "home-assistant.io": SimpleIcon(slug: "homeassistant", color: "18BCF2"),
        "homeadvisor.com": SimpleIcon(slug: "homeadvisor", color: "F68315"),
        "homify.com": SimpleIcon(slug: "homify", color: "7DCDA3"),
        "honda.ie": SimpleIcon(slug: "honda", color: "E40521"),
        "honeybadger.io": SimpleIcon(slug: "honeybadger", color: "EA5937"),
        "honeygain.com": SimpleIcon(slug: "honeygain", color: "F9C900"),
        "hoppscotch.com": SimpleIcon(slug: "hoppscotch", color: "09090B"),
        "hostinger.com": SimpleIcon(slug: "hostinger", color: "673DE6"),
        "hotels.com": SimpleIcon(slug: "hotelsdotcom", color: "EF3346"),
        "hotjar.com": SimpleIcon(slug: "hotjar", color: "FF3C00"),
        "houzz.com": SimpleIcon(slug: "houzz", color: "4DBC15"),
        "hp.com": SimpleIcon(slug: "hp", color: "0096D6"),
        "hsbc.com": SimpleIcon(slug: "hsbc", color: "DB0011"),
        "htc.com": SimpleIcon(slug: "htc", color: "A5CF4C"),
        "htmlacademy.ru": SimpleIcon(slug: "htmlacademy", color: "302683"),
        "huawei.com": SimpleIcon(slug: "huawei", color: "FF0000"),
        "hubspot.com": SimpleIcon(slug: "hubspot", color: "FF7A59"),
        "huggingface.co": SimpleIcon(slug: "huggingface", color: "FFD21E"),
        "humblebundle.com": SimpleIcon(slug: "humblebundle", color: "CC2929"),
        "hungryjacks.com.au": SimpleIcon(slug: "hungryjacks", color: "D0021B"),
        "husqvarna.com": SimpleIcon(slug: "husqvarna", color: "273A60"),
        "hyper.is": SimpleIcon(slug: "hyper", color: "000000"),
        "hyperskill.org": SimpleIcon(slug: "hyperskill", color: "8C5AFF"),
        "hyperx.com": SimpleIcon(slug: "hyperx", color: "E21836"),
        "hyprland.org": SimpleIcon(slug: "hyprland", color: "58E1FF"),
        "hyundai.com": SimpleIcon(slug: "hyundai", color: "002C5E"),
        "iberia.com": SimpleIcon(slug: "iberia", color: "D7192D"),
        "iced.rs": SimpleIcon(slug: "iced", color: "3645FF"),
        "iceland.co.uk": SimpleIcon(slug: "iceland", color: "CC092F"),
        "icicibank.com": SimpleIcon(slug: "icicibank", color: "AE282E"),
        "icomoon.io": SimpleIcon(slug: "icomoon", color: "825794"),
        "icon.foundation": SimpleIcon(slug: "icon", color: "31B8BB"),
        "iconfinder.com": SimpleIcon(slug: "iconfinder", color: "1A1B1F"),
        "iconify.design": SimpleIcon(slug: "iconify", color: "026C9C"),
        "icons8.com": SimpleIcon(slug: "icons8", color: "1FB141"),
        "ieee.org": SimpleIcon(slug: "ieee", color: "00629B"),
        "ifixit.com": SimpleIcon(slug: "ifixit", color: "0071CE"),
        "ifood.com.br": SimpleIcon(slug: "ifood", color: "EA1D2C"),
        "ifttt.com": SimpleIcon(slug: "ifttt", color: "000000"),
        "ign.com": SimpleIcon(slug: "ign", color: "BF1313"),
        "ikea.com": SimpleIcon(slug: "ikea", color: "0058A3"),
        "iledefrance-mobilites.fr": SimpleIcon(slug: "iledefrancemobilites", color: "67B4E7"),
        "ilovepdf.com": SimpleIcon(slug: "ilovepdf", color: "E5322D"),
        "image.sc": SimpleIcon(slug: "imagedotsc", color: "039CB2"),
        "imdb.com": SimpleIcon(slug: "imdb", color: "F5C518"),
        "imgur.com": SimpleIcon(slug: "imgur", color: "1BB76E"),
        "immersivetranslate.com": SimpleIcon(slug: "immersivetranslate", color: "EA4C89"),
        "improvmx.com": SimpleIcon(slug: "improvmx", color: "2FBEFF"),
        "indeed.design": SimpleIcon(slug: "indeed", color: "003A9B"),
        "indiansuperleague.com": SimpleIcon(slug: "indiansuperleague", color: "ED2F21"),
        "indiehackers.com": SimpleIcon(slug: "indiehackers", color: "0E2439"),
        "indieweb.org": SimpleIcon(slug: "indieweb", color: "FF0000"),
        "inductiveautomation.com": SimpleIcon(slug: "inductiveautomation", color: "445C6D"),
        "infiniti.com": SimpleIcon(slug: "infiniti", color: "020B24"),
        "infinityfree.com": SimpleIcon(slug: "infinityfree", color: "7738C8"),
        "infomaniak.com": SimpleIcon(slug: "infomaniak", color: "0098FF"),
        "infoq.com": SimpleIcon(slug: "infoq", color: "2C6CAF"),
        "infosys.com": SimpleIcon(slug: "infosys", color: "007CC3"),
        "infracost.io": SimpleIcon(slug: "infracost", color: "DB44B8"),
        "ingress.com": SimpleIcon(slug: "ingress", color: "783CBD"),
        "inkdrop.app": SimpleIcon(slug: "inkdrop", color: "7A78D7"),
        "inkscape.org": SimpleIcon(slug: "inkscape", color: "000000"),
        "inoreader.com": SimpleIcon(slug: "inoreader", color: "1875F3"),
        "insomnia.rest": SimpleIcon(slug: "insomnia", color: "4000BF"),
        "insta360.com": SimpleIcon(slug: "insta360", color: "FFEE00"),
        "instacart.com": SimpleIcon(slug: "instacart", color: "43B02A"),
        "instagram.com": SimpleIcon(slug: "instagram", color: "FF0069"),
        "instapaper.com": SimpleIcon(slug: "instapaper", color: "1F1F1F"),
        "instatus.com": SimpleIcon(slug: "instatus", color: "4EE3C2"),
        "instructables.com": SimpleIcon(slug: "instructables", color: "FABF15"),
        "instructure.com": SimpleIcon(slug: "instructure", color: "2A7BA0"),
        "intel.com": SimpleIcon(slug: "intel", color: "0071C5"),
        "intercom.com": SimpleIcon(slug: "intercom", color: "6AFDEF"),
        "intermarche.com": SimpleIcon(slug: "intermarche", color: "E2001A"),
        "intigriti.com": SimpleIcon(slug: "intigriti", color: "161A36"),
        "intuit.com": SimpleIcon(slug: "intuit", color: "236CFF"),
        "ionos.de": SimpleIcon(slug: "ionos", color: "003D8F"),
        "iota.org": SimpleIcon(slug: "iota", color: "131F37"),
        "iris.co.uk": SimpleIcon(slug: "iris", color: "25313C"),
        "irobot.com": SimpleIcon(slug: "irobot", color: "6CB86A"),
        "isc2.org": SimpleIcon(slug: "isc2", color: "468145"),
        "issuu.com": SimpleIcon(slug: "issuu", color: "F36D5D"),
        "itch.io": SimpleIcon(slug: "itchdotio", color: "FA5C5C"),
        "iveco.com": SimpleIcon(slug: "iveco", color: "1554FF"),
        "jabber.org": SimpleIcon(slug: "jabber", color: "CC0000"),
        "jbl.com": SimpleIcon(slug: "jbl", color: "FF3300"),
        "jdoodle.com": SimpleIcon(slug: "jdoodle", color: "FD5200"),
        "jellyfin.org": SimpleIcon(slug: "jellyfin", color: "00A4DC"),
        "jenkins.io": SimpleIcon(slug: "jenkins", color: "D24939"),
        "jetblue.com": SimpleIcon(slug: "jetblue", color: "001E59"),
        "jetbrains.com": SimpleIcon(slug: "jetbrains", color: "000000"),
        "jfrog.com": SimpleIcon(slug: "jfrog", color: "40BE46"),
        "jhipster.tech": SimpleIcon(slug: "jhipster", color: "3E8ACC"),
        "jitpack.io": SimpleIcon(slug: "jitpack", color: "000000"),
        "joomla.org": SimpleIcon(slug: "joomla", color: "5091CD"),
        "jouav.com": SimpleIcon(slug: "jouav", color: "E1B133"),
        "jovian.com": SimpleIcon(slug: "jovian", color: "0D61FF"),
        "jpeg.org": SimpleIcon(slug: "jpeg", color: "8A8A8A"),
        "jquery.org": SimpleIcon(slug: "jquery", color: "0769AD"),
        "jsfiddle.net": SimpleIcon(slug: "jsfiddle", color: "0084FF"),
        "juce.com": SimpleIcon(slug: "juce", color: "8DC63F"),
        "juejin.cn": SimpleIcon(slug: "juejin", color: "007FFF"),
        "juke.nl": SimpleIcon(slug: "juke", color: "6CD74A"),
        "just-eat.com": SimpleIcon(slug: "justeat", color: "FF8000"),
        "just.systems": SimpleIcon(slug: "just", color: "000000"),
        "justgiving.com": SimpleIcon(slug: "justgiving", color: "AD29B6"),
        "jwt.io": SimpleIcon(slug: "jsonwebtokens", color: "000000"),
        "k3s.io": SimpleIcon(slug: "k3s", color: "FFC61C"),
        "kaggle.com": SimpleIcon(slug: "kaggle", color: "20BEFF"),
        "kagi.com": SimpleIcon(slug: "kagi", color: "FFB319"),
        "kahoot.com": SimpleIcon(slug: "kahoot", color: "46178F"),
        "kamailio.org": SimpleIcon(slug: "kamailio", color: "506365"),
        "karakeep.app": SimpleIcon(slug: "karakeep", color: "000000"),
        "kashflow.com": SimpleIcon(slug: "kashflow", color: "E5426E"),
        "kaspersky.com": SimpleIcon(slug: "kaspersky", color: "006D5C"),
        "kaufland.com": SimpleIcon(slug: "kaufland", color: "E10915"),
        "kde.org": SimpleIcon(slug: "kde", color: "1D99F3"),
        "kdenlive.org": SimpleIcon(slug: "kdenlive", color: "527EB2"),
        "keenetic.com": SimpleIcon(slug: "keenetic", color: "009EE2"),
        "keepachangelog.com": SimpleIcon(slug: "keepachangelog", color: "E05735"),
        "keeper.io": SimpleIcon(slug: "keeper", color: "FFC700"),
        "kenmei.co": SimpleIcon(slug: "kenmei", color: "545C64"),
        "kentico.com": SimpleIcon(slug: "kentico", color: "F05A22"),
        "keploy.io": SimpleIcon(slug: "keploy", color: "FF914D"),
        "keras.io": SimpleIcon(slug: "keras", color: "D00000"),
        "keycdn.com": SimpleIcon(slug: "keycdn", color: "047AED"),
        "kfc.com": SimpleIcon(slug: "kfc", color: "F40027"),
        "khanacademy.org": SimpleIcon(slug: "khanacademy", color: "14BF96"),
        "kia.com": SimpleIcon(slug: "kia", color: "05141F"),
        "kicad.org": SimpleIcon(slug: "kicad", color: "314CB0"),
        "kick.com": SimpleIcon(slug: "kick", color: "53FC19"),
        "kickstarter.com": SimpleIcon(slug: "kickstarter", color: "05CE78"),
        "kik.com": SimpleIcon(slug: "kik", color: "82BC23"),
        "kinopoisk.ru": SimpleIcon(slug: "kinopoisk", color: "FF5500"),
        "kinsta.com": SimpleIcon(slug: "kinsta", color: "5333ED"),
        "kit.co": SimpleIcon(slug: "kit", color: "000000"),
        "kitsu.io": SimpleIcon(slug: "kitsu", color: "FD755C"),
        "kiwix.org": SimpleIcon(slug: "kiwix", color: "000000"),
        "klarna.design": SimpleIcon(slug: "klarna", color: "FFB3C7"),
        "kleinanzeigen.de": SimpleIcon(slug: "kleinanzeigen", color: "1D4B00"),
        "klm.com": SimpleIcon(slug: "klm", color: "00A1DE"),
        "klook.com": SimpleIcon(slug: "klook", color: "FF5722"),
        "knime.com": SimpleIcon(slug: "knime", color: "FDD800"),
        "knip.dev": SimpleIcon(slug: "knip", color: "F56E0F"),
        "knowledgebase.com": SimpleIcon(slug: "knowledgebase", color: "9146FF"),
        "ko-fi.com": SimpleIcon(slug: "kofi", color: "FF6433"),
        "koc.com.tr": SimpleIcon(slug: "koc", color: "F9423A"),
        "kodak.com": SimpleIcon(slug: "kodak", color: "ED0000"),
        "kodi.tv": SimpleIcon(slug: "kodi", color: "17B2E7"),
        "kodular.io": SimpleIcon(slug: "kodular", color: "4527A0"),
        "koenigsegg.com": SimpleIcon(slug: "koenigsegg", color: "000000"),
        "kofax.com": SimpleIcon(slug: "kofax", color: "00558C"),
        "komoot.com": SimpleIcon(slug: "komoot", color: "6AA127"),
        "kongregate.com": SimpleIcon(slug: "kongregate", color: "F04438"),
        "koyeb.com": SimpleIcon(slug: "koyeb", color: "121212"),
        "krita.org": SimpleIcon(slug: "krita", color: "3BABFF"),
        "ktm.com": SimpleIcon(slug: "ktm", color: "FF6600"),
        "kuaishou.com": SimpleIcon(slug: "kuaishou", color: "FF4906"),
        "kubernetes.io": SimpleIcon(slug: "kubernetes", color: "326CE5"),
        "kubuntu.org": SimpleIcon(slug: "kubuntu", color: "0079C1"),
        "kucoin.com": SimpleIcon(slug: "kucoin", color: "01BC8D"),
        "kueski.com": SimpleIcon(slug: "kueski", color: "0075FF"),
        "kununu.com": SimpleIcon(slug: "kununu", color: "FFC62E"),
        "kuula.co": SimpleIcon(slug: "kuula", color: "4092B4"),
        "kx.com": SimpleIcon(slug: "kx", color: "101820"),
        "kyocera.com": SimpleIcon(slug: "kyocera", color: "DF0522"),
        "labex.io": SimpleIcon(slug: "labex", color: "2E7EEE"),
        "lada.ru": SimpleIcon(slug: "lada", color: "ED6B21"),
        "lamborghini.com": SimpleIcon(slug: "lamborghini", color: "B6A272"),
        "langchain.com": SimpleIcon(slug: "langchain", color: "7FC8FF"),
        "languagetool.org": SimpleIcon(slug: "languagetool", color: "45A1FC"),
        "laragon.org": SimpleIcon(slug: "laragon", color: "0E83CD"),
        "lastpass.com": SimpleIcon(slug: "lastpass", color: "D32D27"),
        "launchpad.net": SimpleIcon(slug: "launchpad", color: "E95420"),
        "lbry.com": SimpleIcon(slug: "lbry", color: "2F9176"),
        "leaderprice.fr": SimpleIcon(slug: "leaderprice", color: "E50005"),
        "leagueoflegends.com": SimpleIcon(slug: "leagueoflegends", color: "C28F2C"),
        "leanpub.com": SimpleIcon(slug: "leanpub", color: "262425"),
        "leetcode.com": SimpleIcon(slug: "leetcode", color: "FFA116"),
        "legacygames.com": SimpleIcon(slug: "legacygames", color: "144B9E"),
        "lemonsqueezy.com": SimpleIcon(slug: "lemonsqueezy", color: "FFC233"),
        "lenovo.com": SimpleIcon(slug: "lenovo", color: "E2231A"),
        "leroymerlin.fr": SimpleIcon(slug: "leroymerlin", color: "78BE20"),
        "leslibraires.ca": SimpleIcon(slug: "leslibraires", color: "CF4A0C"),
        "letsencrypt.org": SimpleIcon(slug: "letsencrypt", color: "003A70"),
        "letterboxd.com": SimpleIcon(slug: "letterboxd", color: "202830"),
        "levels.fyi": SimpleIcon(slug: "levelsdotfyi", color: "788B95"),
        "lg.com": SimpleIcon(slug: "lg", color: "A50034"),
        "libera.chat": SimpleIcon(slug: "liberadotchat", color: "FF55DD"),
        "liberapay.com": SimpleIcon(slug: "liberapay", color: "F6C915"),
        "libretranslate.com": SimpleIcon(slug: "libretranslate", color: "1565C0"),
        "librewolf.net": SimpleIcon(slug: "librewolf", color: "00ACFF"),
        "lichess.org": SimpleIcon(slug: "lichess", color: "000000"),
        "lidl.de": SimpleIcon(slug: "lidl", color: "0050AA"),
        "lifx.com": SimpleIcon(slug: "lifx", color: "000000"),
        "limesurvey.org": SimpleIcon(slug: "limesurvey", color: "14AE5C"),
        "line.me": SimpleIcon(slug: "line", color: "00C300"),
        "lineageos.org": SimpleIcon(slug: "lineageos", color: "167C80"),
        "linear.app": SimpleIcon(slug: "linear", color: "5E6AD2"),
        "lining.com": SimpleIcon(slug: "lining", color: "C5242C"),
        "linkfire.com": SimpleIcon(slug: "linkfire", color: "FF3850"),
        "linksys.com": SimpleIcon(slug: "linksys", color: "000000"),
        "linkvertise.com": SimpleIcon(slug: "linkvertise", color: "FF8114"),
        "linphone.org": SimpleIcon(slug: "linphone", color: "FF5E00"),
        "lintcode.com": SimpleIcon(slug: "lintcode", color: "13B4FF"),
        "linuxfoundation.org": SimpleIcon(slug: "linuxfoundation", color: "003778"),
        "liquibase.com": SimpleIcon(slug: "liquibase", color: "2962FF"),
        "listenhub.ai": SimpleIcon(slug: "listenhub", color: "000000"),
        "listmonk.app": SimpleIcon(slug: "listmonk", color: "0055D4"),
        "literal.club": SimpleIcon(slug: "literal", color: "000000"),
        "litiengine.com": SimpleIcon(slug: "litiengine", color: "00A5BC"),
        "livechat.design": SimpleIcon(slug: "livechat", color: "FF5100"),
        "livejournal.com": SimpleIcon(slug: "livejournal", color: "00B0EA"),
        "livekit.io": SimpleIcon(slug: "livekit", color: "FFFFFF"),
        "llvm.org": SimpleIcon(slug: "llvm", color: "262D3A"),
        "lmms.io": SimpleIcon(slug: "lmms", color: "10B146"),
        "lmstudio.ai": SimpleIcon(slug: "lmstudio", color: "000000"),
        "localxpose.io": SimpleIcon(slug: "localxpose", color: "6023C0"),
        "logmein.com": SimpleIcon(slug: "logmein", color: "45B6F2"),
        "looker.com": SimpleIcon(slug: "looker", color: "4285F4"),
        "loom.com": SimpleIcon(slug: "loom", color: "625DF5"),
        "loopback.io": SimpleIcon(slug: "loopback", color: "3F5DFF"),
        "loops.so": SimpleIcon(slug: "loops", color: "FC5200"),
        "lootcrate.com": SimpleIcon(slug: "lootcrate", color: "1E1E1E"),
        "lospec.com": SimpleIcon(slug: "lospec", color: "EAEAEA"),
        "lpi.org": SimpleIcon(slug: "linuxprofessionalinstitute", color: "FDC300"),
        "lua.org": SimpleIcon(slug: "lua", color: "000080"),
        "luanti.org": SimpleIcon(slug: "luanti", color: "53AC56"),
        "lubuntu.net": SimpleIcon(slug: "lubuntu", color: "0068C8"),
        "lucid.co": SimpleIcon(slug: "lucid", color: "282C33"),
        "lucide.dev": SimpleIcon(slug: "lucide", color: "F56565"),
        "lufthansa.com": SimpleIcon(slug: "lufthansa", color: "05164D"),
        "luogu.com.cn": SimpleIcon(slug: "luogu", color: "5B9BD5"),
        "lvgl.io": SimpleIcon(slug: "lvgl", color: "343839"),
        "lyft.com": SimpleIcon(slug: "lyft", color: "FF00BF"),
        "macpaw.com": SimpleIcon(slug: "macpaw", color: "000000"),
        "magasins-u.com": SimpleIcon(slug: "magasinsu", color: "E71B34"),
        "magic.link": SimpleIcon(slug: "magic", color: "6851FF"),
        "mahindra.com": SimpleIcon(slug: "mahindra", color: "DD052B"),
        "mail.com": SimpleIcon(slug: "maildotcom", color: "004788"),
        "mail.ru": SimpleIcon(slug: "maildotru", color: "005FF9"),
        "mailbox.org": SimpleIcon(slug: "mailbox", color: "ABE659"),
        "mailchimp.com": SimpleIcon(slug: "mailchimp", color: "FFE01B"),
        "mailgun.com": SimpleIcon(slug: "mailgun", color: "F06B66"),
        "mailtrap.io": SimpleIcon(slug: "mailtrap", color: "22D172"),
        "mainwp.com": SimpleIcon(slug: "mainwp", color: "7FB100"),
        "make.com": SimpleIcon(slug: "make", color: "6D00CC"),
        "makerbot.com": SimpleIcon(slug: "makerbot", color: "FF1E0D"),
        "malt.com": SimpleIcon(slug: "malt", color: "FC5757"),
        "malwarebytes.com": SimpleIcon(slug: "malwarebytes", color: "0D3ECC"),
        "mamp.info": SimpleIcon(slug: "mamp", color: "02749C"),
        "man.eu": SimpleIcon(slug: "man", color: "E40045"),
        "manageiq.org": SimpleIcon(slug: "manageiq", color: "EF2929"),
        "mangacollec.com": SimpleIcon(slug: "mangacollec", color: "DA1F05"),
        "mangaupdates.com": SimpleIcon(slug: "mangaupdates", color: "FF8C15"),
        "manjaro.org": SimpleIcon(slug: "manjaro", color: "35BFA4"),
        "mapbox.com": SimpleIcon(slug: "mapbox", color: "000000"),
        "mapillary.com": SimpleIcon(slug: "mapillary", color: "00AF66"),
        "maptiler.com": SimpleIcon(slug: "maptiler", color: "323357"),
        "mariadb.com": SimpleIcon(slug: "mariadb", color: "003545"),
        "marriott.com": SimpleIcon(slug: "marriott", color: "A70023"),
        "marvelapp.com": SimpleIcon(slug: "marvelapp", color: "1FB6FF"),
        "mastercard.com": SimpleIcon(slug: "mastercard", color: "EB001B"),
        "materialdesignicons.com": SimpleIcon(slug: "materialdesignicons", color: "2196F3"),
        "matillion.com": SimpleIcon(slug: "matillion", color: "19E57F"),
        "matomo.org": SimpleIcon(slug: "matomo", color: "3152A0"),
        "matrix.org": SimpleIcon(slug: "matrix", color: "000000"),
        "mattermost.org": SimpleIcon(slug: "mattermost", color: "0058CC"),
        "mautic.org": SimpleIcon(slug: "mautic", color: "4E5E9E"),
        "mazda.com": SimpleIcon(slug: "mazda", color: "101010"),
        "mcafee.com": SimpleIcon(slug: "mcafee", color: "C01818"),
        "mcdonalds.com": SimpleIcon(slug: "mcdonalds", color: "FBC817"),
        "mclaren.com": SimpleIcon(slug: "mclaren", color: "FF0000"),
        "mdblist.com": SimpleIcon(slug: "mdblist", color: "4284CA"),
        "mediafire.com": SimpleIcon(slug: "mediafire", color: "1299F3"),
        "mediamarkt.de": SimpleIcon(slug: "mediamarkt", color: "DF0000"),
        "mediatek.com": SimpleIcon(slug: "mediatek", color: "EC9430"),
        "medibangpaint.com": SimpleIcon(slug: "medibangpaint", color: "00DBDE"),
        "medium.design": SimpleIcon(slug: "medium", color: "000000"),
        "meetup.com": SimpleIcon(slug: "meetup", color: "ED1C40"),
        "mega.io": SimpleIcon(slug: "mega", color: "D9272E"),
        "meilisearch.com": SimpleIcon(slug: "meilisearch", color: "FF5CAA"),
        "meituan.com": SimpleIcon(slug: "meituan", color: "FFD100"),
        "mendeley.com": SimpleIcon(slug: "mendeley", color: "9D1620"),
        "mentorcruise.com": SimpleIcon(slug: "mentorcruise", color: "172E59"),
        "mercadopago.com": SimpleIcon(slug: "mercadopago", color: "00B1EA"),
        "merck.com": SimpleIcon(slug: "merck", color: "007A73"),
        "meta.com": SimpleIcon(slug: "meta", color: "0467DF"),
        "metabase.com": SimpleIcon(slug: "metabase", color: "509EE3"),
        "metacritic.com": SimpleIcon(slug: "metacritic", color: "000000"),
        "metafilter.com": SimpleIcon(slug: "metafilter", color: "065A8F"),
        "metager.de": SimpleIcon(slug: "metager", color: "F47216"),
        "meteor.com": SimpleIcon(slug: "meteor", color: "DE4F4F"),
        "mewe.com": SimpleIcon(slug: "mewe", color: "17377F"),
        "mezmo.com": SimpleIcon(slug: "mezmo", color: "E9FF92"),
        "mg.co.uk": SimpleIcon(slug: "mg", color: "FF0000"),
        "micro.blog": SimpleIcon(slug: "microdotblog", color: "FF8800"),
        "microbit.org": SimpleIcon(slug: "microbit", color: "00ED00"),
        "microstrategy.com": SimpleIcon(slug: "microstrategy", color: "D9232E"),
        "migadu.com": SimpleIcon(slug: "migadu", color: "0043CE"),
        "mikrotik.com": SimpleIcon(slug: "mikrotik", color: "293239"),
        "milanote.com": SimpleIcon(slug: "milanote", color: "31303A"),
        "minds.com": SimpleIcon(slug: "minds", color: "FED12F"),
        "mingw-w64.org": SimpleIcon(slug: "mingww64", color: "000000"),
        "mini.com": SimpleIcon(slug: "mini", color: "000000"),
        "mintlify.com": SimpleIcon(slug: "mintlify", color: "18E299"),
        "minutemailer.com": SimpleIcon(slug: "minutemailer", color: "30B980"),
        "miraheze.org": SimpleIcon(slug: "miraheze", color: "FFFC00"),
        "miro.com": SimpleIcon(slug: "miro", color: "050038"),
        "mitsubishi.com": SimpleIcon(slug: "mitsubishi", color: "E60012"),
        "mix.com": SimpleIcon(slug: "mix", color: "FF8126"),
        "mixcloud.com": SimpleIcon(slug: "mixcloud", color: "5000FF"),
        "mixpanel.com": SimpleIcon(slug: "mixpanel", color: "7856FF"),
        "mlb.com": SimpleIcon(slug: "mlb", color: "041E42"),
        "mlh.io": SimpleIcon(slug: "majorleaguehacking", color: "265A8F"),
        "modal.com": SimpleIcon(slug: "modal", color: "7FEE64"),
        "modelscope.cn": SimpleIcon(slug: "modelscope", color: "624AFF"),
        "modin.org": SimpleIcon(slug: "modin", color: "001729"),
        "modx.com": SimpleIcon(slug: "modx", color: "102C53"),
        "mojeek.com": SimpleIcon(slug: "mojeek", color: "7AB93C"),
        "moleculer.services": SimpleIcon(slug: "moleculer", color: "3CAFCE"),
        "momenteo.com": SimpleIcon(slug: "momenteo", color: "5A6AB1"),
        "moneygram.com": SimpleIcon(slug: "moneygram", color: "DA291C"),
        "mongodb.com": SimpleIcon(slug: "mongodb", color: "47A248"),
        "mongoose.ws": SimpleIcon(slug: "mongoosedotws", color: "F04D35"),
        "monkey-tie.com": SimpleIcon(slug: "monkeytie", color: "1A52C2"),
        "monogame.net": SimpleIcon(slug: "monogame", color: "E73C00"),
        "monoprix.fr": SimpleIcon(slug: "monoprix", color: "FB1911"),
        "monster.com": SimpleIcon(slug: "monster", color: "6D4C9F"),
        "monzo.com": SimpleIcon(slug: "monzo", color: "14233C"),
        "moo.com": SimpleIcon(slug: "moo", color: "00945E"),
        "moodle.com": SimpleIcon(slug: "moodle", color: "F98012"),
        "moonrepo.dev": SimpleIcon(slug: "moonrepo", color: "6F53F3"),
        "moqups.com": SimpleIcon(slug: "moqups", color: "006BE5"),
        "morrisons.com": SimpleIcon(slug: "morrisons", color: "007531"),
        "mozilla.com": SimpleIcon(slug: "mozilla", color: "161616"),
        "mpg.de": SimpleIcon(slug: "maxplanckgesellschaft", color: "006C66"),
        "mqtt.org": SimpleIcon(slug: "mqtt", color: "660066"),
        "msi.com": SimpleIcon(slug: "msi", color: "FF0000"),
        "mta.info": SimpleIcon(slug: "mta", color: "0039A6"),
        "mubi.com": SimpleIcon(slug: "mubi", color: "000000"),
        "mullvad.net": SimpleIcon(slug: "mullvad", color: "294D73"),
        "multisim.com": SimpleIcon(slug: "multisim", color: "57B685"),
        "mural.co": SimpleIcon(slug: "mural", color: "FF4B4B"),
        "mxlinux.org": SimpleIcon(slug: "mxlinux", color: "000000"),
        "myanimelist.net": SimpleIcon(slug: "myanimelist", color: "2E51A2"),
        "myget.org": SimpleIcon(slug: "myget", color: "0C79CE"),
        "myob.com": SimpleIcon(slug: "myob", color: "7B14EF"),
        "myshows.me": SimpleIcon(slug: "myshows", color: "CC0000"),
        "myspace.com": SimpleIcon(slug: "myspace", color: "030303"),
        "mysql.com": SimpleIcon(slug: "mysql", color: "4479A1"),
        "n26.com": SimpleIcon(slug: "n26", color: "48AC98"),
        "n8n.io": SimpleIcon(slug: "n8n", color: "EA4B71"),
        "namebase.io": SimpleIcon(slug: "namebase", color: "0068FF"),
        "namecheap.com": SimpleIcon(slug: "namecheap", color: "DE3723"),
        "namemc.com": SimpleIcon(slug: "namemc", color: "12161A"),
        "namesilo.com": SimpleIcon(slug: "namesilo", color: "031B4E"),
        "nano.org": SimpleIcon(slug: "nano", color: "209CE9"),
        "napster.com": SimpleIcon(slug: "napster", color: "2259FF"),
        "nasa.gov": SimpleIcon(slug: "nasa", color: "E03C31"),
        "nationalgrid.com": SimpleIcon(slug: "nationalgrid", color: "00148C"),
        "nativescript.org": SimpleIcon(slug: "nativescript", color: "65ADF1"),
        "naver.com": SimpleIcon(slug: "naver", color: "03C75A"),
        "nba.com": SimpleIcon(slug: "nba", color: "253B73"),
        "ndi.video": SimpleIcon(slug: "ndi", color: "000000"),
        "ndr.de": SimpleIcon(slug: "ndr", color: "0C1754"),
        "near.org": SimpleIcon(slug: "near", color: "000000"),
        "nebula.tv": SimpleIcon(slug: "nebula", color: "2CADFE"),
        "neo4j.com": SimpleIcon(slug: "neo4j", color: "4581C3"),
        "neon.com": SimpleIcon(slug: "neon", color: "34D59A"),
        "neovim.io": SimpleIcon(slug: "neovim", color: "57A143"),
        "neptune.ai": SimpleIcon(slug: "neptune", color: "5B69C2"),
        "nestjs.com": SimpleIcon(slug: "nestjs", color: "E0234E"),
        "netapp.com": SimpleIcon(slug: "netapp", color: "0067C5"),
        "netbsd.org": SimpleIcon(slug: "netbsd", color: "FF6600"),
        "netcup.de": SimpleIcon(slug: "netcup", color: "056473"),
        "netcup.eu": SimpleIcon(slug: "netcup", color: "056473"),
        "netdata.cloud": SimpleIcon(slug: "netdata", color: "00AB44"),
        "netflix.com": SimpleIcon(slug: "netflix", color: "E50914"),
        "netgear.com": SimpleIcon(slug: "netgear", color: "2C262D"),
        "netgear.de": SimpleIcon(slug: "netgear", color: "2C262D"),
        "netim.com": SimpleIcon(slug: "netim", color: "FE8427"),
        "netlify.com": SimpleIcon(slug: "netlify", color: "00C7B7"),
        "nette.org": SimpleIcon(slug: "nette", color: "3484D2"),
        "newbalance.com": SimpleIcon(slug: "newbalance", color: "CF0A2C"),
        "newegg.com": SimpleIcon(slug: "newegg", color: "E05E00"),
        "newgrounds.com": SimpleIcon(slug: "newgrounds", color: "FDA238"),
        "newrelic.com": SimpleIcon(slug: "newrelic", color: "1CE783"),
        "nexon.com": SimpleIcon(slug: "nexon", color: "000000"),
        "nextbike.net": SimpleIcon(slug: "nextbike", color: "0046D7"),
        "nextbillion.ai": SimpleIcon(slug: "nextbilliondotai", color: "8D5A9E"),
        "nextcloud.com": SimpleIcon(slug: "nextcloud", color: "0082C9"),
        "nextdoor.com": SimpleIcon(slug: "nextdoor", color: "8ED500"),
        "nextra.site": SimpleIcon(slug: "nextra", color: "000000"),
        "nginx.com": SimpleIcon(slug: "nginx", color: "009639"),
        "ngrok.com": SimpleIcon(slug: "ngrok", color: "1F1E37"),
        "ngrx.io": SimpleIcon(slug: "ngrx", color: "BA2BD2"),
        "nhl.com": SimpleIcon(slug: "nhl", color: "000000"),
        "nhost.io": SimpleIcon(slug: "nhost", color: "0052CD"),
        "nicehash.com": SimpleIcon(slug: "nicehash", color: "FBC342"),
        "nike.com": SimpleIcon(slug: "nike", color: "111111"),
        "nikon.com": SimpleIcon(slug: "nikon", color: "FFE100"),
        "nissan.ie": SimpleIcon(slug: "nissan", color: "C3002F"),
        "nodejs.org": SimpleIcon(slug: "nodedotjs", color: "5FA04E"),
        "nodemon.io": SimpleIcon(slug: "nodemon", color: "76D04B"),
        "nodered.org": SimpleIcon(slug: "nodered", color: "8F0000"),
        "nokia.com": SimpleIcon(slug: "nokia", color: "005AFF"),
        "norco.com": SimpleIcon(slug: "norco", color: "00FF00"),
        "nordvpn.com": SimpleIcon(slug: "nordvpn", color: "4687FF"),
        "norton.com": SimpleIcon(slug: "norton", color: "FFE01A"),
        "norwegian.com": SimpleIcon(slug: "norwegian", color: "D81939"),
        "note.jp": SimpleIcon(slug: "note", color: "000000"),
        "notebooklm.google": SimpleIcon(slug: "notebooklm", color: "000000"),
        "notion.com": SimpleIcon(slug: "notion", color: "000000"),
        "notion.so": SimpleIcon(slug: "notion", color: "000000"),
        "novu.co": SimpleIcon(slug: "novu", color: "000000"),
        "npmjs.com": SimpleIcon(slug: "npm", color: "CB3837"),
        "nrwl.io": SimpleIcon(slug: "nrwl", color: "96D7E8"),
        "ns.nl": SimpleIcon(slug: "nederlandsespoorwegen", color: "003082"),
        "ntfy.sh": SimpleIcon(slug: "ntfy", color: "317F6F"),
        "nubank.com.br": SimpleIcon(slug: "nubank", color: "820AD1"),
        "numpy.org": SimpleIcon(slug: "numpy", color: "013243"),
        "nutanix.com": SimpleIcon(slug: "nutanix", color: "024DA1"),
        "nuxt.com": SimpleIcon(slug: "nuxt", color: "00DC82"),
        "nvidia.com": SimpleIcon(slug: "nvidia", color: "76B900"),
        "nx.dev": SimpleIcon(slug: "nx", color: "143055"),
        "nxp.com": SimpleIcon(slug: "nxp", color: "000000"),
        "nzxt.com": SimpleIcon(slug: "nzxt", color: "000000"),
        "obsidian.md": SimpleIcon(slug: "obsidian", color: "7C3AED"),
        "ocaml.org": SimpleIcon(slug: "ocaml", color: "EC6813"),
        "oclc.org": SimpleIcon(slug: "oclc", color: "007DBA"),
        "octobercms.com": SimpleIcon(slug: "octobercms", color: "DB6A26"),
        "odido.nl": SimpleIcon(slug: "odido", color: "2C72FF"),
        "odoo.com": SimpleIcon(slug: "odoo", color: "714B67"),
        "odysee.com": SimpleIcon(slug: "odysee", color: "EF1970"),
        "ohdear.app": SimpleIcon(slug: "ohdear", color: "FF3900"),
        "okcupid.com": SimpleIcon(slug: "okcupid", color: "0500BE"),
        "okta.com": SimpleIcon(slug: "okta", color: "007DC1"),
        "omarchy.org": SimpleIcon(slug: "omarchy", color: "9ECE6A"),
        "oneplus.com": SimpleIcon(slug: "oneplus", color: "F5010C"),
        "onestream.com": SimpleIcon(slug: "onestream", color: "000000"),
        "onlyfans.com": SimpleIcon(slug: "onlyfans", color: "00AFF0"),
        "onlyoffice.com": SimpleIcon(slug: "onlyoffice", color: "444444"),
        "onstar.com": SimpleIcon(slug: "onstar", color: "003D7D"),
        "openai.com": SimpleIcon(slug: "openai", color: "412991", packageVersion: "15.22.0"),
        "openbadges.org": SimpleIcon(slug: "openbadges", color: "073B5A"),
        "openbao.org": SimpleIcon(slug: "openbao", color: "336D5C"),
        "openbugbounty.org": SimpleIcon(slug: "openbugbounty", color: "F67909"),
        "opencollective.com": SimpleIcon(slug: "opencollective", color: "7FADF2"),
        "opencv.org": SimpleIcon(slug: "opencv", color: "5C3EE8"),
        "openfaas.com": SimpleIcon(slug: "openfaas", color: "3B5EE9"),
        "openhab.org": SimpleIcon(slug: "openhab", color: "E64A19"),
        "openid.net": SimpleIcon(slug: "openid", color: "F78C40"),
        "openmined.org": SimpleIcon(slug: "openmined", color: "ED986C"),
        "opennebula.io": SimpleIcon(slug: "opennebula", color: "0097C2"),
        "openproject.org": SimpleIcon(slug: "openproject", color: "0770B8"),
        "openrouter.ai": SimpleIcon(slug: "openrouter", color: "94A3B8"),
        "opensea.io": SimpleIcon(slug: "opensea", color: "2081E2"),
        "opensearch.org": SimpleIcon(slug: "opensearch", color: "005EB8"),
        "openssl.org": SimpleIcon(slug: "openssl", color: "721412"),
        "openstack.org": SimpleIcon(slug: "openstack", color: "ED1944"),
        "openstreetmap.org": SimpleIcon(slug: "openstreetmap", color: "7EBC6F"),
        "opensuse.org": SimpleIcon(slug: "opensuse", color: "73BA25"),
        "opentext.com": SimpleIcon(slug: "opentext", color: "000000"),
        "openvpn.net": SimpleIcon(slug: "openvpn", color: "EA7E20"),
        "openwrt.org": SimpleIcon(slug: "openwrt", color: "00B5E2"),
        "openzeppelin.com": SimpleIcon(slug: "openzeppelin", color: "4E5EE4"),
        "opera.com": SimpleIcon(slug: "opera", color: "FF1B2D"),
        "oppo.com": SimpleIcon(slug: "oppo", color: "2D683D"),
        "opslevel.com": SimpleIcon(slug: "opslevel", color: "0A53E0"),
        "optuna.org": SimpleIcon(slug: "optuna", color: "002C76"),
        "orange.com": SimpleIcon(slug: "orange", color: "FF7900"),
        "orchardcore.net": SimpleIcon(slug: "orchardcore", color: "41B670"),
        "orcid.org": SimpleIcon(slug: "orcid", color: "A6CE39"),
        "oreilly.com": SimpleIcon(slug: "oreilly", color: "D3002D"),
        "organicmaps.app": SimpleIcon(slug: "organicmaps", color: "006C35"),
        "origin.com": SimpleIcon(slug: "origin", color: "F56C2D"),
        "ory.com": SimpleIcon(slug: "ory", color: "4F46E5"),
        "osano.com": SimpleIcon(slug: "osano", color: "7764FA"),
        "osgeo.org": SimpleIcon(slug: "osgeo", color: "4CB05B"),
        "overcast.fm": SimpleIcon(slug: "overcast", color: "FC7E0F"),
        "overleaf.com": SimpleIcon(slug: "overleaf", color: "47A141"),
        "ovh.com": SimpleIcon(slug: "ovh", color: "123F6D"),
        "owncloud.com": SimpleIcon(slug: "owncloud", color: "041E42"),
        "p5js.org": SimpleIcon(slug: "p5dotjs", color: "ED225D"),
        "paddle.com": SimpleIcon(slug: "paddle", color: "FDDD35"),
        "paddlepaddle.org.cn": SimpleIcon(slug: "paddlepaddle", color: "0062B0"),
        "paddypower.com": SimpleIcon(slug: "paddypower", color: "004833"),
        "padlet.com": SimpleIcon(slug: "padlet", color: "FF4081"),
        "pagekit.com": SimpleIcon(slug: "pagekit", color: "212121"),
        "pagerduty.com": SimpleIcon(slug: "pagerduty", color: "06AC38"),
        "paloaltonetworks.com": SimpleIcon(slug: "paloaltonetworks", color: "F04E23"),
        "panasonic.com": SimpleIcon(slug: "panasonic", color: "0049AB"),
        "paperspace.com": SimpleIcon(slug: "paperspace", color: "000000"),
        "paperswithcode.com": SimpleIcon(slug: "paperswithcode", color: "21CBCE"),
        "paradoxinteractive.com": SimpleIcon(slug: "paradoxinteractive", color: "101010"),
        "paramount.com": SimpleIcon(slug: "paramountplus", color: "0064FF"),
        "parse.ly": SimpleIcon(slug: "parsedotly", color: "5BA745"),
        "passbolt.com": SimpleIcon(slug: "passbolt", color: "D40101"),
        "pastebin.com": SimpleIcon(slug: "pastebin", color: "02456C"),
        "patreon.com": SimpleIcon(slug: "patreon", color: "000000"),
        "payback.de": SimpleIcon(slug: "payback", color: "003EB0"),
        "paychex.com": SimpleIcon(slug: "paychex", color: "004B8D"),
        "payhip.com": SimpleIcon(slug: "payhip", color: "5C6AC4"),
        "payloadcms.com": SimpleIcon(slug: "payloadcms", color: "000000"),
        "payoneer.com": SimpleIcon(slug: "payoneer", color: "FF4800"),
        "paypal.com": SimpleIcon(slug: "paypal", color: "002991"),
        "paysafe.com": SimpleIcon(slug: "paysafe", color: "5A28FF"),
        "paytm.com": SimpleIcon(slug: "paytm", color: "20336B"),
        "pcgamingwiki.com": SimpleIcon(slug: "pcgamingwiki", color: "556DB3"),
        "pdq.com": SimpleIcon(slug: "pdq", color: "231F20"),
        "peakdesign.com": SimpleIcon(slug: "peakdesign", color: "1C1B1C"),
        "pearson.com": SimpleIcon(slug: "pearson", color: "000000"),
        "peerlist.io": SimpleIcon(slug: "peerlist", color: "00AA45"),
        "penny.de": SimpleIcon(slug: "penny", color: "CD1414"),
        "penpot.app": SimpleIcon(slug: "penpot", color: "000000"),
        "percy.io": SimpleIcon(slug: "percy", color: "9E66BF"),
        "perplexity.ai": SimpleIcon(slug: "perplexity", color: "1FB8CD"),
        "persistent.com": SimpleIcon(slug: "persistent", color: "FD5F07"),
        "personio.com": SimpleIcon(slug: "personio", color: "000000"),
        "petsathome.com": SimpleIcon(slug: "petsathome", color: "00AA28"),
        "peugeot.co.uk": SimpleIcon(slug: "peugeot", color: "000000"),
        "pexels.com": SimpleIcon(slug: "pexels", color: "05A081"),
        "pfsense.org": SimpleIcon(slug: "pfsense", color: "212121"),
        "philips-hue.com": SimpleIcon(slug: "philipshue", color: "0065D3"),
        "phonepe.com": SimpleIcon(slug: "phonepe", color: "5F259F"),
        "phosphoricons.com": SimpleIcon(slug: "phosphoricons", color: "3C402B"),
        "photobucket.com": SimpleIcon(slug: "photobucket", color: "1C47CB"),
        "photocrowd.com": SimpleIcon(slug: "photocrowd", color: "3DAD4B"),
        "php.net": SimpleIcon(slug: "php", color: "777BB4"),
        "phpbb.com": SimpleIcon(slug: "phpbb", color: "009BDF"),
        "pi-hole.net": SimpleIcon(slug: "pihole", color: "96060C"),
        "piaggiogroup.com": SimpleIcon(slug: "piaggiogroup", color: "000000"),
        "picarto.tv": SimpleIcon(slug: "picartodottv", color: "1DA456"),
        "picnic.app": SimpleIcon(slug: "picnic", color: "E1171E"),
        "picpay.com": SimpleIcon(slug: "picpay", color: "21C25E"),
        "picrew.me": SimpleIcon(slug: "picrew", color: "FFBD16"),
        "picsart.com": SimpleIcon(slug: "picsart", color: "C209C1"),
        "picxy.com": SimpleIcon(slug: "picxy", color: "2E3192"),
        "pimcore.com": SimpleIcon(slug: "pimcore", color: "6428B4"),
        "pingdom.com": SimpleIcon(slug: "pingdom", color: "FFF000"),
        "pinterest.com": SimpleIcon(slug: "pinterest", color: "BD081C"),
        "pioneerdj.com": SimpleIcon(slug: "pioneerdj", color: "1A1928"),
        "pipecat.ai": SimpleIcon(slug: "pipecat", color: "000000"),
        "pivotaltracker.com": SimpleIcon(slug: "pivotaltracker", color: "517A9E"),
        "pixabay.com": SimpleIcon(slug: "pixabay", color: "191B26"),
        "pixelfed.org": SimpleIcon(slug: "pixelfed", color: "6366F1"),
        "pixiv.net": SimpleIcon(slug: "pixiv", color: "0096FA"),
        "pixlr.com": SimpleIcon(slug: "pixlr", color: "3EBBDF"),
        "pkgsrc.org": SimpleIcon(slug: "pkgsrc", color: "FF6600"),
        "plane.so": SimpleIcon(slug: "plane", color: "121212"),
        "planet.com": SimpleIcon(slug: "planet", color: "009DB1"),
        "planetscale.com": SimpleIcon(slug: "planetscale", color: "000000"),
        "plangrid.com": SimpleIcon(slug: "plangrid", color: "0085DE"),
        "platform.sh": SimpleIcon(slug: "platformdotsh", color: "1A182A"),
        "playcanvas.com": SimpleIcon(slug: "playcanvas", color: "E05F2C"),
        "player.me": SimpleIcon(slug: "playerdotme", color: "C0379A"),
        "playstation.com": SimpleIcon(slug: "playstation", color: "0070D1"),
        "pleroma.social": SimpleIcon(slug: "pleroma", color: "FBA457"),
        "plesk.com": SimpleIcon(slug: "plesk", color: "52BBE6"),
        "plex.tv": SimpleIcon(slug: "plex", color: "EBAF00"),
        "plotly.com": SimpleIcon(slug: "plotly", color: "7A76FF"),
        "plume.com": SimpleIcon(slug: "plume", color: "7C5CDF"),
        "pluralsight.com": SimpleIcon(slug: "pluralsight", color: "F15B2A"),
        "plurk.com": SimpleIcon(slug: "plurk", color: "FF574D"),
        "pnpm.io": SimpleIcon(slug: "pnpm", color: "F69220"),
        "pocketcasts.com": SimpleIcon(slug: "pocketcasts", color: "F43E37"),
        "podcastaddict.com": SimpleIcon(slug: "podcastaddict", color: "F4842D"),
        "podcastindex.org": SimpleIcon(slug: "podcastindex", color: "F90000"),
        "podman.io": SimpleIcon(slug: "podman", color: "892CA0"),
        "poe.com": SimpleIcon(slug: "poe", color: "5D5CDE"),
        "polkadot.network": SimpleIcon(slug: "polkadot", color: "E6007A"),
        "poly.com": SimpleIcon(slug: "poly", color: "EB3C00"),
        "polygon.technology": SimpleIcon(slug: "polygon", color: "7B3FE4"),
        "polywork.com": SimpleIcon(slug: "polywork", color: "543DE0"),
        "pomerium.com": SimpleIcon(slug: "pomerium", color: "6F43E7"),
        "pond5.com": SimpleIcon(slug: "pond5", color: "000000"),
        "porkbun.design": SimpleIcon(slug: "porkbun", color: "EF7878"),
        "porsche.com": SimpleIcon(slug: "porsche", color: "B12B28"),
        "portainer.io": SimpleIcon(slug: "portainer", color: "13BEF9"),
        "portswigger.net": SimpleIcon(slug: "portswigger", color: "FF6633"),
        "posit.co": SimpleIcon(slug: "posit", color: "447099"),
        "postcss.org": SimpleIcon(slug: "postcss", color: "DD3A0A"),
        "postgresql.org": SimpleIcon(slug: "postgresql", color: "4169E1"),
        "posthog.com": SimpleIcon(slug: "posthog", color: "000000"),
        "postiz.com": SimpleIcon(slug: "postiz", color: "612BD3"),
        "postman.com": SimpleIcon(slug: "postman", color: "FF6C37"),
        "postmates.com": SimpleIcon(slug: "postmates", color: "FFDF18"),
        "pr.co": SimpleIcon(slug: "prdotco", color: "0080FF"),
        "prefect.io": SimpleIcon(slug: "prefect", color: "070E10"),
        "premierleague.com": SimpleIcon(slug: "premierleague", color: "360D3A"),
        "prepbytes.com": SimpleIcon(slug: "prepbytes", color: "5A87C6"),
        "prestashop.com": SimpleIcon(slug: "prestashop", color: "DF0067"),
        "pretzel.rocks": SimpleIcon(slug: "pretzel", color: "1BB3A4"),
        "prevention.com": SimpleIcon(slug: "prevention", color: "44C1C5"),
        "prezi.com": SimpleIcon(slug: "prezi", color: "3181FF"),
        "primefaces.org": SimpleIcon(slug: "primefaces", color: "263238"),
        "printables.com": SimpleIcon(slug: "printables", color: "FA6831"),
        "prismic.io": SimpleIcon(slug: "prismic", color: "5163BA"),
        "privatedivision.com": SimpleIcon(slug: "privatedivision", color: "000000"),
        "privateinternetaccess.com": SimpleIcon(slug: "privateinternetaccess", color: "1E811F"),
        "processingfoundation.org": SimpleIcon(slug: "processingfoundation", color: "006699"),
        "processon.com": SimpleIcon(slug: "processon", color: "067BEF"),
        "processwire.com": SimpleIcon(slug: "processwire", color: "2480E6"),
        "producthunt.com": SimpleIcon(slug: "producthunt", color: "DA552F"),
        "progate.com": SimpleIcon(slug: "progate", color: "380953"),
        "progress.com": SimpleIcon(slug: "progress", color: "5CE500"),
        "prometheus.io": SimpleIcon(slug: "prometheus", color: "E6522C"),
        "pronouns.page": SimpleIcon(slug: "pronounsdotpage", color: "C71585"),
        "prosieben.de": SimpleIcon(slug: "prosieben", color: "E6000F"),
        "proto.io": SimpleIcon(slug: "protodotio", color: "34A7C1"),
        "protocols.io": SimpleIcon(slug: "protocolsdotio", color: "4D9FE7"),
        "proton.me": SimpleIcon(slug: "proton", color: "6D4AFF"),
        "protondb.com": SimpleIcon(slug: "protondb", color: "F50057"),
        "proxmox.com": SimpleIcon(slug: "proxmox", color: "E57000"),
        "publons.com": SimpleIcon(slug: "publons", color: "336699"),
        "pulumi.com": SimpleIcon(slug: "pulumi", color: "8A3391"),
        "puma.com": SimpleIcon(slug: "puma", color: "242B2F"),
        "puppet.com": SimpleIcon(slug: "puppet", color: "FFAE1A"),
        "pushbullet.com": SimpleIcon(slug: "pushbullet", color: "4AB367"),
        "pusher.com": SimpleIcon(slug: "pusher", color: "300D4F"),
        "pypi.org": SimpleIcon(slug: "pypi", color: "3775A9"),
        "pypy.org": SimpleIcon(slug: "pypy", color: "193440"),
        "python.org": SimpleIcon(slug: "python", color: "3776AB"),
        "pythonanywhere.com": SimpleIcon(slug: "pythonanywhere", color: "1D9FD7"),
        "pyup.io": SimpleIcon(slug: "pyup", color: "9F55FF"),
        "qantas.com": SimpleIcon(slug: "qantas", color: "E40000"),
        "qase.io": SimpleIcon(slug: "qase", color: "4F46DC"),
        "qatarairways.com": SimpleIcon(slug: "qatarairways", color: "5C0D34"),
        "qdrant.tech": SimpleIcon(slug: "qdrant", color: "DC244C"),
        "qemu.org": SimpleIcon(slug: "qemu", color: "FF6600"),
        "qgis.org": SimpleIcon(slug: "qgis", color: "589632"),
        "qiita.com": SimpleIcon(slug: "qiita", color: "55C500"),
        "qiskit.org": SimpleIcon(slug: "qiskit", color: "6929C4"),
        "qiwi.com": SimpleIcon(slug: "qiwi", color: "FF8C00"),
        "qlik.com": SimpleIcon(slug: "qlik", color: "009848"),
        "qnap.com": SimpleIcon(slug: "qnap", color: "0C2E82"),
        "qodo.ai": SimpleIcon(slug: "qodo", color: "7968FA"),
        "qq.design": SimpleIcon(slug: "qq", color: "1EBAFC"),
        "qt.io": SimpleIcon(slug: "qt", color: "41CD52"),
        "qualcomm.com": SimpleIcon(slug: "qualcomm", color: "3253DC"),
        "qualtrics.com": SimpleIcon(slug: "qualtrics", color: "00B4EF"),
        "qualys.com": SimpleIcon(slug: "qualys", color: "ED2E26"),
        "quantcast.com": SimpleIcon(slug: "quantcast", color: "000000"),
        "quantconnect.com": SimpleIcon(slug: "quantconnect", color: "F98309"),
        "quarto.org": SimpleIcon(slug: "quarto", color: "39729E"),
        "quest.com": SimpleIcon(slug: "quest", color: "FB4F14"),
        "quizlet.com": SimpleIcon(slug: "quizlet", color: "4255FF"),
        "quora.com": SimpleIcon(slug: "quora", color: "B92B27"),
        "qwant.com": SimpleIcon(slug: "qwant", color: "282B2F"),
        "qwen.ai": SimpleIcon(slug: "qwen", color: "6950EF"),
        "r3.com": SimpleIcon(slug: "r3", color: "EC1D24"),
        "rabbitmq.com": SimpleIcon(slug: "rabbitmq", color: "FF6600"),
        "radar.io": SimpleIcon(slug: "radar", color: "007AFF"),
        "radiofrance.fr": SimpleIcon(slug: "radiofrance", color: "2B00E7"),
        "radix-ui.com": SimpleIcon(slug: "radixui", color: "161618"),
        "railway.app": SimpleIcon(slug: "railway", color: "0B0D0E"),
        "rainyun.com": SimpleIcon(slug: "rainyun", color: "DAD9D9"),
        "rakuten.com": SimpleIcon(slug: "rakuten", color: "BF0000"),
        "rancher.com": SimpleIcon(slug: "rancher", color: "0075A8"),
        "rarible.com": SimpleIcon(slug: "rarible", color: "FEDA03"),
        "rasa.com": SimpleIcon(slug: "rasa", color: "5A17EE"),
        "raspberrypi.org": SimpleIcon(slug: "raspberrypi", color: "A22846"),
        "ravelry.com": SimpleIcon(slug: "ravelry", color: "EE6E62"),
        "raycast.com": SimpleIcon(slug: "raycast", color: "FF6363"),
        "razer.com": SimpleIcon(slug: "razer", color: "00FF00"),
        "razorpay.com": SimpleIcon(slug: "razorpay", color: "0C2451"),
        "read.cv": SimpleIcon(slug: "readdotcv", color: "111111"),
        "readme.com": SimpleIcon(slug: "readme", color: "018EF5"),
        "reasonstudios.com": SimpleIcon(slug: "reasonstudios", color: "FFFFFF"),
        "redbubble.com": SimpleIcon(slug: "redbubble", color: "E41321"),
        "redbull.com": SimpleIcon(slug: "redbull", color: "DB0A40"),
        "redcandlegames.com": SimpleIcon(slug: "redcandlegames", color: "D23735"),
        "reddit.com": SimpleIcon(slug: "reddit", color: "FF4500"),
        "redhat.com": SimpleIcon(slug: "redhat", color: "EE0000"),
        "redis.io": SimpleIcon(slug: "redis", color: "FF4438"),
        "redmine.org": SimpleIcon(slug: "redmine", color: "B32024"),
        "redsys.es": SimpleIcon(slug: "redsys", color: "DC7C26"),
        "redwoodjs.com": SimpleIcon(slug: "redwoodjs", color: "BF4722"),
        "reebok.com": SimpleIcon(slug: "reebok", color: "E41D1B"),
        "refine.dev": SimpleIcon(slug: "refine", color: "14141F"),
        "reflex.dev": SimpleIcon(slug: "reflex", color: "6E56CF"),
        "reka-ui.com": SimpleIcon(slug: "rekaui", color: "16A353"),
        "relay.dev": SimpleIcon(slug: "relay", color: "F26B00"),
        "remove.bg": SimpleIcon(slug: "removedotbg", color: "54616C"),
        "render.com": SimpleIcon(slug: "render", color: "000000"),
        "renpy.org": SimpleIcon(slug: "renpy", color: "FF7F7F"),
        "replicate.com": SimpleIcon(slug: "replicate", color: "000000"),
        "rescuetime.com": SimpleIcon(slug: "rescuetime", color: "161A3B"),
        "researchgate.net": SimpleIcon(slug: "researchgate", color: "00CCBB"),
        "resend.com": SimpleIcon(slug: "resend", color: "000000"),
        "retool.com": SimpleIcon(slug: "retool", color: "3D3D3D"),
        "revanced.app": SimpleIcon(slug: "revanced", color: "9ED5FF"),
        "revealjs.com": SimpleIcon(slug: "revealdotjs", color: "F2E142"),
        "revenuecat.com": SimpleIcon(slug: "revenuecat", color: "F2545B"),
        "reverbnation.com": SimpleIcon(slug: "reverbnation", color: "E43526"),
        "revolt.chat": SimpleIcon(slug: "revoltdotchat", color: "FF4655"),
        "revolut.com": SimpleIcon(slug: "revolut", color: "191C1F"),
        "rewe.de": SimpleIcon(slug: "rewe", color: "CC071E"),
        "rezgo.com": SimpleIcon(slug: "rezgo", color: "F76C00"),
        "ril.com": SimpleIcon(slug: "relianceindustrieslimited", color: "D1AB66"),
        "rimac-automobili.com": SimpleIcon(slug: "rimacautomobili", color: "0A222E"),
        "ring.com": SimpleIcon(slug: "ring", color: "1C9AD6"),
        "riotgames.com": SimpleIcon(slug: "riotgames", color: "EB0029"),
        "ripple.com": SimpleIcon(slug: "ripple", color: "0085C0"),
        "riscv.org": SimpleIcon(slug: "riscv", color: "283272"),
        "riseup.net": SimpleIcon(slug: "riseup", color: "FF0000"),
        "ritzcarlton.com": SimpleIcon(slug: "ritzcarlton", color: "000000"),
        "rive.app": SimpleIcon(slug: "rive", color: "1D1D1D"),
        "roadmap.sh": SimpleIcon(slug: "roadmapdotsh", color: "000000"),
        "roamresearch.com": SimpleIcon(slug: "roamresearch", color: "343A40"),
        "robinhood.com": SimpleIcon(slug: "robinhood", color: "CCFF00"),
        "roblox.com": SimpleIcon(slug: "roblox", color: "000000"),
        "roboflow.com": SimpleIcon(slug: "roboflow", color: "6706CE"),
        "rocket.chat": SimpleIcon(slug: "rocketdotchat", color: "F5455C"),
        "rocket.rs": SimpleIcon(slug: "rocket", color: "D33847"),
        "rockstargames.com": SimpleIcon(slug: "rockstargames", color: "FCAF17"),
        "rockwellautomation.com": SimpleIcon(slug: "rockwellautomation", color: "CD163F"),
        "roku.com": SimpleIcon(slug: "roku", color: "662D91"),
        "roll20.net": SimpleIcon(slug: "roll20", color: "E10085"),
        "rollbar.com": SimpleIcon(slug: "rollbar", color: "3569F3"),
        "rollupjs.org": SimpleIcon(slug: "rollupdotjs", color: "EC4A3F"),
        "root-me.org": SimpleIcon(slug: "rootme", color: "000000"),
        "root.cern": SimpleIcon(slug: "root", color: "1ED3E4"),
        "roots.io": SimpleIcon(slug: "roots", color: "525DDC"),
        "ros.org": SimpleIcon(slug: "ros", color: "22314E"),
        "rossmann.de": SimpleIcon(slug: "rossmann", color: "C3002D"),
        "roundcube.net": SimpleIcon(slug: "roundcube", color: "37BEFF"),
        "rsocket.io": SimpleIcon(slug: "rsocket", color: "EF0092"),
        "rte.ie": SimpleIcon(slug: "rte", color: "00A7B3"),
        "rtl.de": SimpleIcon(slug: "rtl", color: "FA002E"),
        "rtm.fr": SimpleIcon(slug: "rtm", color: "36474F"),
        "rubygems.org": SimpleIcon(slug: "rubygems", color: "E9573F"),
        "rubyonrails.org": SimpleIcon(slug: "rubyonrails", color: "D30001"),
        "rumahweb.com": SimpleIcon(slug: "rumahweb", color: "2EB4E3"),
        "rumble.com": SimpleIcon(slug: "rumble", color: "85C742"),
        "runkeeper.com": SimpleIcon(slug: "runkeeper", color: "001E62"),
        "runrun.it": SimpleIcon(slug: "runrundotit", color: "DB3729"),
        "rustfs.com": SimpleIcon(slug: "rustfs", color: "0196D0"),
        "ryanair.com": SimpleIcon(slug: "ryanair", color: "073590"),
        "sabanci.com": SimpleIcon(slug: "sabanci", color: "004B93"),
        "sage.com": SimpleIcon(slug: "sage", color: "00D639"),
        "sahibinden.com": SimpleIcon(slug: "sahibinden", color: "FFE800"),
        "sailfishos.org": SimpleIcon(slug: "sailfishos", color: "053766"),
        "sailsjs.com": SimpleIcon(slug: "sailsdotjs", color: "14ACC2"),
        "salesforce.com": SimpleIcon(slug: "salesforce", color: "00A1E0", packageVersion: "15.22.0"),
        "salla.com": SimpleIcon(slug: "salla", color: "BAF3E6"),
        "saltproject.io": SimpleIcon(slug: "saltproject", color: "57BCAD"),
        "samsclub.com": SimpleIcon(slug: "samsclub", color: "0067A0"),
        "samsung.com": SimpleIcon(slug: "samsung", color: "1428A0"),
        "sap.com": SimpleIcon(slug: "sap", color: "0FAAFF"),
        "sartorius.com": SimpleIcon(slug: "sartorius", color: "FFED00"),
        "satellite.me": SimpleIcon(slug: "satellite", color: "000000"),
        "saturn.de": SimpleIcon(slug: "saturn", color: "EB680B"),
        "saucelabs.com": SimpleIcon(slug: "saucelabs", color: "3DDC91"),
        "scalar.com": SimpleIcon(slug: "scalar", color: "1A1A1A"),
        "scaleway.com": SimpleIcon(slug: "scaleway", color: "4F0599"),
        "scan.co.uk": SimpleIcon(slug: "scan", color: "004C97"),
        "scania.com": SimpleIcon(slug: "scania", color: "041E42"),
        "scopus.com": SimpleIcon(slug: "scopus", color: "E9711C"),
        "scrapbox.io": SimpleIcon(slug: "scrapbox", color: "06B632"),
        "screencastify.com": SimpleIcon(slug: "screencastify", color: "FF8282"),
        "scrimba.com": SimpleIcon(slug: "scrimba", color: "2B283A"),
        "scrumalliance.org": SimpleIcon(slug: "scrumalliance", color: "009FDA"),
        "scrutinizer-ci.com": SimpleIcon(slug: "scrutinizerci", color: "8A9296"),
        "scylladb.com": SimpleIcon(slug: "scylladb", color: "6CD5E7"),
        "se.com": SimpleIcon(slug: "schneiderelectric", color: "3DCD58"),
        "seafile.com": SimpleIcon(slug: "seafile", color: "FF9800"),
        "seagate.com": SimpleIcon(slug: "seagate", color: "6EBE49"),
        "searxng.org": SimpleIcon(slug: "searxng", color: "3050FF"),
        "seat.es": SimpleIcon(slug: "seat", color: "33302E"),
        "seatgeek.com": SimpleIcon(slug: "seatgeek", color: "FF5B49"),
        "securityscorecard.com": SimpleIcon(slug: "securityscorecard", color: "7033FD"),
        "sellfy.com": SimpleIcon(slug: "sellfy", color: "21B352"),
        "semantic-ui.com": SimpleIcon(slug: "semanticui", color: "00B5AD"),
        "semanticscholar.org": SimpleIcon(slug: "semanticscholar", color: "1857B6"),
        "semaphoreci.com": SimpleIcon(slug: "semaphoreci", color: "19A974"),
        "semrush.com": SimpleIcon(slug: "semrush", color: "FF642D"),
        "sencha.com": SimpleIcon(slug: "sencha", color: "86BC40"),
        "sennheiser.com": SimpleIcon(slug: "sennheiser", color: "000000"),
        "sentry.io": SimpleIcon(slug: "sentry", color: "362D59"),
        "servbay.com": SimpleIcon(slug: "servbay", color: "00103C"),
        "serverless.com": SimpleIcon(slug: "serverless", color: "FD5750"),
        "sessionize.com": SimpleIcon(slug: "sessionize", color: "1AB394"),
        "setapp.com": SimpleIcon(slug: "setapp", color: "E6C3A5"),
        "shadow.tech": SimpleIcon(slug: "shadow", color: "0A0C0D"),
        "shazam.com": SimpleIcon(slug: "shazam", color: "0088FF"),
        "shelly.com": SimpleIcon(slug: "shelly", color: "4495D1"),
        "shikimori.one": SimpleIcon(slug: "shikimori", color: "343434"),
        "shopee.com": SimpleIcon(slug: "shopee", color: "EE4D2D"),
        "shopify.com": SimpleIcon(slug: "shopify", color: "7AB55C"),
        "shopware.com": SimpleIcon(slug: "shopware", color: "189EFF"),
        "shortcut.com": SimpleIcon(slug: "shortcut", color: "58B1E4"),
        "showpad.com": SimpleIcon(slug: "showpad", color: "2D2E83"),
        "showwcase.com": SimpleIcon(slug: "showwcase", color: "0A0D14"),
        "sidekiq.org": SimpleIcon(slug: "sidekiq", color: "B1003E"),
        "siemens.com": SimpleIcon(slug: "siemens", color: "009999"),
        "sifive.com": SimpleIcon(slug: "sifive", color: "252323"),
        "signal.org": SimpleIcon(slug: "signal", color: "3B45FD"),
        "silverairways.com": SimpleIcon(slug: "silverairways", color: "D0006F"),
        "similarweb.com": SimpleIcon(slug: "similarweb", color: "092540"),
        "simkl.com": SimpleIcon(slug: "simkl", color: "000000"),
        "simpleanalytics.com": SimpleIcon(slug: "simpleanalytics", color: "FF4F64"),
        "simpleicons.org": SimpleIcon(slug: "simpleicons", color: "111111"),
        "simplelocalize.io": SimpleIcon(slug: "simplelocalize", color: "222B33"),
        "simplelogin.io": SimpleIcon(slug: "simplelogin", color: "EA319F"),
        "singlestore.com": SimpleIcon(slug: "singlestore", color: "AA00FF"),
        "sitecore.com": SimpleIcon(slug: "sitecore", color: "EB1F1F"),
        "sitepoint.com": SimpleIcon(slug: "sitepoint", color: "258AAF"),
        "sketch.com": SimpleIcon(slug: "sketch", color: "F7B500"),
        "sketchfab.com": SimpleIcon(slug: "sketchfab", color: "1CAAD9"),
        "sketchup.com": SimpleIcon(slug: "sketchup", color: "005F9E"),
        "skillshare.com": SimpleIcon(slug: "skillshare", color: "00FF84"),
        "skypack.dev": SimpleIcon(slug: "skypack", color: "3167FF"),
        "slack.com": SimpleIcon(slug: "slack", color: "4A154B", packageVersion: "15.22.0"),
        "slickpic.com": SimpleIcon(slug: "slickpic", color: "FF880F"),
        "slides.com": SimpleIcon(slug: "slides", color: "E4637C"),
        "slideshare.net": SimpleIcon(slug: "slideshare", color: "008ED2"),
        "smart.com": SimpleIcon(slug: "smart", color: "D7E600"),
        "smartthings.com": SimpleIcon(slug: "smartthings", color: "15BFFF"),
        "smashingmagazine.com": SimpleIcon(slug: "smashingmagazine", color: "E85C33"),
        "smoothcomp.com": SimpleIcon(slug: "smoothcomp", color: "000000"),
        "snapchat.com": SimpleIcon(slug: "snapchat", color: "FFFC00"),
        "sncf.com": SimpleIcon(slug: "sncf", color: "CA0939"),
        "snort.org": SimpleIcon(slug: "snort", color: "F6A7AA"),
        "snowflake.com": SimpleIcon(slug: "snowflake", color: "29B5E8"),
        "snowpack.dev": SimpleIcon(slug: "snowpack", color: "2E5E82"),
        "snyk.io": SimpleIcon(slug: "snyk", color: "4C4A73"),
        "socialblade.com": SimpleIcon(slug: "socialblade", color: "B3382C"),
        "society6.com": SimpleIcon(slug: "society6", color: "000000"),
        "socket.io": SimpleIcon(slug: "socketdotio", color: "010101"),
        "softcatala.org": SimpleIcon(slug: "softcatala", color: "BA2626"),
        "sogou.com": SimpleIcon(slug: "sogou", color: "FB6022"),
        "solana.com": SimpleIcon(slug: "solana", color: "9945FF"),
        "sololearn.com": SimpleIcon(slug: "sololearn", color: "149EF2"),
        "solved.ac": SimpleIcon(slug: "solveddotac", color: "17CE3A"),
        "sonatype.com": SimpleIcon(slug: "sonatype", color: "1B1C30"),
        "songkick.com": SimpleIcon(slug: "songkick", color: "F80046"),
        "songoda.com": SimpleIcon(slug: "songoda", color: "FC494A"),
        "sonos.com": SimpleIcon(slug: "sonos", color: "000000"),
        "sony.com": SimpleIcon(slug: "sony", color: "FFFFFF"),
        "soriana.com": SimpleIcon(slug: "soriana", color: "D52B1E"),
        "soundcharts.com": SimpleIcon(slug: "soundcharts", color: "0C1528"),
        "soundcloud.com": SimpleIcon(slug: "soundcloud", color: "FF5500"),
        "sourcehut.org": SimpleIcon(slug: "sourcehut", color: "000000"),
        "spacemacs.org": SimpleIcon(slug: "spacemacs", color: "9266CC"),
        "spaceship.com": SimpleIcon(slug: "spaceship", color: "394EFF"),
        "spacex.com": SimpleIcon(slug: "spacex", color: "000000"),
        "sparkasse.de": SimpleIcon(slug: "sparkasse", color: "FF0000"),
        "sparkfun.com": SimpleIcon(slug: "sparkfun", color: "E53525"),
        "sparkpost.com": SimpleIcon(slug: "sparkpost", color: "FA6423"),
        "spdx.org": SimpleIcon(slug: "spdx", color: "4398CC"),
        "speakerdeck.com": SimpleIcon(slug: "speakerdeck", color: "009287"),
        "spectrum.chat": SimpleIcon(slug: "spectrum", color: "7B16FF"),
        "speedtest.net": SimpleIcon(slug: "speedtest", color: "141526"),
        "speedypage.com": SimpleIcon(slug: "speedypage", color: "1C71F9"),
        "spigotmc.org": SimpleIcon(slug: "spigotmc", color: "ED8106"),
        "splunk.com": SimpleIcon(slug: "splunk", color: "000000"),
        "spoj.com": SimpleIcon(slug: "spoj", color: "337AB7"),
        "spond.com": SimpleIcon(slug: "spond", color: "EE4353"),
        "spotify.com": SimpleIcon(slug: "spotify", color: "1ED760"),
        "spotlight.com": SimpleIcon(slug: "spotlight", color: "352A71"),
        "spreadshirt.ie": SimpleIcon(slug: "spreadshirt", color: "00B2A5"),
        "spreaker.com": SimpleIcon(slug: "spreaker", color: "F5C300"),
        "spring.io": SimpleIcon(slug: "spring", color: "6DB33F"),
        "square-enix.com": SimpleIcon(slug: "squareenix", color: "ED1C24"),
        "srgssr.ch": SimpleIcon(slug: "srgssr", color: "AF001E"),
        "ssrn.com": SimpleIcon(slug: "ssrn", color: "154881"),
        "sst.dev": SimpleIcon(slug: "sst", color: "E27152"),
        "stackbit.com": SimpleIcon(slug: "stackbit", color: "207BEA"),
        "stackblitz.com": SimpleIcon(slug: "stackblitz", color: "1269D3"),
        "stackhawk.com": SimpleIcon(slug: "stackhawk", color: "00CBC6"),
        "stackoverflow.com": SimpleIcon(slug: "stackoverflow", color: "F58025"),
        "stackoverflow.design": SimpleIcon(slug: "stackoverflow", color: "F58025"),
        "stackshare.io": SimpleIcon(slug: "stackshare", color: "0690FA"),
        "staffbase.com": SimpleIcon(slug: "staffbase", color: "00A4FD"),
        "stagetimer.io": SimpleIcon(slug: "stagetimer", color: "00A66C"),
        "standardresume.co": SimpleIcon(slug: "standardresume", color: "2A3FFB"),
        "starbucks.com": SimpleIcon(slug: "starbucks", color: "006241"),
        "stardock.com": SimpleIcon(slug: "stardock", color: "004B8D"),
        "starlingbank.com": SimpleIcon(slug: "starlingbank", color: "6935D3"),
        "starship.rs": SimpleIcon(slug: "starship", color: "DD0B78"),
        "start.gg": SimpleIcon(slug: "startdotgg", color: "2E75BA"),
        "startpage.com": SimpleIcon(slug: "startpage", color: "6563FF"),
        "startrek.com": SimpleIcon(slug: "startrek", color: "FFE200"),
        "starz.com": SimpleIcon(slug: "starz", color: "082125"),
        "statamic.com": SimpleIcon(slug: "statamic", color: "FF269E"),
        "statista.com": SimpleIcon(slug: "statista", color: "001327"),
        "statuspal.io": SimpleIcon(slug: "statuspal", color: "4934BF"),
        "steamdb.info": SimpleIcon(slug: "steamdb", color: "000000"),
        "steelseries.com": SimpleIcon(slug: "steelseries", color: "FF5200"),
        "steem.com": SimpleIcon(slug: "steem", color: "171FC9"),
        "steemit.com": SimpleIcon(slug: "steemit", color: "06D6A9"),
        "steinberg.net": SimpleIcon(slug: "steinberg", color: "C90827"),
        "stellar.org": SimpleIcon(slug: "stellar", color: "FDDA24"),
        "stencyl.com": SimpleIcon(slug: "stencyl", color: "8E1C04"),
        "stockx.com": SimpleIcon(slug: "stockx", color: "006340"),
        "storyblok.com": SimpleIcon(slug: "storyblok", color: "09B3AF"),
        "strapi.io": SimpleIcon(slug: "strapi", color: "4945FF"),
        "streamlabs.com": SimpleIcon(slug: "streamlabs", color: "80F5D2"),
        "streamlit.io": SimpleIcon(slug: "streamlit", color: "FF4B4B"),
        "streamrunners.fr": SimpleIcon(slug: "streamrunners", color: "6644F8"),
        "stripe.com": SimpleIcon(slug: "stripe", color: "635BFF"),
        "strongswan.org": SimpleIcon(slug: "strongswan", color: "E00033"),
        "stubhub.com": SimpleIcon(slug: "stubhub", color: "003168"),
        "studio3t.com": SimpleIcon(slug: "studio3t", color: "17AF66"),
        "styled-components.com": SimpleIcon(slug: "styledcomponents", color: "DB7093"),
        "sublimetext.com": SimpleIcon(slug: "sublimetext", color: "FF9800"),
        "substack.com": SimpleIcon(slug: "substack", color: "FF6719"),
        "suckless.org": SimpleIcon(slug: "suckless", color: "1177AA"),
        "sui.io": SimpleIcon(slug: "sui", color: "4DA2FF"),
        "suno.com": SimpleIcon(slug: "suno", color: "000000"),
        "sunrise.ch": SimpleIcon(slug: "sunrise", color: "DA291C"),
        "supercell.com": SimpleIcon(slug: "supercell", color: "FFFFFF"),
        "supercrease.com": SimpleIcon(slug: "supercrease", color: "000000"),
        "supermicro.com": SimpleIcon(slug: "supermicro", color: "151F6D"),
        "surfshark.com": SimpleIcon(slug: "surfshark", color: "1EBFBF"),
        "surveymonkey.com": SimpleIcon(slug: "surveymonkey", color: "00BF6F"),
        "suse.com": SimpleIcon(slug: "suse", color: "0C322C"),
        "suzuki.ie": SimpleIcon(slug: "suzuki", color: "E30613"),
        "svgtrace.com": SimpleIcon(slug: "svgtrace", color: "F453C4"),
        "swagger.io": SimpleIcon(slug: "swagger", color: "85EA2D"),
        "swiggy.com": SimpleIcon(slug: "swiggy", color: "FC8019"),
        "swisscows.com": SimpleIcon(slug: "swisscows", color: "000000"),
        "symbolab.com": SimpleIcon(slug: "symbolab", color: "DB3F59"),
        "symfony.com": SimpleIcon(slug: "symfony", color: "000000"),
        "symphony.com": SimpleIcon(slug: "symphony", color: "0098FF"),
        "synology.com": SimpleIcon(slug: "synology", color: "B5B5B6"),
        "tabelog.com": SimpleIcon(slug: "tabelog", color: "F2CC38"),
        "tablecheck.com": SimpleIcon(slug: "tablecheck", color: "7935D2"),
        "tacobell.com": SimpleIcon(slug: "tacobell", color: "38096C"),
        "tado.com": SimpleIcon(slug: "tado", color: "FFA900"),
        "taichi-lang.org": SimpleIcon(slug: "taichilang", color: "000000"),
        "tailscale.com": SimpleIcon(slug: "tailscale", color: "242424"),
        "tailwindcss.com": SimpleIcon(slug: "tailwindcss", color: "06B6D4"),
        "taipy.io": SimpleIcon(slug: "taipy", color: "FF371A"),
        "talend.com": SimpleIcon(slug: "talend", color: "FF6D70"),
        "talenthouse.com": SimpleIcon(slug: "talenthouse", color: "000000"),
        "tanstack.com": SimpleIcon(slug: "tanstack", color: "000000"),
        "tapas.io": SimpleIcon(slug: "tapas", color: "FFCE00"),
        "target.com": SimpleIcon(slug: "target", color: "CC0000"),
        "tarom.ro": SimpleIcon(slug: "tarom", color: "003366"),
        "tarteaucitron.io": SimpleIcon(slug: "tarteaucitron", color: "F7D917"),
        "taxbuzz.com": SimpleIcon(slug: "taxbuzz", color: "ED8B0B"),
        "tcs.com": SimpleIcon(slug: "tcs", color: "EE3984"),
        "teamspeak.com": SimpleIcon(slug: "teamspeak", color: "4B69B6"),
        "teamviewer.com": SimpleIcon(slug: "teamviewer", color: "050A52"),
        "ted.com": SimpleIcon(slug: "ted", color: "E62B1E"),
        "teepublic.design": SimpleIcon(slug: "teepublic", color: "4E64DF"),
        "teespring.com": SimpleIcon(slug: "teespring", color: "ED2761"),
        "telegram.org": SimpleIcon(slug: "telegram", color: "26A5E4"),
        "telenor.no": SimpleIcon(slug: "telenor", color: "00C8FF"),
        "telequebec.tv": SimpleIcon(slug: "telequebec", color: "1343FB"),
        "tensorflow.org": SimpleIcon(slug: "tensorflow", color: "FF6F00"),
        "teratail.com": SimpleIcon(slug: "teratail", color: "F4C51C"),
        "termius.com": SimpleIcon(slug: "termius", color: "000000"),
        "tesco.com": SimpleIcon(slug: "tesco", color: "00539F"),
        "tesla.com": SimpleIcon(slug: "tesla", color: "CC0000"),
        "testin.cn": SimpleIcon(slug: "testin", color: "007DD7"),
        "testing-library.com": SimpleIcon(slug: "testinglibrary", color: "E33332"),
        "testrail.com": SimpleIcon(slug: "testrail", color: "65C179"),
        "tether.to": SimpleIcon(slug: "tether", color: "50AF95"),
        "textpattern.com": SimpleIcon(slug: "textpattern", color: "FFDA44"),
        "tfl.gov.uk": SimpleIcon(slug: "transportforlondon", color: "113B92"),
        "thangs.com": SimpleIcon(slug: "thangs", color: "FFBC00"),
        "thanos.io": SimpleIcon(slug: "thanos", color: "6D41FF"),
        "theconversation.com": SimpleIcon(slug: "theconversation", color: "D8352A"),
        "theguardian.com": SimpleIcon(slug: "theguardian", color: "052962"),
        "themighty.com": SimpleIcon(slug: "themighty", color: "D0072A"),
        "thenorthface.com": SimpleIcon(slug: "thenorthface", color: "000000"),
        "theodinproject.com": SimpleIcon(slug: "theodinproject", color: "A9792B"),
        "theregister.co.uk": SimpleIcon(slug: "theregister", color: "FF0000"),
        "thestorygraph.com": SimpleIcon(slug: "thestorygraph", color: "000000"),
        "thingiverse.com": SimpleIcon(slug: "thingiverse", color: "248BFB"),
        "thirdweb.com": SimpleIcon(slug: "thirdweb", color: "F213A4"),
        "threadless.com": SimpleIcon(slug: "threadless", color: "0099FF"),
        "threema.ch": SimpleIcon(slug: "threema", color: "3FE669"),
        "thumbtack.com": SimpleIcon(slug: "thumbtack", color: "009FD9"),
        "thunderbird.net": SimpleIcon(slug: "thunderbird", color: "0A84FF"),
        "ticketmaster.com": SimpleIcon(slug: "ticketmaster", color: "026CDF"),
        "tickettailor.com": SimpleIcon(slug: "tickettailor", color: "222432"),
        "ticktick.com": SimpleIcon(slug: "ticktick", color: "4772FA"),
        "tidal.com": SimpleIcon(slug: "tidal", color: "000000"),
        "tiddlywiki.com": SimpleIcon(slug: "tiddlywiki", color: "111111"),
        "tide.co": SimpleIcon(slug: "tide", color: "4050FB"),
        "tietoevry.com": SimpleIcon(slug: "tietoevry", color: "063752"),
        "tiktok.com": SimpleIcon(slug: "tiktok", color: "000000"),
        "timescale.com": SimpleIcon(slug: "timescale", color: "FDB515"),
        "tindie.com": SimpleIcon(slug: "tindie", color: "17AEB9"),
        "tinkercad.com": SimpleIcon(slug: "tinkercad", color: "1477D1"),
        "tinyletter.com": SimpleIcon(slug: "tinyletter", color: "ED1C24"),
        "tio.run": SimpleIcon(slug: "tryitonline", color: "303030"),
        "tistory.com": SimpleIcon(slug: "tistory", color: "000000"),
        "tldraw.dev": SimpleIcon(slug: "tldraw", color: "FAFAFA"),
        "toggl.com": SimpleIcon(slug: "toggl", color: "FFDE91"),
        "tokio.rs": SimpleIcon(slug: "tokio", color: "000000"),
        "tomorrowland.com": SimpleIcon(slug: "tomorrowland", color: "000000"),
        "tomtom.com": SimpleIcon(slug: "tomtom", color: "DF1B12"),
        "ton.org": SimpleIcon(slug: "ton", color: "0098EA"),
        "top.gg": SimpleIcon(slug: "topdotgg", color: "FF3366"),
        "topcoder.com": SimpleIcon(slug: "topcoder", color: "29A7DF"),
        "toptal.com": SimpleIcon(slug: "toptal", color: "3863A0"),
        "torproject.org": SimpleIcon(slug: "torproject", color: "7D4698"),
        "totvs.com": SimpleIcon(slug: "totvs", color: "363636"),
        "toyota.com": SimpleIcon(slug: "toyota", color: "EB0A1E"),
        "tp-link.com": SimpleIcon(slug: "tplink", color: "4ACBD6"),
        "traccar.org": SimpleIcon(slug: "traccar", color: "000000"),
        "tradingview.com": SimpleIcon(slug: "tradingview", color: "131622"),
        "trailforks.com": SimpleIcon(slug: "trailforks", color: "FFCD00"),
        "trainerroad.com": SimpleIcon(slug: "trainerroad", color: "DA291C"),
        "trakt.tv": SimpleIcon(slug: "trakt", color: "9F42C6"),
        "transifex.com": SimpleIcon(slug: "transifex", color: "0064AB"),
        "transportforireland.ie": SimpleIcon(slug: "transportforireland", color: "00B274"),
        "travis-ci.com": SimpleIcon(slug: "travisci", color: "3EAAAF"),
        "trendmicro.com": SimpleIcon(slug: "trendmicro", color: "D71921"),
        "tresorit.com": SimpleIcon(slug: "tresorit", color: "00A9E2"),
        "tricentis.com": SimpleIcon(slug: "tricentis", color: "12438C"),
        "triller.co": SimpleIcon(slug: "triller", color: "FF0089"),
        "trimble.com": SimpleIcon(slug: "trimble", color: "0063A3"),
        "trip.com": SimpleIcon(slug: "tripdotcom", color: "287DFA"),
        "trivago.com": SimpleIcon(slug: "trivago", color: "E32851"),
        "trmnl.com": SimpleIcon(slug: "trmnl", color: "F8654B"),
        "truenas.com": SimpleIcon(slug: "truenas", color: "0095D5"),
        "trueup.io": SimpleIcon(slug: "trueup", color: "4E71DA"),
        "trulia.com": SimpleIcon(slug: "trulia", color: "0A0B09"),
        "trustedshops.com": SimpleIcon(slug: "trustedshops", color: "FFDC0F"),
        "trustpilot.com": SimpleIcon(slug: "trustpilot", color: "00B67A"),
        "tryhackme.com": SimpleIcon(slug: "tryhackme", color: "212C42"),
        "tubi.tv": SimpleIcon(slug: "tubi", color: "7408FF"),
        "tumblr.com": SimpleIcon(slug: "tumblr", color: "36465D"),
        "turbosquid.com": SimpleIcon(slug: "turbosquid", color: "FF8135"),
        "turkishairlines.com": SimpleIcon(slug: "turkishairlines", color: "C70A0C"),
        "turso.tech": SimpleIcon(slug: "turso", color: "4FF8D2"),
        "tuta.com": SimpleIcon(slug: "tuta", color: "850122"),
        "tuxedocomputers.com": SimpleIcon(slug: "tuxedocomputers", color: "000000"),
        "tv4play.se": SimpleIcon(slug: "tv4play", color: "E0001C"),
        "tvtime.com": SimpleIcon(slug: "tvtime", color: "FFD400"),
        "twenty.com": SimpleIcon(slug: "twenty", color: "000000"),
        "twinkly.com": SimpleIcon(slug: "twinkly", color: "FCC15E"),
        "twinmotion.com": SimpleIcon(slug: "twinmotion", color: "000000"),
        "twitch.tv": SimpleIcon(slug: "twitch", color: "9146FF"),
        "typeform.com": SimpleIcon(slug: "typeform", color: "262627"),
        "typo3.com": SimpleIcon(slug: "typo3", color: "FF8700"),
        "typst.app": SimpleIcon(slug: "typst", color: "239DAD"),
        "uber.com": SimpleIcon(slug: "uber", color: "000000"),
        "ubisoft.com": SimpleIcon(slug: "ubisoft", color: "000000"),
        "ubuntu-mate.org": SimpleIcon(slug: "ubuntumate", color: "84A454"),
        "ubuntu.com": SimpleIcon(slug: "ubuntu", color: "E95420"),
        "udacity.com": SimpleIcon(slug: "udacity", color: "02B3E4"),
        "udemy.com": SimpleIcon(slug: "udemy", color: "A435F0"),
        "ufc.com": SimpleIcon(slug: "ufc", color: "D20A0A"),
        "uipath.com": SimpleIcon(slug: "uipath", color: "FA4616"),
        "ultralytics.com": SimpleIcon(slug: "ultralytics", color: "111F68"),
        "umbraco.com": SimpleIcon(slug: "umbraco", color: "3544B1"),
        "umbrel.com": SimpleIcon(slug: "umbrel", color: "5351FB"),
        "uml.org": SimpleIcon(slug: "uml", color: "FABD14"),
        "un.org": SimpleIcon(slug: "unitednations", color: "009EDB"),
        "unacademy.com": SimpleIcon(slug: "unacademy", color: "08BD80"),
        "underarmour.com": SimpleIcon(slug: "underarmour", color: "1D1D1D"),
        "undertale.com": SimpleIcon(slug: "undertale", color: "E71D29"),
        "unilever.com": SimpleIcon(slug: "unilever", color: "1F36C7"),
        "unity.com": SimpleIcon(slug: "unity", color: "FFFFFF"),
        "unjs.io": SimpleIcon(slug: "unjs", color: "ECDC5A"),
        "unraid.net": SimpleIcon(slug: "unraid", color: "F15A2C"),
        "unrealengine.com": SimpleIcon(slug: "unrealengine", color: "0E1128"),
        "unsplash.com": SimpleIcon(slug: "unsplash", color: "000000"),
        "unstop.com": SimpleIcon(slug: "unstop", color: "1C4980"),
        "untappd.com": SimpleIcon(slug: "untappd", color: "FFC000"),
        "upcloud.com": SimpleIcon(slug: "upcloud", color: "7B00FF"),
        "uphold.com": SimpleIcon(slug: "uphold", color: "49CC68"),
        "uplabs.com": SimpleIcon(slug: "uplabs", color: "3930D8"),
        "ups.com": SimpleIcon(slug: "ups", color: "150400"),
        "upstash.com": SimpleIcon(slug: "upstash", color: "00E9A3"),
        "upwork.com": SimpleIcon(slug: "upwork", color: "6FDA44"),
        "uservoice.com": SimpleIcon(slug: "uservoice", color: "FF6720"),
        "usnews.com": SimpleIcon(slug: "udotsdotnews", color: "005EA6"),
        "usps.com": SimpleIcon(slug: "usps", color: "333366"),
        "utorrent.com": SimpleIcon(slug: "utorrent", color: "76B83F"),
        "v0.dev": SimpleIcon(slug: "v0", color: "000000"),
        "v2ex.com": SimpleIcon(slug: "v2ex", color: "1F1F1F"),
        "v8.dev": SimpleIcon(slug: "v8", color: "4B8BF5"),
        "vaadin.com": SimpleIcon(slug: "vaadin", color: "00B4F0"),
        "vapor.codes": SimpleIcon(slug: "vapor", color: "0D0D0D"),
        "vectary.com": SimpleIcon(slug: "vectary", color: "6100FF"),
        "vectorworks.net": SimpleIcon(slug: "vectorworks", color: "000000"),
        "veeam.com": SimpleIcon(slug: "veeam", color: "00B336"),
        "veed.io": SimpleIcon(slug: "veed", color: "B6FF60"),
        "veepee.fr": SimpleIcon(slug: "veepee", color: "EC008C"),
        "venmo.com": SimpleIcon(slug: "venmo", color: "008CFF"),
        "vercel.com": SimpleIcon(slug: "vercel", color: "000000"),
        "verdaccio.org": SimpleIcon(slug: "verdaccio", color: "4B5E40"),
        "veritas.com": SimpleIcon(slug: "veritas", color: "B1181E"),
        "vexxhost.com": SimpleIcon(slug: "vexxhost", color: "2A1659"),
        "vfairs.com": SimpleIcon(slug: "vfairs", color: "EF4678"),
        "viber.com": SimpleIcon(slug: "viber", color: "7360F2"),
        "viblo.asia": SimpleIcon(slug: "viblo", color: "5387C6"),
        "victoriametrics.com": SimpleIcon(slug: "victoriametrics", color: "621773"),
        "victronenergy.com": SimpleIcon(slug: "victronenergy", color: "0066B2"),
        "vimeo.com": SimpleIcon(slug: "vimeo", color: "1AB7EA"),
        "vinted.com": SimpleIcon(slug: "vinted", color: "007782"),
        "virgin.com": SimpleIcon(slug: "virgin", color: "E10A0A"),
        "virginatlantic.com": SimpleIcon(slug: "virginatlantic", color: "DA0530"),
        "virtualbox.org": SimpleIcon(slug: "virtualbox", color: "2F61B4"),
        "virustotal.com": SimpleIcon(slug: "virustotal", color: "394EFF"),
        "visa.com": SimpleIcon(slug: "visa", color: "1A1F71"),
        "visual-paradigm.com": SimpleIcon(slug: "visualparadigm", color: "CC3333"),
        "vivaldi.com": SimpleIcon(slug: "vivaldi", color: "EF3939"),
        "vivawallet.com": SimpleIcon(slug: "vivawallet", color: "1F263A"),
        "vivino.com": SimpleIcon(slug: "vivino", color: "A61A30"),
        "vivo.com": SimpleIcon(slug: "vivo", color: "415FFF"),
        "vk.com": SimpleIcon(slug: "vk", color: "0077FF"),
        "voelkner.de": SimpleIcon(slug: "voelkner", color: "94C125"),
        "voidlinux.org": SimpleIcon(slug: "voidlinux", color: "478061"),
        "voip.ms": SimpleIcon(slug: "voipdotms", color: "E1382D"),
        "vonage.com": SimpleIcon(slug: "vonage", color: "000000"),
        "vrchat.com": SimpleIcon(slug: "vrchat", color: "000000"),
        "vsco.co": SimpleIcon(slug: "vsco", color: "000000"),
        "vtex.com": SimpleIcon(slug: "vtex", color: "ED125F"),
        "vultr.com": SimpleIcon(slug: "vultr", color: "007BFC"),
        "vyond.com": SimpleIcon(slug: "vyond", color: "D95E26"),
        "w3schools.com": SimpleIcon(slug: "w3schools", color: "04AA6D"),
        "wacom.com": SimpleIcon(slug: "wacom", color: "000000"),
        "wagmi.sh": SimpleIcon(slug: "wagmi", color: "000000"),
        "wails.io": SimpleIcon(slug: "wails", color: "DF0000"),
        "wakatime.com": SimpleIcon(slug: "wakatime", color: "000000"),
        "walletconnect.com": SimpleIcon(slug: "walletconnect", color: "3B99FC"),
        "wappalyzer.com": SimpleIcon(slug: "wappalyzer", color: "4608AD"),
        "warp.dev": SimpleIcon(slug: "warp", color: "01A4FF"),
        "wasabi.com": SimpleIcon(slug: "wasabi", color: "01CD3E"),
        "wattpad.com": SimpleIcon(slug: "wattpad", color: "FF500A"),
        "waze.com": SimpleIcon(slug: "waze", color: "33CCFF"),
        "wazirx.com": SimpleIcon(slug: "wazirx", color: "3067F0"),
        "weasyl.com": SimpleIcon(slug: "weasyl", color: "990000"),
        "web.de": SimpleIcon(slug: "webdotde", color: "FFD800"),
        "webassembly.org": SimpleIcon(slug: "webassembly", color: "654FF0"),
        "webcomponents.org": SimpleIcon(slug: "webcomponentsdotorg", color: "29ABE2"),
        "webex.com": SimpleIcon(slug: "webex", color: "000000"),
        "webmoney.ru": SimpleIcon(slug: "webmoney", color: "036CB5"),
        "webrtc.org": SimpleIcon(slug: "webrtc", color: "333333"),
        "webtrees.net": SimpleIcon(slug: "webtrees", color: "2694E8"),
        "wechat.design": SimpleIcon(slug: "wechat", color: "07C160"),
        "wegame.com.cn": SimpleIcon(slug: "wegame", color: "FAAB00"),
        "welcometothejungle.com": SimpleIcon(slug: "welcometothejungle", color: "FFCD00"),
        "wellfound.com": SimpleIcon(slug: "wellfound", color: "000000"),
        "wellsfargo.com": SimpleIcon(slug: "wellsfargo", color: "D71E28"),
        "westernunion.com": SimpleIcon(slug: "westernunion", color: "FFDD00"),
        "wetransfer.com": SimpleIcon(slug: "wetransfer", color: "409FFF"),
        "wgpu.rs": SimpleIcon(slug: "wgpu", color: "40E0D0"),
        "what3words.com": SimpleIcon(slug: "what3words", color: "E11F26"),
        "wheniwork.com": SimpleIcon(slug: "wheniwork", color: "51A33D"),
        "who.int": SimpleIcon(slug: "worldhealthorganization", color: "0093D5"),
        "wiki.gg": SimpleIcon(slug: "wikidotgg", color: "FF1985"),
        "winamp.com": SimpleIcon(slug: "winamp", color: "F93821"),
        "windsurf.com": SimpleIcon(slug: "windsurf", color: "0B100F"),
        "wipro.com": SimpleIcon(slug: "wipro", color: "341C53"),
        "wire.com": SimpleIcon(slug: "wire", color: "000000"),
        "wireguard.com": SimpleIcon(slug: "wireguard", color: "88171A"),
        "wise.design": SimpleIcon(slug: "wise", color: "9FE870"),
        "wish.com": SimpleIcon(slug: "wish", color: "32E476"),
        "wistia.com": SimpleIcon(slug: "wistia", color: "58B7FE"),
        "wix.com": SimpleIcon(slug: "wix", color: "0C6EFC"),
        "wizzair.com": SimpleIcon(slug: "wizzair", color: "C6007E"),
        "wolfram.com": SimpleIcon(slug: "wolfram", color: "DD1100"),
        "wondershare.com": SimpleIcon(slug: "wondershare", color: "000000"),
        "woocommerce.com": SimpleIcon(slug: "woocommerce", color: "96588A"),
        "wordpress.org": SimpleIcon(slug: "wordpress", color: "21759B"),
        "wp-rocket.me": SimpleIcon(slug: "wprocket", color: "F56640"),
        "wpengine.com": SimpleIcon(slug: "wpengine", color: "0ECAD4"),
        "wpexplorer.com": SimpleIcon(slug: "wpexplorer", color: "2563EB"),
        "write.as": SimpleIcon(slug: "writedotas", color: "5AC4EE"),
        "wykop.pl": SimpleIcon(slug: "wykop", color: "367DA9"),
        "wyze.com": SimpleIcon(slug: "wyze", color: "1DF0BB"),
        "x.com": SimpleIcon(slug: "x", color: "000000"),
        "xda-developers.com": SimpleIcon(slug: "xdadevelopers", color: "EA7100"),
        "xendit.co": SimpleIcon(slug: "xendit", color: "4573FF"),
        "xero.com": SimpleIcon(slug: "xero", color: "13B5EA"),
        "xfce.org": SimpleIcon(slug: "xfce", color: "2284F2"),
        "xiaohongshu.com": SimpleIcon(slug: "xiaohongshu", color: "FF2442"),
        "xing.com": SimpleIcon(slug: "xing", color: "006567"),
        "xsplit.com": SimpleIcon(slug: "xsplit", color: "0095DE"),
        "yaak.app": SimpleIcon(slug: "yaak", color: "814EDF"),
        "ycombinator.com": SimpleIcon(slug: "ycombinator", color: "F0652F"),
        "yelp.com": SimpleIcon(slug: "yelp", color: "FF1A1A"),
        "yeti.com": SimpleIcon(slug: "yeti", color: "00263C"),
        "yoast.com": SimpleIcon(slug: "yoast", color: "A61E69"),
        "youhodler.com": SimpleIcon(slug: "youhodler", color: "546DF9"),
        "youtube.com": SimpleIcon(slug: "youtube", color: "FF0000"),
        "yr.no": SimpleIcon(slug: "yr", color: "00B9F1"),
        "yubico.com": SimpleIcon(slug: "yubico", color: "84BD00"),
        "zabka.pl": SimpleIcon(slug: "zabka", color: "006420"),
        "zaim.net": SimpleIcon(slug: "zaim", color: "50A135"),
        "zalando.co.uk": SimpleIcon(slug: "zalando", color: "FF6900"),
        "zalo.me": SimpleIcon(slug: "zalo", color: "0068FF"),
        "zara.com": SimpleIcon(slug: "zara", color: "000000"),
        "zazzle.com": SimpleIcon(slug: "zazzle", color: "212121"),
        "zcool.com.cn": SimpleIcon(slug: "zcool", color: "FFF200"),
        "zdf.de": SimpleIcon(slug: "zdf", color: "FA7D19"),
        "zebpay.com": SimpleIcon(slug: "zebpay", color: "2072EF"),
        "zend.com": SimpleIcon(slug: "zend", color: "0679EA"),
        "zendesk.com": SimpleIcon(slug: "zendesk", color: "03363D"),
        "zenn.dev": SimpleIcon(slug: "zenn", color: "3EA8FF"),
        "zenodo.org": SimpleIcon(slug: "zenodo", color: "1682D4"),
        "zensar.com": SimpleIcon(slug: "zensar", color: "000000"),
        "zerodha.com": SimpleIcon(slug: "zerodha", color: "387ED1"),
        "zerotier.com": SimpleIcon(slug: "zerotier", color: "FFB441"),
        "zettlr.com": SimpleIcon(slug: "zettlr", color: "1CB27E"),
        "zhihu.com": SimpleIcon(slug: "zhihu", color: "0084FF"),
        "zilch.com": SimpleIcon(slug: "zilch", color: "00D287"),
        "zillow.com": SimpleIcon(slug: "zillow", color: "006AFF"),
        "zingat.com": SimpleIcon(slug: "zingat", color: "009CFB"),
        "zoho.com": SimpleIcon(slug: "zoho", color: "E42527"),
        "zoiper.com": SimpleIcon(slug: "zoiper", color: "F47920"),
        "zomato.com": SimpleIcon(slug: "zomato", color: "E23744"),
        "zoom.us": SimpleIcon(slug: "zoom", color: "0B5CFF"),
        "zorin.com": SimpleIcon(slug: "zorin", color: "15A6F0"),
        "zotero.org": SimpleIcon(slug: "zotero", color: "CC2936"),
        "zyte.com": SimpleIcon(slug: "zyte", color: "B02CCE")
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

    private static func debugLog(_ debugLabel: String?, _ message: String) {
        guard let debugLabel else { return }
        NSLog("%@", "[MailiaAvatar] \(debugLabel) \(message)")
    }
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
