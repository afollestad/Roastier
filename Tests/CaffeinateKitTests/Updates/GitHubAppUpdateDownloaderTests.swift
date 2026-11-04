import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import CaffeinateKit

final class GitHubAppUpdateDownloaderTests {
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaffeinateDownloaderTests-\(UUID().uuidString)", isDirectory: true)
    private let assetURL = StubURLProtocol.uniqueURL(path: "releases/download/v0.2.0/Caffeinate.app.zip")
    private let chunks = [Data(repeating: 1, count: 4_000), Data(repeating: 2, count: 4_000), Data(repeating: 3, count: 2_000)]

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @Test
    func streamsVerifiesAndReportsProgress() async throws {
        StubURLProtocol.stub(assetURL, .init(chunks: chunks))
        let progress = Mutex<[Double]>([])

        let zipURL = try await makeDownloader().download(release: release()) { value in
            progress.withLock { $0.append(value) }
        }

        #expect(try Data(contentsOf: zipURL) == payload)
        #expect(zipURL.path.hasPrefix(temporaryDirectory.appendingPathComponent("CaffeinateUpdates").path))
        let reported = progress.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(reported == reported.sorted())
        #expect(reported.count > 2)
    }

    @Test
    func keepsEveryHopUncached() async throws {
        let cdnURL = StubURLProtocol.uniqueURL(path: "asset")
        StubURLProtocol.stub(assetURL, .init(redirectURL: cdnURL))
        StubURLProtocol.stub(cdnURL, .init(chunks: chunks))

        _ = try await makeDownloader().download(release: release()) { _ in }

        let original = try #require(StubURLProtocol.requests(to: assetURL).first)
        let redirected = try #require(StubURLProtocol.requests(to: cdnURL).first)
        for request in [original, redirected] {
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        }
    }

    @Test
    func rejectsDigestMismatchAndCleansUp() async {
        StubURLProtocol.stub(assetURL, .init(chunks: chunks))
        let release = release(digest: String(repeating: "0", count: 64))

        await #expect(throws: AppUpdateFailure(message: "The downloaded update failed SHA-256 verification.")) {
            try await self.makeDownloader().download(release: release) { _ in }
        }
        #expect(downloadDirectories.isEmpty)
    }

    @Test
    func rejectsSizeMismatch() async {
        StubURLProtocol.stub(assetURL, .init(chunks: chunks))
        let release = release(size: payload.count + 1)

        await #expect(throws: AppUpdateFailure(message: "Downloaded 10000 bytes, but GitHub reported 10001 bytes.")) {
            try await self.makeDownloader().download(release: release) { _ in }
        }
        #expect(downloadDirectories.isEmpty)
    }

    @Test
    func rejectsHTTPErrors() async {
        StubURLProtocol.stub(assetURL, .init(statusCode: 404))

        await #expect(throws: AppUpdateFailure(message: "GitHub failed to download the update. (HTTP 404)")) {
            try await self.makeDownloader().download(release: self.release()) { _ in }
        }
        #expect(downloadDirectories.isEmpty)
    }

    private var payload: Data {
        chunks.reduce(Data(), +)
    }

    private var downloadDirectories: [URL] {
        let parent = temporaryDirectory.appendingPathComponent("CaffeinateUpdates")
        return (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
    }

    private func makeDownloader() -> GitHubAppUpdateDownloader {
        GitHubAppUpdateDownloader(
            temporaryDirectory: temporaryDirectory,
            sessionConfiguration: StubURLProtocol.configuration
        )
    }

    private func release(size: Int? = nil, digest: String? = nil) -> AppUpdateRelease {
        let actualDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return makeRelease(size: size ?? payload.count, digest: digest ?? actualDigest, downloadURL: assetURL)
    }
}
