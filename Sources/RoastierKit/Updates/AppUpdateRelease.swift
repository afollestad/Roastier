import Foundation

/// The newest stable GitHub Release, already validated as installable.
public struct AppUpdateRelease: Equatable, Sendable {
    public let tagName: String
    public let version: AppUpdateVersion
    /// The release page, which doubles as the release notes and a manual download.
    public let htmlURL: URL
    let asset: AppUpdateReleaseAsset
}

struct AppUpdateReleaseAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let size: Int?
    let digest: AppUpdateReleaseAssetDigest
}

struct AppUpdateReleaseAssetDigest: Equatable, Sendable {
    let sha256HexDigest: String

    /// Parses GitHub's `sha256:<hex>` asset digest format.
    init?(gitHubDigest: String) {
        let components = gitHubDigest
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].lowercased() == "sha256" else {
            return nil
        }
        self.init(sha256HexDigest: String(components[1]))
    }

    init?(sha256HexDigest: String) {
        let normalizedDigest = sha256HexDigest
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedDigest.count == 64,
              normalizedDigest.allSatisfy(\.isHexDigit) else {
            return nil
        }
        self.sha256HexDigest = normalizedDigest
    }

    var gitHubDigest: String {
        "sha256:\(sha256HexDigest)"
    }
}

public enum AppUpdateUnavailableReason: Equatable, Sendable {
    case noRelease
    case malformedVersion(String)
    case missingAsset(expectedName: String)
    case missingAssetDigest(expectedName: String)
    /// A release or asset URL, or an asset digest, that GitHub returned malformed.
    case invalidRelease(String)
    case requestFailed(statusCode: Int)
    case rateLimited(resetDate: Date?)
    case decodingFailed(String)
    case transportFailed(String)

    public var displayDescription: String {
        switch self {
        case .noRelease:
            "No stable GitHub release is available."
        case .malformedVersion(let version):
            "The version could not be read: \(version)."
        case .missingAsset(let expectedName):
            "The latest release is missing \(expectedName)."
        case .missingAssetDigest(let expectedName):
            "The latest release is missing a SHA-256 digest for \(expectedName)."
        case .invalidRelease(let detail):
            "The latest release is invalid: \(detail)"
        case .requestFailed(let statusCode):
            "GitHub returned HTTP \(statusCode)."
        case .rateLimited(let resetDate):
            Self.rateLimitedDescription(resetDate: resetDate)
        case .decodingFailed(let message):
            "GitHub's release list could not be read: \(message)"
        case .transportFailed(let message):
            "The update check failed: \(message)"
        }
    }

    private static func rateLimitedDescription(resetDate: Date?) -> String {
        guard let resetDate else {
            return "GitHub is rate limiting update checks."
        }
        return "GitHub is rate limiting update checks until \(resetDate.formatted(date: .omitted, time: .shortened))."
    }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
    case updateAvailable(AppUpdateRelease)
    case upToDate(AppUpdateRelease)
    case unavailable(AppUpdateUnavailableReason)
}
