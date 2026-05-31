import Foundation
import Testing
@testable import MailiaApp

@Test
func avatarMissingResultPersistsAcrossResolverInstances() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailiaAvatarCacheTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: cacheDirectory)
        AvatarMissingURLProtocol.state.reset()
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AvatarMissingURLProtocol.self]
    let session = URLSession(configuration: configuration)

    let resolver = EntityBrandAvatarResolver(diskCacheDirectory: cacheDirectory, session: session)
    let firstResult = await resolver.gravatarDataURL(forEmailAddress: "missing-avatar@gmail.com")
    let secondResult = await resolver.gravatarDataURL(forEmailAddress: "missing-avatar@gmail.com")

    let resolverAfterRestart = EntityBrandAvatarResolver(diskCacheDirectory: cacheDirectory, session: session)
    let thirdResult = await resolverAfterRestart.gravatarDataURL(forEmailAddress: "missing-avatar@gmail.com")
    let cachedStatus = await resolverAfterRestart.cachedAvatarStatus(
        primaryEmailAddress: "missing-avatar@gmail.com",
        emailAddresses: []
    )

    #expect(firstResult == nil)
    #expect(secondResult == nil)
    #expect(thirdResult == nil)
    #expect(cachedStatus == .missing)
    #expect(AvatarMissingURLProtocol.state.requestCount == 1)
}

private final class AvatarMissingURLProtocol: URLProtocol {
    static let state = AvatarMissingURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.recordRequest()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AvatarMissingURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    func recordRequest() {
        lock.withLock {
            requests += 1
        }
    }

    func reset() {
        lock.withLock {
            requests = 0
        }
    }
}
