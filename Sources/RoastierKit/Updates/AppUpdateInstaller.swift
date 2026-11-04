import Foundation

/// Hands a staged update to a detached helper script that swaps it in after this process quits, then quits.
struct AppUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
    typealias LaunchHelper = @Sendable (_ helperURL: URL, _ arguments: [String]) throws -> Void

    private let updatesDirectory: URL
    private let storagePaths: AppUpdateStoragePaths
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    private let installLocation: AppUpdateInstallLocation
    private let processIdentifier: @Sendable () -> Int32
    private let helperScript: AppUpdateInstallHelperScript
    private let launchHelper: LaunchHelper
    private let terminateApp: @MainActor @Sendable () -> Void

    /// - Parameter terminateApp: Quits the app once the helper is running; the helper waits for this process to exit.
    init(
        updatesDirectory: URL,
        processRunner: any ProcessRunning,
        terminateApp: @escaping @MainActor @Sendable () -> Void,
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        processIdentifier: @escaping @Sendable () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        helperScript: AppUpdateInstallHelperScript = .live,
        launchHelper: @escaping LaunchHelper = AppUpdateInstaller.launchDetachedHelper
    ) {
        self.updatesDirectory = updatesDirectory
        storagePaths = AppUpdateStoragePaths(updatesDirectory: updatesDirectory)
        self.processRunner = processRunner
        self.fileManager = fileManager
        installLocation = AppUpdateInstallLocation(bundle: bundle, fileManager: fileManager)
        self.processIdentifier = processIdentifier
        self.helperScript = helperScript
        self.launchHelper = launchHelper
        self.terminateApp = terminateApp
    }

    func installAndRelaunch(stagedUpdate: StagedAppUpdate) async throws {
        let targetAppURL = try installLocation.validatedBundleURL()
        let stagedDirectory = try await verifyInstallInputs(targetAppURL: targetAppURL, stagedUpdate: stagedUpdate)

        let helpersDirectory = updatesDirectory.appendingPathComponent("Helpers", isDirectory: true)
        let logsDirectory = updatesDirectory.appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: helpersDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let helperURL = helpersDirectory
            .appendingPathComponent("install-\(UUID().uuidString)")
            .appendingPathExtension("zsh")
        let logURL = logsDirectory
            .appendingPathComponent("install-\(stagedUpdate.release.tagName.sanitizedForPathComponent)-\(UUID().uuidString)")
            .appendingPathExtension("log")
        let backupAppURL = targetAppURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Roastier.app.backup-\(UUID().uuidString)", isDirectory: true)

        try helperScript.contents.write(to: helperURL, atomically: true, encoding: .utf8)
        try launchHelper(helperURL, helperScript.arguments(for: AppUpdateInstallHelperInvocation(
            runningProcessIdentifier: processIdentifier(),
            stagedAppURL: stagedUpdate.appBundleURL,
            stagedDirectoryURL: stagedDirectory,
            targetAppURL: targetAppURL,
            backupAppURL: backupAppURL,
            logURL: logURL,
            metadataURL: storagePaths.metadataURL,
            quarantinedMetadataURL: storagePaths.quarantinedMetadataURL(id: UUID()),
            helperURL: helperURL
        )))
        await terminateApp()
    }

    static func launchDetachedHelper(helperURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path] + arguments
        try process.run()
    }
}

private extension AppUpdateInstaller {
    /// Re-checks the staged files right before install, since they sat on disk since staging.
    func verifyInstallInputs(targetAppURL: URL, stagedUpdate: StagedAppUpdate) async throws -> URL {
        try storagePaths.validateMetadataURL(stagedUpdate.metadataURL)
        let stagedDirectory = try storagePaths.validatedStagedDirectory(containing: stagedUpdate.appBundleURL)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stagedUpdate.appBundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppUpdateFailure(message: "The downloaded update is no longer available.")
        }
        guard fileManager.fileExists(atPath: storagePaths.metadataURL.path) else {
            throw AppUpdateFailure(message: "The downloaded update's metadata is no longer available.")
        }

        try await verifySignature(of: targetAppURL, failureMessage: "The running app is not signed correctly.")
        try await verifySignature(of: stagedUpdate.appBundleURL, failureMessage: "The downloaded update is not signed correctly.")
        return stagedDirectory
    }

    func verifySignature(of appURL: URL, failureMessage: String) async throws {
        let result = try await processRunner.run(
            executable: "/usr/bin/codesign",
            args: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path],
            timeout: .seconds(60)
        )
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateFailure(message: detail.isEmpty ? failureMessage : "\(failureMessage) \(detail)")
        }
    }
}
