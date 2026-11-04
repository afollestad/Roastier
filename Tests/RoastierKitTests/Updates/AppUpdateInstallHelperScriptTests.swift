import Foundation
import Testing
@testable import RoastierKit

/// Runs the real zsh helper against throwaway bundles, with fake copy and open tools.
final class AppUpdateInstallHelperScriptTests {
    private static let recordingOpenScript = """
        #!/bin/zsh
        echo "$1" >> "$OPEN_INVOCATIONS_FILE"
        exit 0
        """
    private static let copyScript = """
        #!/bin/zsh
        /usr/bin/ditto "$1" "$2"
        """

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RoastierHelperTests-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test
    func quarantinesMetadataBeforeRelaunchAndCleansUp() throws {
        // Fails the relaunch if the staged metadata still exists, which would make the new app re-offer itself.
        let fixture = try makeFixture(copyScript: Self.copyScript, openScript: """
            #!/bin/zsh
            echo "$1" >> "$OPEN_INVOCATIONS_FILE"
            if [ -e "$EXPECTED_METADATA_FILE" ]; then
              exit 41
            fi
            exit 0
            """)

        #expect(try fixture.run() == 0)
        #expect(exists(fixture.targetAppURL.appendingPathComponent("new.txt")))
        #expect(!exists(fixture.targetAppURL.appendingPathComponent("old.txt")))
        #expect(!exists(fixture.metadataURL))
        #expect(!exists(fixture.quarantinedMetadataURL))
        #expect(!exists(fixture.stagedDirectoryURL))
        #expect(!exists(fixture.backupAppURL))
        #expect(!exists(fixture.helperURL))
        #expect(try fixture.openInvocations() == [fixture.targetAppURL.path])
    }

    @Test
    func copyFailureRestoresAppAndMetadata() throws {
        let fixture = try makeFixture(copyScript: "#!/bin/zsh\nexit 1", openScript: Self.recordingOpenScript)

        #expect(try fixture.run() == 1)
        expectRolledBack(fixture)
        #expect(try fixture.openInvocations() == [fixture.targetAppURL.path])
    }

    @Test
    func relaunchFailureRestoresAppAndMetadata() throws {
        let fixture = try makeFixture(copyScript: Self.copyScript, openScript: """
            #!/bin/zsh
            echo "$1" >> "$OPEN_INVOCATIONS_FILE"
            exit 1
            """)

        #expect(try fixture.run() == 1)
        expectRolledBack(fixture)
        #expect(try fixture.openInvocations() == [fixture.targetAppURL.path, fixture.targetAppURL.path])
    }

    @Test
    func metadataQuarantineFailureLeavesBothAppsUntouched() throws {
        let fixture = try makeFixture(copyScript: "#!/bin/zsh\nexit 42", openScript: Self.recordingOpenScript)
        // `mv` would move the metadata into a directory at the quarantine path, so make that directory unwritable.
        let quarantinePath = fixture.quarantinedMetadataURL.path
        try FileManager.default.createDirectory(at: fixture.quarantinedMetadataURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: quarantinePath)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: quarantinePath)
        }

        #expect(try fixture.run() == 1)
        #expect(exists(fixture.targetAppURL.appendingPathComponent("old.txt")))
        #expect(!exists(fixture.targetAppURL.appendingPathComponent("new.txt")))
        #expect(exists(fixture.metadataURL))
        #expect(exists(fixture.stagedAppURL.appendingPathComponent("new.txt")))
        #expect(try fixture.openInvocations() == [fixture.targetAppURL.path])
        #expect(try String(contentsOf: fixture.logURL, encoding: .utf8).contains("Could not quarantine staged update metadata"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func expectRolledBack(_ fixture: HelperFixture, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(exists(fixture.targetAppURL.appendingPathComponent("old.txt")), sourceLocation: sourceLocation)
        #expect(!exists(fixture.targetAppURL.appendingPathComponent("new.txt")), sourceLocation: sourceLocation)
        #expect(exists(fixture.metadataURL), sourceLocation: sourceLocation)
        #expect(!exists(fixture.quarantinedMetadataURL), sourceLocation: sourceLocation)
        #expect(exists(fixture.stagedAppURL.appendingPathComponent("new.txt")), sourceLocation: sourceLocation)
        #expect(!exists(fixture.backupAppURL), sourceLocation: sourceLocation)
        #expect(exists(fixture.helperURL), sourceLocation: sourceLocation)
    }

    private func makeFixture(copyScript: String, openScript: String) throws -> HelperFixture {
        let updatesDirectory = root.appendingPathComponent("Updates", isDirectory: true)
        let stagedDirectoryURL = updatesDirectory.appendingPathComponent("Staged/v0.2.0", isDirectory: true)
        let fixture = HelperFixture(
            script: AppUpdateInstallHelperScript(
                copyExecutableURL: try writeExecutable(named: "copy.zsh", contents: copyScript),
                openExecutableURL: try writeExecutable(named: "open.zsh", contents: openScript),
                relaunchGraceSeconds: 0
            ),
            stagedAppURL: stagedDirectoryURL.appendingPathComponent("Roastier.app", isDirectory: true),
            stagedDirectoryURL: stagedDirectoryURL,
            targetAppURL: root.appendingPathComponent("Applications/Roastier.app", isDirectory: true),
            backupAppURL: root.appendingPathComponent("Applications/.Roastier.app.backup", isDirectory: true),
            logURL: updatesDirectory.appendingPathComponent("install.log"),
            metadataURL: updatesDirectory.appendingPathComponent("staged-update.json"),
            quarantinedMetadataURL: updatesDirectory.appendingPathComponent("staged-update.installing-test.json"),
            helperURL: updatesDirectory.appendingPathComponent("install-helper.zsh"),
            openInvocationsURL: updatesDirectory.appendingPathComponent("open-invocations.txt")
        )

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fixture.stagedAppURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.targetAppURL, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: fixture.stagedAppURL.appendingPathComponent("new.txt"))
        try Data("old".utf8).write(to: fixture.targetAppURL.appendingPathComponent("old.txt"))
        try Data("metadata".utf8).write(to: fixture.metadataURL)
        try fixture.script.contents.write(to: fixture.helperURL, atomically: true, encoding: .utf8)
        return fixture
    }

    private func writeExecutable(named name: String, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private struct HelperFixture {
    let script: AppUpdateInstallHelperScript
    let stagedAppURL: URL
    let stagedDirectoryURL: URL
    let targetAppURL: URL
    let backupAppURL: URL
    let logURL: URL
    let metadataURL: URL
    let quarantinedMetadataURL: URL
    let helperURL: URL
    let openInvocationsURL: URL

    /// Runs the helper to completion; `Int32.max` is never a live PID, so it skips waiting for the app to quit.
    func run() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path] + script.arguments(for: AppUpdateInstallHelperInvocation(
            runningProcessIdentifier: Int32.max,
            stagedAppURL: stagedAppURL,
            stagedDirectoryURL: stagedDirectoryURL,
            targetAppURL: targetAppURL,
            backupAppURL: backupAppURL,
            logURL: logURL,
            metadataURL: metadataURL,
            quarantinedMetadataURL: quarantinedMetadataURL,
            helperURL: helperURL
        ))
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["EXPECTED_METADATA_FILE": metadataURL.path, "OPEN_INVOCATIONS_FILE": openInvocationsURL.path]
        ) { _, fixtureValue in fixtureValue }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func openInvocations() throws -> [String] {
        guard FileManager.default.fileExists(atPath: openInvocationsURL.path) else {
            return []
        }
        return try String(contentsOf: openInvocationsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }
}
