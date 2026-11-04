import Foundation
import Synchronization
import Testing
@testable import CaffeinateKit

@MainActor
final class AppUpdateInstallerTests {
    private let fixture: UpdateFixture
    private let launches = HelperLaunches()
    private var didTerminate = false

    init() throws {
        fixture = try UpdateFixture()
    }

    deinit {
        fixture.remove()
    }

    @Test
    func launchesHelperThenTerminates() async throws {
        let stagedUpdate = try stageUpdate()
        let runner = FakeProcessRunner()

        try await makeInstaller(runner).installAndRelaunch(stagedUpdate: stagedUpdate)

        let launch = try #require(launches.all.first)
        #expect(FileManager.default.fileExists(atPath: launch.helperURL.path))
        #expect(launch.arguments[0] == "4242")
        #expect(launch.arguments[1] == stagedUpdate.appBundleURL.path)
        #expect(URL(fileURLWithPath: launch.arguments[3]).lastPathComponent == "Caffeinate.app")
        #expect(URL(fileURLWithPath: launch.arguments[4]).lastPathComponent.hasPrefix(".Caffeinate.app.backup-"))
        #expect(didTerminate)
        #expect(runner.invocations.count == 2)
    }

    @Test
    func refusesMissingStagedAppWithoutLaunching() async throws {
        let stagedUpdate = try stageUpdate()
        try FileManager.default.removeItem(at: stagedUpdate.appBundleURL)

        await #expect(throws: AppUpdateFailure(message: "The downloaded update is no longer available.")) {
            try await self.makeInstaller(FakeProcessRunner()).installAndRelaunch(stagedUpdate: stagedUpdate)
        }
        #expect(launches.all.isEmpty)
        #expect(!didTerminate)
    }

    @Test
    func refusesUnsignedStagedApp() async throws {
        let stagedUpdate = try stageUpdate()
        let runner = FakeProcessRunner { _, args in
            let isStaged = args.last?.contains("/Updates/") ?? false
            return ProcessResult(stdout: "", stderr: isStaged ? "code object is not signed" : "", exitCode: isStaged ? 1 : 0)
        }

        await #expect(throws: AppUpdateFailure(message: "The downloaded update is not signed correctly. code object is not signed")) {
            try await self.makeInstaller(runner).installAndRelaunch(stagedUpdate: stagedUpdate)
        }
        #expect(!didTerminate)
    }

    private func makeInstaller(_ runner: FakeProcessRunner) -> AppUpdateInstaller {
        AppUpdateInstaller(
            updatesDirectory: fixture.updatesDirectory,
            processRunner: runner,
            terminateApp: { [weak self] in
                self?.didTerminate = true
            },
            bundle: fixture.runningBundle,
            processIdentifier: { 4242 },
            launchHelper: { [launches] helperURL, arguments in
                launches.record(helperURL: helperURL, arguments: arguments)
            }
        )
    }

    /// Writes a staged app and its metadata where the stager would have.
    private func stageUpdate() throws -> StagedAppUpdate {
        let paths = AppUpdateStoragePaths(updatesDirectory: fixture.updatesDirectory)
        let appURL = try paths.stagedAppURL(directoryName: "v0.2.0")
        try UpdateFixture.writeApp(at: appURL, version: "0.2.0")
        let stagedUpdate = StagedAppUpdate(
            release: makeRelease(),
            appBundleURL: appURL,
            metadataURL: paths.metadataURL,
            stagedAt: Date()
        )
        try JSONEncoder.appUpdateMetadata
            .encode(AppUpdateStagedMetadata(stagedUpdate: stagedUpdate))
            .write(to: paths.metadataURL)
        return stagedUpdate
    }
}

private final class HelperLaunches: Sendable {
    private let launches = Mutex<[(helperURL: URL, arguments: [String])]>([])

    var all: [(helperURL: URL, arguments: [String])] {
        launches.withLock { $0 }
    }

    func record(helperURL: URL, arguments: [String]) {
        launches.withLock { $0.append((helperURL, arguments)) }
    }
}
