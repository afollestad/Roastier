import Foundation

/// Extracts a downloaded ZIP and admits its app into update storage only if it is the expected, newer,
/// Gatekeeper-approved build signed by the same identity as the running app.
struct AppUpdateStager: AppUpdateStaging, @unchecked Sendable {
    private let storagePaths: AppUpdateStoragePaths
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    private let installLocation: AppUpdateInstallLocation
    private let now: @Sendable () -> Date

    init(
        updatesDirectory: URL,
        processRunner: any ProcessRunning,
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        storagePaths = AppUpdateStoragePaths(updatesDirectory: updatesDirectory)
        self.processRunner = processRunner
        self.fileManager = fileManager
        installLocation = AppUpdateInstallLocation(bundle: bundle, fileManager: fileManager)
        self.now = now
    }

    func validateInstallLocation() throws {
        _ = try installLocation.validatedBundleURL()
    }

    func stageDownloadedUpdate(release: AppUpdateRelease, downloadedZIPURL: URL) async throws -> StagedAppUpdate {
        try validateInstallLocation()
        let workingDirectory = storagePaths.updatesDirectory
            .appendingPathComponent("Working", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extractedDirectory = workingDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workingDirectory)
            try? fileManager.removeItem(at: downloadedZIPURL)
        }

        try await runRequired(
            executable: "/usr/bin/ditto",
            args: ["-x", "-k", downloadedZIPURL.path, extractedDirectory.path],
            failureMessage: "Could not extract the update archive."
        )

        let extractedAppURL = extractedDirectory.appendingPathComponent(AppUpdateStoragePaths.appBundleName, isDirectory: true)
        try await validateExtractedApp(extractedAppURL, release: release)

        let stagedAppURL = try storagePaths.stagedAppURL(directoryName: release.tagName.sanitizedForPathComponent)
        let stagedDirectory = stagedAppURL.deletingLastPathComponent()
        try? fileManager.removeItem(at: stagedDirectory)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: extractedAppURL, to: stagedAppURL)

        let stagedUpdate = StagedAppUpdate(
            release: release,
            appBundleURL: stagedAppURL,
            metadataURL: storagePaths.metadataURL,
            stagedAt: now()
        )
        try JSONEncoder.appUpdateMetadata
            .encode(AppUpdateStagedMetadata(stagedUpdate: stagedUpdate))
            .write(to: storagePaths.metadataURL, options: [.atomic])
        removeSupersededStagedDirectories(keeping: stagedDirectory)
        return stagedUpdate
    }

    func loadValidatedStagedUpdate() async throws -> StagedAppUpdate? {
        let metadataData: Data
        do {
            metadataData = try Data(contentsOf: storagePaths.metadataURL)
        } catch {
            guard !error.isMissingFile else {
                return nil
            }
            try? fileManager.removeItem(at: storagePaths.metadataURL)
            throw error
        }

        let stagedUpdate: StagedAppUpdate
        do {
            let metadata = try JSONDecoder.appUpdateMetadata.decode(AppUpdateStagedMetadata.self, from: metadataData)
            let stagedDirectory = try storagePaths.validatedStagedDirectory(containing: metadata.appBundleURL)
            let candidate = try metadata.stagedUpdate(metadataURL: storagePaths.metadataURL)

            // The helper deletes staged files only after relaunching, so an installed update can still be on disk.
            if let runningVersion = installLocation.runningVersion, candidate.release.version <= runningVersion {
                try? fileManager.removeItem(at: storagePaths.metadataURL)
                try? fileManager.removeItem(at: stagedDirectory)
                return nil
            }

            try validateInstallLocation()
            try await validateExtractedApp(candidate.appBundleURL, release: candidate.release)
            stagedUpdate = candidate
        } catch let loadError {
            // Another copy may have staged a replacement while this one validated; leave that one alone.
            guard let metadataMatches = try? stagedMetadataMatches(metadataData) else {
                throw loadError
            }
            guard metadataMatches else {
                return nil
            }
            try? fileManager.removeItem(at: storagePaths.metadataURL)
            throw loadError
        }

        guard try stagedMetadataMatches(metadataData) else {
            return nil
        }
        return stagedUpdate
    }
}

private extension AppUpdateStager {
    func stagedMetadataMatches(_ expectedData: Data) throws -> Bool {
        do {
            return try Data(contentsOf: storagePaths.metadataURL) == expectedData
        } catch {
            guard error.isMissingFile else {
                throw error
            }
            return false
        }
    }

    /// Staging a newer release leaves the older one's directory behind; the install helper only removes its own.
    func removeSupersededStagedDirectories(keeping keptDirectory: URL) {
        let children = (try? fileManager.contentsOfDirectory(at: storagePaths.stagedRootURL, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.lastPathComponent != keptDirectory.lastPathComponent {
            let appURL = child.appendingPathComponent(AppUpdateStoragePaths.appBundleName, isDirectory: true)
            guard let directory = try? storagePaths.validatedStagedDirectory(containing: appURL) else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    func validateExtractedApp(_ appURL: URL, release: AppUpdateRelease) async throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              appURL.lastPathComponent == AppUpdateStoragePaths.appBundleName else {
            throw AppUpdateFailure(message: "The update archive did not contain Roastier.app at the top level.")
        }
        guard let stagedBundle = Bundle(url: appURL),
              stagedBundle.bundleIdentifier == installLocation.bundle.bundleIdentifier else {
            throw AppUpdateFailure(message: "The update's bundle identifier does not match Roastier.")
        }
        let stagedVersion = (stagedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppUpdateVersion.init(string:))
        guard let stagedVersion, stagedVersion == release.version else {
            throw AppUpdateFailure(message: "The update's version does not match \(release.tagName).")
        }
        if let runningVersion = installLocation.runningVersion, stagedVersion <= runningVersion {
            throw AppUpdateFailure(message: "The update is not newer than this Roastier build.")
        }

        try await runRequired(
            executable: "/usr/bin/codesign",
            args: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path],
            failureMessage: "The update's code signature is invalid."
        )
        try await runRequired(
            executable: "/usr/sbin/spctl",
            args: ["--assess", "--type", "execute", "--verbose=2", appURL.path],
            failureMessage: "Gatekeeper rejected the update."
        )
        try await verifySigningMatchesRunningApp(stagedAppURL: appURL)
    }

    func verifySigningMatchesRunningApp(stagedAppURL: URL) async throws {
        let runningSignature = try await signatureDetails(for: installLocation.bundle.bundleURL)
        let stagedSignature = try await signatureDetails(for: stagedAppURL)
        guard let runningTeamIdentifier = runningSignature.teamIdentifier,
              runningTeamIdentifier == stagedSignature.teamIdentifier else {
            throw AppUpdateFailure(message: "The update is not signed by the same team as Roastier.")
        }
        guard !runningSignature.authorities.isEmpty,
              runningSignature.authorities == stagedSignature.authorities else {
            throw AppUpdateFailure(message: "The update's signing identity does not match Roastier's.")
        }
    }

    func signatureDetails(for appURL: URL) async throws -> AppUpdateSignatureDetails {
        let result = try await processRunner.run(
            executable: "/usr/bin/codesign",
            args: ["-dv", "--verbose=4", appURL.path],
            timeout: .seconds(30)
        )
        guard result.succeeded else {
            throw AppUpdateFailure(message: "Could not read the app's signing identity.")
        }
        // `codesign -d` writes its report to stderr.
        return AppUpdateSignatureDetails(output: result.stderr)
    }

    func runRequired(executable: String, args: [String], failureMessage: String) async throws {
        let result = try await processRunner.run(executable: executable, args: args, timeout: .seconds(120))
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateFailure(message: detail.isEmpty ? failureMessage : "\(failureMessage) \(detail)")
        }
    }
}

private struct AppUpdateSignatureDetails {
    let teamIdentifier: String?
    let authorities: [String]

    init(output: String) {
        var teamIdentifier: String?
        var authorities: [String] = []
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("TeamIdentifier=") {
                teamIdentifier = String(line.dropFirst("TeamIdentifier=".count))
            } else if line.hasPrefix("Authority=") {
                authorities.append(String(line.dropFirst("Authority=".count)))
            }
        }
        // Ad hoc signatures report "not set", which must never count as a match.
        self.teamIdentifier = teamIdentifier == "not set" ? nil : teamIdentifier
        self.authorities = authorities
    }
}

private extension Error {
    var isMissingFile: Bool {
        let error = self as NSError
        return error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }
}
