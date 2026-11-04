import Foundation

/// Finds the newest stable release through GitHub's public REST API, without authentication.
struct GitHubAppUpdateReleaseClient: AppUpdateReleaseClient, @unchecked Sendable {
    static let expectedAssetName = "Caffeinate.app.zip"
    static let defaultReleasesURL = URL(string: "https://api.github.com/repos/afollestad/caffeinate-menubar/releases?per_page=100")

    private let releasesURL: URL?
    private let sessionConfiguration: URLSessionConfiguration

    init(
        releasesURL: URL? = GitHubAppUpdateReleaseClient.defaultReleasesURL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.releasesURL = releasesURL
        self.sessionConfiguration = sessionConfiguration
    }

    func latestRelease() async -> AppUpdateReleaseLookupResult {
        guard let releasesURL else {
            return .unavailable(.invalidRelease("The GitHub releases URL is malformed."))
        }

        var request = URLRequest(url: releasesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Caffeinate", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: sessionConfiguration)
        defer {
            session.finishTasksAndInvalidate()
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unavailable(.transportFailed(error.localizedDescription))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .unavailable(.transportFailed("GitHub returned a non-HTTP response."))
        }
        if let reason = Self.failureReason(for: httpResponse) {
            return .unavailable(reason)
        }

        let releases: [GitHubReleaseResponse]
        do {
            releases = try JSONDecoder().decode([GitHubReleaseResponse].self, from: data)
        } catch {
            return .unavailable(.decodingFailed(error.localizedDescription))
        }
        return Self.latestInstallableRelease(from: releases)
    }
}

private extension GitHubAppUpdateReleaseClient {
    static func failureReason(for response: HTTPURLResponse) -> AppUpdateUnavailableReason? {
        let statusCode = response.statusCode
        if (200..<300).contains(statusCode) {
            return nil
        }
        let isRateLimited = statusCode == 429
            || (statusCode == 403 && response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0")
        guard isRateLimited else {
            return .requestFailed(statusCode: statusCode)
        }
        let resetDate = response.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return .rateLimited(resetDate: resetDate)
    }

    /// Picks the highest stable semver rather than GitHub's newest-created release, then validates only that one.
    static func latestInstallableRelease(from releases: [GitHubReleaseResponse]) -> AppUpdateReleaseLookupResult {
        let stableReleases = releases.filter { !$0.draft && !$0.prerelease }
        guard let firstStable = stableReleases.first else {
            return .unavailable(.noRelease)
        }
        let latest = stableReleases
            .compactMap { release in AppUpdateVersion(string: release.tagName).map { (release, $0) } }
            .max { $0.1 < $1.1 }
        guard let (release, version) = latest else {
            return .unavailable(.malformedVersion(firstStable.tagName))
        }

        guard let htmlURL = URL(string: release.htmlURL), htmlURL.scheme == "https" else {
            return .unavailable(.invalidRelease("Malformed release URL \(release.htmlURL)."))
        }
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            return .unavailable(.missingAsset(expectedName: expectedAssetName))
        }
        guard let downloadURL = URL(string: asset.browserDownloadURL), downloadURL.scheme == "https" else {
            return .unavailable(.invalidRelease("Malformed download URL \(asset.browserDownloadURL)."))
        }
        guard let rawDigest = asset.digest, !rawDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.missingAssetDigest(expectedName: expectedAssetName))
        }
        guard let digest = AppUpdateReleaseAssetDigest(gitHubDigest: rawDigest) else {
            return .unavailable(.invalidRelease("Malformed asset digest \(rawDigest)."))
        }

        return .found(
            AppUpdateRelease(
                tagName: release.tagName,
                version: version,
                htmlURL: htmlURL,
                asset: AppUpdateReleaseAsset(name: asset.name, downloadURL: downloadURL, size: asset.size, digest: digest)
            )
        )
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAssetResponse]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAssetResponse: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int?
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }
}
