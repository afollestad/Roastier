import CryptoKit
import Foundation

/// Streams a release's ZIP from its public download URL, then checks its size and SHA-256 digest.
struct GitHubAppUpdateDownloader: AppUpdateDownloading, @unchecked Sendable {
    private static let downloadTimeout: TimeInterval = 600

    private let temporaryDirectory: URL
    private let sessionConfiguration: URLSessionConfiguration

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.sessionConfiguration = sessionConfiguration
    }

    func download(
        release: AppUpdateRelease,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let downloadDirectory = temporaryDirectory
            .appendingPathComponent("CaffeinateUpdates", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        let zipURL = downloadDirectory.appendingPathComponent(release.asset.name.sanitizedForPathComponent)
        do {
            await progress(0)
            try await downloadAsset(
                request: Self.assetRequest(url: release.asset.downloadURL),
                destinationURL: zipURL,
                expectedSize: release.asset.size,
                progress: progress
            )
            try Self.verifyDownloadedSize(zipURL: zipURL, expectedSize: release.asset.size)
            try Self.verifyDownloadedDigest(zipURL: zipURL, expectedDigest: release.asset.digest)
            await progress(1)
            return zipURL
        } catch {
            try? fileManager.removeItem(at: downloadDirectory)
            throw error
        }
    }
}

private extension GitHubAppUpdateDownloader {
    static func assetRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = downloadTimeout
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("Caffeinate", forHTTPHeaderField: "User-Agent")
        return request
    }

    func downloadAsset(
        request: URLRequest,
        destinationURL: URL,
        expectedSize: Int?,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let delegate = AppUpdateDownloadDelegate(
            destinationURL: destinationURL,
            expectedSize: expectedSize,
            progress: progress
        )
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer {
            session.invalidateAndCancel()
        }

        do {
            try await withTaskCancellationHandler {
                try await delegate.download(with: task)
            } onCancel: {
                task.cancel()
            }
            await delegate.waitForProgressReports()
        } catch {
            await delegate.waitForProgressReports()
            throw error
        }
    }

    static func verifyDownloadedSize(zipURL: URL, expectedSize: Int?) throws {
        guard let expectedSize else {
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let downloadedByteCount = (attributes[.size] as? NSNumber)?.intValue
        guard downloadedByteCount == expectedSize else {
            throw AppUpdateFailure(
                message: "Downloaded \(downloadedByteCount ?? 0) bytes, but GitHub reported \(expectedSize) bytes."
            )
        }
    }

    static func verifyDownloadedDigest(zipURL: URL, expectedDigest: AppUpdateReleaseAssetDigest) throws {
        let fileHandle = try FileHandle(forReadingFrom: zipURL)
        defer {
            try? fileHandle.close()
        }

        var hasher = SHA256()
        while let data = try fileHandle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualDigest == expectedDigest.sha256HexDigest else {
            throw AppUpdateFailure(message: "The downloaded update failed SHA-256 verification.")
        }
    }
}
