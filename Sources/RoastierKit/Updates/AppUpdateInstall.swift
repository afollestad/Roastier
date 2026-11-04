import Foundation

public struct AppUpdateFailure: Equatable, Sendable, LocalizedError {
    public let message: String

    public var errorDescription: String? {
        message
    }

    static func from(_ error: any Error) -> AppUpdateFailure {
        if let failure = error as? AppUpdateFailure {
            return failure
        }
        return AppUpdateFailure(message: error.localizedDescription)
    }
}

/// A downloaded, validated app bundle waiting in update storage for a restart.
public struct StagedAppUpdate: Equatable, Sendable {
    public let release: AppUpdateRelease
    let appBundleURL: URL
    let metadataURL: URL
    let stagedAt: Date
}

public enum AppUpdateDownloadState: Equatable, Sendable {
    case idle
    case downloading(AppUpdateRelease, progress: Double)
    case staging(AppUpdateRelease)
    case readyToInstall(StagedAppUpdate)
    case installing(StagedAppUpdate)
    case failed(AppUpdateFailure)
}

protocol AppUpdateDownloading: Sendable {
    /// Returns the downloaded ZIP after verifying its size and SHA-256 digest.
    func download(
        release: AppUpdateRelease,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL
}

protocol AppUpdateStaging: Sendable {
    /// Throws when the running app can't be replaced in place, so callers can skip a doomed download.
    func validateInstallLocation() throws

    func stageDownloadedUpdate(
        release: AppUpdateRelease,
        downloadedZIPURL: URL
    ) async throws -> StagedAppUpdate

    func loadValidatedStagedUpdate() async throws -> StagedAppUpdate?
}

protocol AppUpdateInstalling: Sendable {
    func installAndRelaunch(stagedUpdate: StagedAppUpdate) async throws
}

struct AppUpdateStoragePaths: Sendable {
    static let appBundleName = "Roastier.app"

    let updatesDirectory: URL

    var metadataURL: URL {
        updatesDirectory.appendingPathComponent("staged-update.json")
    }

    var stagedRootURL: URL {
        updatesDirectory.appendingPathComponent("Staged", isDirectory: true)
    }

    func quarantinedMetadataURL(id: UUID) -> URL {
        updatesDirectory
            .appendingPathComponent("staged-update.installing-\(id.uuidString)")
            .appendingPathExtension("json")
    }

    func stagedAppURL(directoryName: String) throws -> URL {
        let appURL = stagedRootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(Self.appBundleName, isDirectory: true)
        _ = try validatedStagedDirectory(containing: appURL)
        return appURL
    }

    func validateMetadataURL(_ candidateURL: URL) throws {
        guard candidateURL.isFileURL,
              candidateURL.standardizedFileURL == metadataURL.standardizedFileURL else {
            throw AppUpdateFailure(message: "The staged update metadata is outside Roastier's update storage.")
        }
    }

    /// Returns the `Staged/<name>` directory holding `appBundleURL`, after rejecting traversal and symlinks out of
    /// update storage. Cleanup may delete only the directory this returns.
    func validatedStagedDirectory(containing appBundleURL: URL) throws -> URL {
        let standardizedRoot = stagedRootURL.standardizedFileURL
        let standardizedApp = appBundleURL.standardizedFileURL
        let standardizedDirectory = standardizedApp.deletingLastPathComponent()
        let directoryName = standardizedDirectory.lastPathComponent
        let pathComponents = appBundleURL.pathComponents

        guard appBundleURL.isFileURL,
              !pathComponents.contains("."),
              !pathComponents.contains(".."),
              standardizedApp.lastPathComponent == Self.appBundleName,
              !directoryName.isEmpty,
              directoryName != ".",
              directoryName != "..",
              standardizedDirectory.deletingLastPathComponent() == standardizedRoot else {
            throw AppUpdateFailure(message: "The staged app is outside Roastier's update storage.")
        }

        let resolvedUpdatesDirectory = updatesDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let resolvedDirectory = standardizedDirectory.resolvingSymlinksInPath()
        let resolvedApp = standardizedApp.resolvingSymlinksInPath()
        guard resolvedRoot.deletingLastPathComponent().path == resolvedUpdatesDirectory.path,
              resolvedRoot.lastPathComponent == "Staged",
              resolvedDirectory.deletingLastPathComponent().path == resolvedRoot.path,
              resolvedDirectory.lastPathComponent == directoryName,
              resolvedApp.deletingLastPathComponent().path == resolvedDirectory.path,
              resolvedApp.lastPathComponent == Self.appBundleName else {
            throw AppUpdateFailure(message: "The staged app is outside Roastier's update storage.")
        }

        return standardizedDirectory
    }
}
