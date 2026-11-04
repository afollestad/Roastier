import Foundation

protocol AppUpdateReleaseClient: Sendable {
    func latestRelease() async -> AppUpdateReleaseLookupResult
}

enum AppUpdateReleaseLookupResult: Equatable, Sendable {
    case found(AppUpdateRelease)
    case unavailable(AppUpdateUnavailableReason)
}

/// Compares the newest installable release against the running app's version.
struct AppUpdateChecker: Sendable {
    let releaseClient: any AppUpdateReleaseClient
    let versionProvider: any AppVersionProviding

    func checkForUpdates() async -> AppUpdateCheckResult {
        guard let currentVersion = versionProvider.currentVersion else {
            return .unavailable(.malformedVersion(versionProvider.currentVersionString ?? ""))
        }

        switch await releaseClient.latestRelease() {
        case .found(let release):
            return release.version > currentVersion ? .updateAvailable(release) : .upToDate(release)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}
