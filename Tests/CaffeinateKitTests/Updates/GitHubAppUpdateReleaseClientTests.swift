import Foundation
import Testing
@testable import CaffeinateKit

struct GitHubAppUpdateReleaseClientTests {
    private let releasesURL = StubURLProtocol.uniqueURL(path: "releases?per_page=100")
    private let digest = String(repeating: "b", count: 64)

    @Test
    func picksHighestStableSemverAndSkipsDraftsPrereleasesAndBadTags() async throws {
        try stub([
            release("v0.2.0"),
            release("v0.10.0", size: 1_234),
            release("nightly"),
            release("v0.11.0", prerelease: true),
            release("v1.0.0", draft: true)
        ])

        let result = await makeClient().latestRelease()

        guard case .found(let found) = result else {
            Issue.record("Expected a release, got \(result)")
            return
        }
        #expect(found.tagName == "v0.10.0")
        #expect(found.version.description == "0.10.0")
        #expect(found.htmlURL.absoluteString == "https://github.com/afollestad/caffeinate-menubar/releases/tag/v0.10.0")
        #expect(found.asset.downloadURL.absoluteString.hasSuffix("/v0.10.0/Caffeinate.app.zip"))
        #expect(found.asset.size == 1_234)
        #expect(found.asset.digest.sha256HexDigest == digest)

        let request = try #require(StubURLProtocol.requests(to: releasesURL).first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Caffeinate")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func reportsNoReleaseWhenNothingIsStable() async throws {
        try stub([release("v1.0.0", draft: true), release("v0.9.0", prerelease: true)])
        #expect(await makeClient().latestRelease() == .unavailable(.noRelease))
    }

    @Test
    func reportsMalformedVersionWhenNoStableTagParses() async throws {
        try stub([release("nightly")])
        #expect(await makeClient().latestRelease() == .unavailable(.malformedVersion("nightly")))
    }

    @Test
    func requiresTheAppAsset() async throws {
        try stub([release("v0.2.0", assetName: "Caffeinate.dSYMs.zip")])
        #expect(await makeClient().latestRelease() == .unavailable(.missingAsset(expectedName: "Caffeinate.app.zip")))
    }

    @Test
    func requiresAnAssetDigest() async throws {
        try stub([release("v0.2.0", includesDigest: false)])
        #expect(await makeClient().latestRelease() == .unavailable(.missingAssetDigest(expectedName: "Caffeinate.app.zip")))
    }

    @Test
    func rejectsMalformedAssetDigest() async throws {
        try stub([release("v0.2.0", digest: "md5:abc")])
        #expect(await makeClient().latestRelease() == .unavailable(.invalidRelease("Malformed asset digest md5:abc.")))
    }

    @Test
    func mapsExhaustedRateLimitWithItsResetTime() async {
        StubURLProtocol.stub(releasesURL, .init(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000000"]
        ))
        let expected = AppUpdateUnavailableReason.rateLimited(resetDate: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(await makeClient().latestRelease() == .unavailable(expected))
    }

    @Test(arguments: [403, 404, 500])
    func mapsOtherHTTPFailuresToTheirStatus(_ statusCode: Int) async {
        StubURLProtocol.stub(releasesURL, .init(statusCode: statusCode))
        #expect(await makeClient().latestRelease() == .unavailable(.requestFailed(statusCode: statusCode)))
    }

    @Test
    func reportsUndecodableResponses() async {
        StubURLProtocol.stub(releasesURL, .init(chunks: [Data("{}".utf8)]))
        guard case .unavailable(.decodingFailed) = await makeClient().latestRelease() else {
            Issue.record("Expected a decoding failure")
            return
        }
    }

    @Test
    func reportsTransportFailures() async {
        StubURLProtocol.stub(releasesURL, .init(error: URLError(.notConnectedToInternet)))
        guard case .unavailable(.transportFailed) = await makeClient().latestRelease() else {
            Issue.record("Expected a transport failure")
            return
        }
    }

    private func makeClient() -> GitHubAppUpdateReleaseClient {
        GitHubAppUpdateReleaseClient(releasesURL: releasesURL, sessionConfiguration: StubURLProtocol.configuration)
    }

    private func stub(_ releases: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: releases)
        StubURLProtocol.stub(releasesURL, .init(chunks: [data]))
    }

    private func release(
        _ tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String = "Caffeinate.app.zip",
        size: Int = 100,
        digest: String? = nil,
        includesDigest: Bool = true
    ) -> [String: Any] {
        var asset: [String: Any] = [
            "name": assetName,
            "browser_download_url": "https://github.com/afollestad/caffeinate-menubar/releases/download/\(tag)/\(assetName)",
            "size": size
        ]
        if includesDigest {
            asset["digest"] = digest ?? "sha256:\(self.digest)"
        }
        return [
            "tag_name": tag,
            "html_url": "https://github.com/afollestad/caffeinate-menubar/releases/tag/\(tag)",
            "draft": draft,
            "prerelease": prerelease,
            "assets": [asset]
        ]
    }
}
