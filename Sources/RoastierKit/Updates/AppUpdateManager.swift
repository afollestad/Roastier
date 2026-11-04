import Foundation
import Observation

/// The last successful check. Failures never replace it, so a flaky network can't hide a known update.
public enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case updateAvailable(AppUpdateRelease)
    case upToDate(AppUpdateRelease)
}

public enum AppUpdateBadge: Equatable, Sendable {
    case none
    case updateAvailable
    case readyToInstall
}

/// What a manual check found, shown until the popover closes. Automatic checks stay quiet.
public enum AppUpdateManualCheckFeedback: Equatable, Sendable {
    case upToDate
    case unavailable(AppUpdateUnavailableReason)
}

enum AppUpdateCheckTrigger: Equatable, Sendable {
    case automatic
    case manual
}

/// Checks GitHub for releases, downloads and stages newer ones in the background, and installs a staged update on
/// request.
@MainActor
@Observable
public final class AppUpdateManager {
    static let automaticCheckInterval: Duration = .seconds(6 * 60 * 60)

    public private(set) var status: AppUpdateStatus = .idle
    public private(set) var isChecking = false
    public private(set) var downloadState: AppUpdateDownloadState = .idle
    public private(set) var stagedUpdate: StagedAppUpdate?
    public private(set) var manualCheckFeedback: AppUpdateManualCheckFeedback?

    @ObservationIgnored private let checker: AppUpdateChecker
    @ObservationIgnored private let versionProvider: any AppVersionProviding
    @ObservationIgnored private let downloader: any AppUpdateDownloading
    @ObservationIgnored private let stager: any AppUpdateStaging
    @ObservationIgnored private let installer: any AppUpdateInstalling
    @ObservationIgnored private let sleep: AwakeController.Sleep
    @ObservationIgnored private var didStartAutomaticChecks = false
    @ObservationIgnored private var automaticCheckTask: Task<Void, Never>?
    @ObservationIgnored private var activeCheckTask: Task<AppUpdateCheckResult, Never>?
    @ObservationIgnored private var lastFailedDownloadTag: String?
    /// Internal so tests can await a background download instead of sleeping.
    @ObservationIgnored private(set) var downloadTask: Task<Void, Never>?

    init(
        releaseClient: any AppUpdateReleaseClient,
        versionProvider: any AppVersionProviding,
        downloader: any AppUpdateDownloading,
        stager: any AppUpdateStaging,
        installer: any AppUpdateInstalling,
        sleep: @escaping AwakeController.Sleep = { try await Task.sleep(for: $0) }
    ) {
        checker = AppUpdateChecker(releaseClient: releaseClient, versionProvider: versionProvider)
        self.versionProvider = versionProvider
        self.downloader = downloader
        self.stager = stager
        self.installer = installer
        self.sleep = sleep
    }

    isolated deinit {
        automaticCheckTask?.cancel()
        downloadTask?.cancel()
    }

    public var currentVersionString: String? {
        versionProvider.currentVersionString
    }

    public var latestRelease: AppUpdateRelease? {
        switch status {
        case .idle:
            nil
        case .updateAvailable(let release), .upToDate(let release):
            release
        }
    }

    public var badge: AppUpdateBadge {
        if stagedUpdate != nil {
            return .readyToInstall
        }
        if case .updateAvailable = status {
            return .updateAvailable
        }
        return .none
    }

    /// Restores a staged update from a previous launch, then checks now and every six hours after the last check.
    public func startAutomaticChecks() {
        guard !didStartAutomaticChecks else {
            return
        }
        didStartAutomaticChecks = true
        Task {
            await loadStagedUpdate()
            await runCheck(trigger: .automatic)
        }
    }

    /// Also the Download and Retry action: a manual check that finds an update always starts its download.
    @discardableResult
    public func forceCheck() async -> AppUpdateCheckResult {
        await runCheck(trigger: .manual)
    }

    public func dismissManualCheckFeedback() {
        manualCheckFeedback = nil
    }

    /// Quits and relaunches into the staged update; returns only if the install could not start or is already underway.
    public func installDownloadedUpdate() async {
        // A repeated click would launch a second helper that races the first over the app bundle.
        if case .installing = downloadState {
            return
        }
        guard let stagedUpdate else {
            downloadState = .failed(AppUpdateFailure(message: "No downloaded update is ready to install."))
            return
        }
        downloadState = .installing(stagedUpdate)
        do {
            try await installer.installAndRelaunch(stagedUpdate: stagedUpdate)
        } catch {
            // Forget the staged copy, so a retry downloads and validates a fresh one.
            self.stagedUpdate = nil
            downloadState = .failed(.from(error))
        }
    }

    @discardableResult
    func runCheck(trigger: AppUpdateCheckTrigger) async -> AppUpdateCheckResult {
        if trigger == .manual {
            manualCheckFeedback = nil
        }
        let check = activeCheckTask ?? startCheckTask()
        let result = await check.value
        if activeCheckTask == check {
            activeCheckTask = nil
            isChecking = false
        }
        apply(result, trigger: trigger)
        scheduleNextAutomaticCheck()
        return result
    }

    func loadStagedUpdate() async {
        guard stagedUpdate == nil else {
            return
        }
        do {
            guard let loadedUpdate = try await stager.loadValidatedStagedUpdate() else {
                return
            }
            stagedUpdate = loadedUpdate
            downloadState = .readyToInstall(loadedUpdate)
        } catch {
            downloadState = .failed(.from(error))
        }
    }
}

private extension AppUpdateManager {
    func startCheckTask() -> Task<AppUpdateCheckResult, Never> {
        let checker = checker
        let task = Task.detached(priority: .utility) {
            await checker.checkForUpdates()
        }
        activeCheckTask = task
        isChecking = true
        return task
    }

    func apply(_ result: AppUpdateCheckResult, trigger: AppUpdateCheckTrigger) {
        switch result {
        case .updateAvailable(let release):
            status = .updateAvailable(release)
            startDownloadIfNeeded(for: release, trigger: trigger)
        case .upToDate(let release):
            status = .upToDate(release)
            if case .failed = downloadState {
                downloadState = .idle
            }
            if trigger == .manual {
                manualCheckFeedback = .upToDate
            }
        case .unavailable(let reason):
            if trigger == .manual {
                manualCheckFeedback = .unavailable(reason)
            }
        }
    }

    func startDownloadIfNeeded(for release: AppUpdateRelease, trigger: AppUpdateCheckTrigger) {
        guard downloadTask == nil else {
            return
        }
        if let stagedUpdate, stagedUpdate.release.version >= release.version {
            return
        }
        if trigger == .automatic, lastFailedDownloadTag == release.tagName {
            return
        }
        do {
            try stager.validateInstallLocation()
        } catch {
            downloadFailed(release, error: error)
            return
        }

        downloadState = .downloading(release, progress: 0)
        downloadTask = Task {
            await download(release)
            downloadTask = nil
        }
    }

    func download(_ release: AppUpdateRelease) async {
        do {
            let zipURL = try await downloader.download(release: release) { [weak self] progress in
                await self?.reportProgress(progress, for: release)
            }
            downloadState = .staging(release)
            let stagedUpdate = try await stager.stageDownloadedUpdate(release: release, downloadedZIPURL: zipURL)
            self.stagedUpdate = stagedUpdate
            lastFailedDownloadTag = nil
            downloadState = .readyToInstall(stagedUpdate)
        } catch {
            downloadFailed(release, error: error)
        }
    }

    func downloadFailed(_ release: AppUpdateRelease, error: any Error) {
        lastFailedDownloadTag = release.tagName
        // An older staged update is still installable, so keep offering it over the failure.
        if let stagedUpdate {
            downloadState = .readyToInstall(stagedUpdate)
        } else {
            downloadState = .failed(.from(error))
        }
    }

    func reportProgress(_ progress: Double, for release: AppUpdateRelease) {
        guard case .downloading(let downloadingRelease, _) = downloadState, downloadingRelease == release else {
            return
        }
        downloadState = .downloading(release, progress: progress)
    }

    func scheduleNextAutomaticCheck() {
        guard didStartAutomaticChecks else {
            return
        }
        automaticCheckTask?.cancel()
        let sleep = sleep
        automaticCheckTask = Task { [weak self] in
            do {
                try await sleep(Self.automaticCheckInterval)
            } catch {
                return
            }
            await self?.runCheck(trigger: .automatic)
        }
    }
}

extension AppUpdateManager {
    /// The app's updater: GitHub Releases, staged under Application Support, swapped in by the install helper.
    public static func live(terminateApp: @escaping @MainActor @Sendable () -> Void) -> AppUpdateManager {
        var updatesDirectory = URL.applicationSupportDirectory.appendingPathComponent("Roastier/Updates", isDirectory: true)
        #if DEBUG
        // Keeps a development run from discarding a release copy's staged update.
        updatesDirectory.appendPathComponent("Debug", isDirectory: true)
        #endif
        let processRunner = ProcessRunner()
        return AppUpdateManager(
            releaseClient: GitHubAppUpdateReleaseClient(),
            versionProvider: BundleAppVersionProvider(),
            downloader: GitHubAppUpdateDownloader(),
            stager: AppUpdateStager(updatesDirectory: updatesDirectory, processRunner: processRunner),
            installer: AppUpdateInstaller(
                updatesDirectory: updatesDirectory,
                processRunner: processRunner,
                terminateApp: terminateApp
            )
        )
    }
}
