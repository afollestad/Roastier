import Foundation
import Testing
@testable import CaffeinateKit

@MainActor
struct AppUpdateManagerTests {
    private let client = FakeReleaseClient(.found(makeRelease()))
    private let downloader = FakeDownloader()
    private let stager = FakeStager()
    private let installer = FakeInstaller()

    @Test
    func checkFindingAnUpdateDownloadsAndStagesIt() async {
        let manager = makeManager()

        #expect(await manager.forceCheck() == .updateAvailable(makeRelease()))
        #expect(manager.status == .updateAvailable(makeRelease()))
        #expect(manager.downloadState == .downloading(makeRelease(), progress: 0))
        #expect(manager.badge == .updateAvailable)

        await manager.downloadTask?.value
        #expect(downloader.downloadedTags == ["v0.2.0"])
        #expect(manager.stagedUpdate == makeStagedUpdate(makeRelease()))
        #expect(manager.downloadState == .readyToInstall(makeStagedUpdate(makeRelease())))
        #expect(manager.badge == .readyToInstall)
        #expect(manager.downloadTask == nil)
    }

    @Test
    func automaticChecksDoNotRetryAFailedTagButManualChecksDo() async {
        downloader.setError(AppUpdateFailure(message: "offline"))
        let manager = makeManager()

        await manager.runCheck(trigger: .automatic)
        await manager.downloadTask?.value
        #expect(manager.downloadState == .failed(AppUpdateFailure(message: "offline")))
        #expect(manager.badge == .updateAvailable)

        await manager.runCheck(trigger: .automatic)
        #expect(manager.downloadTask == nil)
        #expect(downloader.downloadedTags == ["v0.2.0"])

        downloader.setError(nil)
        await manager.forceCheck()
        await manager.downloadTask?.value
        #expect(downloader.downloadedTags == ["v0.2.0", "v0.2.0"])
        #expect(manager.badge == .readyToInstall)
    }

    @Test
    func automaticChecksDownloadANewerTagAfterAFailure() async {
        downloader.setError(AppUpdateFailure(message: "offline"))
        let manager = makeManager()
        await manager.runCheck(trigger: .automatic)
        await manager.downloadTask?.value

        downloader.setError(nil)
        client.setResult(.found(makeRelease("0.3.0")))
        await manager.runCheck(trigger: .automatic)
        await manager.downloadTask?.value
        #expect(downloader.downloadedTags == ["v0.2.0", "v0.3.0"])
        #expect(manager.stagedUpdate?.release == makeRelease("0.3.0"))
    }

    @Test
    func unreplaceableInstallFailsWithoutDownloading() async {
        let failure = AppUpdateFailure(message: "Updates cannot be installed over a development build.")
        stager.setLocationError(failure)
        let manager = makeManager()

        await manager.forceCheck()
        #expect(manager.downloadTask == nil)
        #expect(downloader.downloadedTags.isEmpty)
        #expect(manager.downloadState == .failed(failure))
        #expect(manager.badge == .updateAvailable)
    }

    @Test
    func stagedUpdateFromLastLaunchIsReadyWithoutDownloadingAgain() async {
        stager.setLoadResult(makeStagedUpdate(makeRelease()))
        let manager = makeManager()

        await manager.loadStagedUpdate()
        #expect(manager.downloadState == .readyToInstall(makeStagedUpdate(makeRelease())))
        #expect(manager.badge == .readyToInstall)

        await manager.runCheck(trigger: .automatic)
        #expect(manager.downloadTask == nil)
        #expect(downloader.downloadedTags.isEmpty)
    }

    @Test
    func failedReplacementKeepsOfferingTheStagedUpdate() async {
        stager.setLoadResult(makeStagedUpdate(makeRelease()))
        client.setResult(.found(makeRelease("0.3.0")))
        downloader.setError(AppUpdateFailure(message: "offline"))
        let manager = makeManager()

        await manager.loadStagedUpdate()
        await manager.runCheck(trigger: .automatic)
        await manager.downloadTask?.value
        #expect(downloader.downloadedTags == ["v0.3.0"])
        #expect(manager.downloadState == .readyToInstall(makeStagedUpdate(makeRelease())))
        #expect(manager.badge == .readyToInstall)
    }

    @Test
    func onlyManualChecksReportBeingUpToDate() async {
        client.setResult(.found(makeRelease("0.1.0")))
        let manager = makeManager()

        await manager.runCheck(trigger: .automatic)
        #expect(manager.status == .upToDate(makeRelease("0.1.0")))
        #expect(manager.manualCheckFeedback == nil)
        #expect(manager.badge == .none)

        await manager.forceCheck()
        #expect(manager.manualCheckFeedback == .upToDate)
        manager.dismissManualCheckFeedback()
        #expect(manager.manualCheckFeedback == nil)
    }

    @Test
    func failedChecksKeepTheKnownReleaseAndOnlyManualOnesSaySo() async {
        let manager = makeManager()
        await manager.forceCheck()
        await manager.downloadTask?.value

        client.setResult(.unavailable(.requestFailed(statusCode: 503)))
        await manager.runCheck(trigger: .automatic)
        #expect(manager.manualCheckFeedback == nil)
        #expect(manager.status == .updateAvailable(makeRelease()))

        await manager.forceCheck()
        #expect(manager.manualCheckFeedback == .unavailable(.requestFailed(statusCode: 503)))
        #expect(manager.status == .updateAvailable(makeRelease()))
        #expect(manager.latestRelease == makeRelease())
    }

    @Test
    func overlappingChecksShareOneLookup() async {
        let (gate, opener) = AsyncStream.makeStream(of: Void.self)
        let client = FakeReleaseClient(.found(makeRelease("0.1.0")), gate: gate)
        let manager = makeManager(client: client)

        // Both tasks run on the main actor, in order, up to their shared lookup before the gate opens.
        let manual = Task { await manager.forceCheck() }
        let automatic = Task { await manager.runCheck(trigger: .automatic) }
        while client.callCount == 0 {
            await Task.yield()
        }
        #expect(manager.isChecking)
        opener.yield()
        opener.finish()

        #expect(await manual.value == .upToDate(makeRelease("0.1.0")))
        #expect(await automatic.value == .upToDate(makeRelease("0.1.0")))
        #expect(client.callCount == 1)
        #expect(!manager.isChecking)
    }

    @Test
    func automaticChecksRunAtLaunchAndEverySixHours() async {
        let (sleeps, recorder) = AsyncStream.makeStream(of: Duration.self)
        let manager = makeManager { duration in
            recorder.yield(duration)
            try await Task.sleep(for: .seconds(3_600))
        }

        manager.startAutomaticChecks()
        for await duration in sleeps {
            #expect(duration == .seconds(21_600))
            break
        }
        #expect(client.callCount == 1)
    }

    @Test
    func installHandsTheStagedUpdateToTheInstaller() async {
        stager.setLoadResult(makeStagedUpdate(makeRelease()))
        let manager = makeManager()
        await manager.loadStagedUpdate()

        await manager.installDownloadedUpdate()
        #expect(installer.installed == [makeStagedUpdate(makeRelease())])
        #expect(manager.downloadState == .installing(makeStagedUpdate(makeRelease())))
    }

    @Test
    func repeatedInstallRequestsStartOneInstall() async {
        stager.setLoadResult(makeStagedUpdate(makeRelease()))
        let manager = makeManager()
        await manager.loadStagedUpdate()

        // The fake installer returns instead of quitting, leaving the first install in progress.
        await manager.installDownloadedUpdate()
        await manager.installDownloadedUpdate()
        #expect(installer.installed.count == 1)
    }

    @Test
    func failedInstallForgetsTheStagedUpdateSoARetryDownloadsAgain() async {
        let failure = AppUpdateFailure(message: "Caffeinate's install location is not writable.")
        installer.setError(failure)
        stager.setLoadResult(makeStagedUpdate(makeRelease()))
        let manager = makeManager()
        await manager.loadStagedUpdate()

        await manager.installDownloadedUpdate()
        #expect(manager.downloadState == .failed(failure))
        #expect(manager.stagedUpdate == nil)

        await manager.forceCheck()
        await manager.downloadTask?.value
        #expect(downloader.downloadedTags == ["v0.2.0"])
        #expect(manager.badge == .readyToInstall)
    }

    private func makeManager(
        client: FakeReleaseClient? = nil,
        sleep: @escaping AwakeController.Sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
    ) -> AppUpdateManager {
        AppUpdateManager(
            releaseClient: client ?? self.client,
            versionProvider: FakeVersionProvider(),
            downloader: downloader,
            stager: stager,
            installer: installer,
            sleep: sleep
        )
    }
}
