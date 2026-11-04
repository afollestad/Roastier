import Foundation
import Testing
@testable import CaffeinateKit

final class AppUpdateStagerTests {
    private let fixture: UpdateFixture
    private let zipURL: URL

    init() throws {
        fixture = try UpdateFixture()
        zipURL = fixture.root.appendingPathComponent("Caffeinate.app.zip")
        try Data("zip".utf8).write(to: zipURL)
    }

    deinit {
        fixture.remove()
    }

    @Test
    func stagesNewerSignedUpdateAndCleansWorkingFiles() async throws {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        let stagedUpdate = try await makeStager(runner).stageDownloadedUpdate(release: makeRelease(), downloadedZIPURL: zipURL)

        let stagedAppURL = fixture.updatesDirectory.appendingPathComponent("Staged/v0.2.0/Caffeinate.app")
        #expect(stagedUpdate.appBundleURL.standardizedFileURL == stagedAppURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: stagedAppURL.appendingPathComponent("Contents/Info.plist").path))
        #expect(FileManager.default.fileExists(atPath: fixture.updatesDirectory.appendingPathComponent("staged-update.json").path))
        #expect(!FileManager.default.fileExists(atPath: zipURL.path))
        #expect(try workingDirectories().isEmpty)
        #expect(runner.invocations.map(\.first).contains("/usr/sbin/spctl"))
    }

    @Test
    func removesSupersededStagedUpdates() async throws {
        let olderAppURL = fixture.updatesDirectory.appendingPathComponent("Staged/v0.1.5/Caffeinate.app")
        try UpdateFixture.writeApp(at: olderAppURL, version: "0.1.5")

        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        _ = try await makeStager(runner).stageDownloadedUpdate(release: makeRelease(), downloadedZIPURL: zipURL)

        #expect(!FileManager.default.fileExists(atPath: olderAppURL.deletingLastPathComponent().path))
    }

    @Test
    func rejectsUpdateThatIsNotNewer() async {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler(extractedVersion: "0.1.0"))
        await expectStagingFails("The update is not newer than this Caffeinate build.", runner: runner, release: makeRelease("0.1.0"))
    }

    @Test
    func rejectsVersionThatDoesNotMatchTheRelease() async {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler(extractedVersion: "0.3.0"))
        await expectStagingFails("The update's version does not match v0.2.0.", runner: runner)
    }

    @Test
    func rejectsForeignBundleIdentifier() async {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler(extractedBundleIdentifier: "com.example.other"))
        await expectStagingFails("The update's bundle identifier does not match Caffeinate.", runner: runner)
    }

    @Test
    func rejectsGatekeeperFailure() async {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler(spctlExitCode: 3))
        await expectStagingFails("Gatekeeper rejected the update. rejected", runner: runner)
    }

    @Test
    func rejectsDifferentSigningTeam() async {
        let otherTeam = UpdateFixture.signature.replacingOccurrences(of: "TEAM123456", with: "OTHER12345")
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler(stagedSignature: otherTeam))
        await expectStagingFails("The update is not signed by the same team as Caffeinate.", runner: runner)
    }

    @Test
    func rejectsAdHocSignatures() async {
        let adHoc = "Identifier=com.afollestad.caffeinate\nSignature=adhoc\nTeamIdentifier=not set"
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler(stagedSignature: adHoc))
        await expectStagingFails("The update is not signed by the same team as Caffeinate.", runner: runner)
    }

    @Test
    func refusesDevelopmentBuildsBeforeExtracting() async throws {
        let devFixture = try UpdateFixture(installFolder: ".build/app/debug")
        defer {
            devFixture.remove()
        }
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        let stager = AppUpdateStager(updatesDirectory: devFixture.updatesDirectory, processRunner: runner, bundle: devFixture.runningBundle)

        #expect(throws: AppUpdateFailure(message: "Updates cannot be installed over a development build.")) {
            try stager.validateInstallLocation()
        }
        await #expect(throws: AppUpdateFailure.self) {
            try await stager.stageDownloadedUpdate(release: makeRelease(), downloadedZIPURL: self.zipURL)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func loadReturnsNilWithoutMetadata() async throws {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        #expect(try await makeStager(runner).loadValidatedStagedUpdate() == nil)
    }

    @Test
    func loadRestoresValidStagedUpdate() async throws {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        let stagedUpdate = try await makeStager(runner).stageDownloadedUpdate(release: makeRelease(), downloadedZIPURL: zipURL)

        let loaded = try await makeStager(runner).loadValidatedStagedUpdate()
        #expect(loaded?.release == stagedUpdate.release)
        #expect(loaded?.appBundleURL == stagedUpdate.appBundleURL)
    }

    @Test
    func loadDiscardsUpdateTheRunningAppAlreadyHas() async throws {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        let stagedUpdate = try await makeStager(runner).stageDownloadedUpdate(release: makeRelease(), downloadedZIPURL: zipURL)

        let updatedFixture = try UpdateFixture(runningVersion: "0.2.0")
        defer {
            updatedFixture.remove()
        }
        let stager = AppUpdateStager(updatesDirectory: fixture.updatesDirectory, processRunner: runner, bundle: updatedFixture.runningBundle)
        #expect(try await stager.loadValidatedStagedUpdate() == nil)
        #expect(!FileManager.default.fileExists(atPath: stagedUpdate.metadataURL.path))
        #expect(!FileManager.default.fileExists(atPath: stagedUpdate.appBundleURL.deletingLastPathComponent().path))
    }

    @Test
    func loadRemovesMalformedMetadata() async throws {
        let metadataURL = fixture.updatesDirectory.appendingPathComponent("staged-update.json")
        try FileManager.default.createDirectory(at: fixture.updatesDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: metadataURL)

        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        await #expect(throws: (any Error).self) {
            try await self.makeStager(runner).loadValidatedStagedUpdate()
        }
        #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
    }

    @Test
    func loadRejectsMetadataPointingOutsideStorageWithoutDeletingIt() async throws {
        let runner = FakeProcessRunner(handler: UpdateFixture.stagingHandler())
        let stagedUpdate = try await makeStager(runner).stageDownloadedUpdate(release: makeRelease(), downloadedZIPURL: zipURL)
        let metadataURL = stagedUpdate.metadataURL
        let externalAppURL = fixture.root.appendingPathComponent("Elsewhere/Caffeinate.app")
        try UpdateFixture.writeApp(at: externalAppURL, version: "0.2.0")
        let traversalURL = fixture.updatesDirectory.appendingPathComponent("Staged/../../Elsewhere/Caffeinate.app")
        let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
            .replacingOccurrences(
                of: stagedUpdate.appBundleURL.absoluteString.replacingOccurrences(of: "/", with: "\\/"),
                with: traversalURL.absoluteString.replacingOccurrences(of: "/", with: "\\/")
            )
        try Data(metadata.utf8).write(to: metadataURL)

        await #expect(throws: AppUpdateFailure(message: "The staged app is outside Caffeinate's update storage.")) {
            try await self.makeStager(runner).loadValidatedStagedUpdate()
        }
        #expect(FileManager.default.fileExists(atPath: externalAppURL.path))
    }

    private func makeStager(_ runner: FakeProcessRunner) -> AppUpdateStager {
        AppUpdateStager(updatesDirectory: fixture.updatesDirectory, processRunner: runner, bundle: fixture.runningBundle)
    }

    private func expectStagingFails(
        _ message: String,
        runner: FakeProcessRunner,
        release: AppUpdateRelease = makeRelease(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await #expect(throws: AppUpdateFailure(message: message), sourceLocation: sourceLocation) {
            try await self.makeStager(runner).stageDownloadedUpdate(release: release, downloadedZIPURL: self.zipURL)
        }
        let stagedRoot = fixture.updatesDirectory.appendingPathComponent("Staged")
        #expect(!FileManager.default.fileExists(atPath: stagedRoot.path), sourceLocation: sourceLocation)
        #expect((try? workingDirectories().isEmpty) ?? true, sourceLocation: sourceLocation)
    }

    private func workingDirectories() throws -> [URL] {
        let workingRoot = fixture.updatesDirectory.appendingPathComponent("Working")
        guard FileManager.default.fileExists(atPath: workingRoot.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(at: workingRoot, includingPropertiesForKeys: nil)
    }
}
