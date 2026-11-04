import Foundation
import Synchronization
@testable import RoastierKit

/// Serves canned responses to sessions built from `configuration`. Each test stubs URLs on its own UUID host, so tests
/// can share the tables while running in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var statusCode = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var redirectURL: URL?
        var error: URLError?
    }

    private struct Tables {
        var responses: [URL: [Response]] = [:]
        var requests: [String: [URLRequest]] = [:]
    }

    private static let tables = Mutex(Tables())

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    static func uniqueURL(path: String) -> URL {
        URL(string: "https://\(UUID().uuidString.lowercased()).test/\(path)")!
    }

    static func stub(_ url: URL, _ response: Response) {
        tables.withLock { $0.responses[url, default: []].append(response) }
    }

    static func requests(to url: URL) -> [URLRequest] {
        tables.withLock { $0.requests[url.host() ?? ""] ?? [] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let request = request
        let response: Response? = Self.tables.withLock { tables in
            tables.requests[url.host() ?? "", default: []].append(request)
            guard var queue = tables.responses[url], !queue.isEmpty else {
                return nil
            }
            let next = queue.removeFirst()
            tables.responses[url] = queue
            return next
        }

        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let redirectURL = response.redirectURL {
            let redirect = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectURL.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: redirect)
            return
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records every invocation and answers from `handler` instead of running a real tool.
final class FakeProcessRunner: ProcessRunning {
    typealias Handler = @Sendable (_ executable: String, _ args: [String]) throws -> ProcessResult

    static let success = ProcessResult(stdout: "", stderr: "", exitCode: 0)

    private let handler: Handler
    private let recorded = Mutex<[[String]]>([])

    init(handler: @escaping Handler = { _, _ in FakeProcessRunner.success }) {
        self.handler = handler
    }

    var invocations: [[String]] {
        recorded.withLock { $0 }
    }

    func run(executable: String, args: [String], timeout: Duration) async throws -> ProcessResult {
        recorded.withLock { $0.append([executable] + args) }
        return try handler(executable, args)
    }
}

/// A throwaway directory holding a fake running `Roastier.app` and its update storage.
struct UpdateFixture {
    static let bundleIdentifier = "com.afollestad.roastier"
    static let signature = """
        Identifier=com.afollestad.roastier
        Authority=Developer ID Application: Test (TEAM123456)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        TeamIdentifier=TEAM123456
        """

    let root: URL
    let updatesDirectory: URL
    let runningAppURL: URL
    let runningBundle: Bundle

    init(runningVersion: String = "0.1.0", installFolder: String = "Applications") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoastierUpdateTests-\(UUID().uuidString)", isDirectory: true)
        updatesDirectory = root.appendingPathComponent("Updates", isDirectory: true)
        runningAppURL = root
            .appendingPathComponent(installFolder, isDirectory: true)
            .appendingPathComponent("Roastier.app", isDirectory: true)
        try Self.writeApp(at: runningAppURL, version: runningVersion)
        runningBundle = Bundle(url: runningAppURL)!
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func writeApp(at appURL: URL, version: String, bundleIdentifier: String = bundleIdentifier) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "Roastier",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version
        ]
        try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

    /// Answers the stager's tools: `ditto -x` writes an extracted app, and `codesign -dv` reports `stagedSignature` for
    /// any app under update storage and `signature` for the running app.
    static func stagingHandler(
        extractedVersion: String = "0.2.0",
        extractedBundleIdentifier: String = bundleIdentifier,
        stagedSignature: String = signature,
        spctlExitCode: Int32 = 0
    ) -> FakeProcessRunner.Handler {
        { executable, args in
            switch (executable, args.first) {
            case ("/usr/bin/ditto", "-x"):
                let extractedAppURL = URL(fileURLWithPath: args[3]).appendingPathComponent("Roastier.app")
                try writeApp(at: extractedAppURL, version: extractedVersion, bundleIdentifier: extractedBundleIdentifier)
                return FakeProcessRunner.success
            case ("/usr/sbin/spctl", _):
                return ProcessResult(stdout: "", stderr: spctlExitCode == 0 ? "" : "rejected", exitCode: spctlExitCode)
            case ("/usr/bin/codesign", "-dv"):
                let isStaged = args.last?.contains("/Updates/") ?? false
                return ProcessResult(stdout: "", stderr: isStaged ? stagedSignature : signature, exitCode: 0)
            default:
                return FakeProcessRunner.success
            }
        }
    }
}

func makeRelease(
    _ version: String = "0.2.0",
    size: Int? = nil,
    digest: String = String(repeating: "a", count: 64),
    downloadURL: URL = URL(string: "https://example.com/Roastier.app.zip")!
) -> AppUpdateRelease {
    AppUpdateRelease(
        tagName: "v\(version)",
        version: AppUpdateVersion(string: version)!,
        htmlURL: URL(string: "https://github.com/afollestad/Roastier/releases/tag/v\(version)")!,
        asset: AppUpdateReleaseAsset(
            name: "Roastier.app.zip",
            downloadURL: downloadURL,
            size: size,
            digest: AppUpdateReleaseAssetDigest(sha256HexDigest: digest)!
        )
    )
}

func makeStagedUpdate(_ release: AppUpdateRelease) -> StagedAppUpdate {
    StagedAppUpdate(
        release: release,
        appBundleURL: URL(fileURLWithPath: "/tmp/Staged/\(release.tagName)/Roastier.app"),
        metadataURL: URL(fileURLWithPath: "/tmp/staged-update.json"),
        stagedAt: Date(timeIntervalSinceReferenceDate: 0)
    )
}

struct FakeVersionProvider: AppVersionProviding {
    var currentVersionString: String? = "0.1.0"

    var currentVersion: AppUpdateVersion? {
        currentVersionString.flatMap(AppUpdateVersion.init(string:))
    }
}

final class FakeReleaseClient: AppUpdateReleaseClient {
    private let state: Mutex<(result: AppUpdateReleaseLookupResult, callCount: Int)>
    /// When set, each lookup waits for a value before answering.
    private let gate: AsyncStream<Void>?

    init(_ result: AppUpdateReleaseLookupResult, gate: AsyncStream<Void>? = nil) {
        state = Mutex((result, 0))
        self.gate = gate
    }

    var callCount: Int {
        state.withLock { $0.callCount }
    }

    func setResult(_ result: AppUpdateReleaseLookupResult) {
        state.withLock { $0.result = result }
    }

    func latestRelease() async -> AppUpdateReleaseLookupResult {
        state.withLock { $0.callCount += 1 }
        if let gate {
            for await _ in gate {
                break
            }
        }
        return state.withLock { $0.result }
    }
}

final class FakeDownloader: AppUpdateDownloading {
    private let state = Mutex<(error: AppUpdateFailure?, downloadedTags: [String])>((nil, []))

    var downloadedTags: [String] {
        state.withLock { $0.downloadedTags }
    }

    func setError(_ error: AppUpdateFailure?) {
        state.withLock { $0.error = error }
    }

    func download(release: AppUpdateRelease, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        let error = state.withLock { state in
            state.downloadedTags.append(release.tagName)
            return state.error
        }
        await progress(0.5)
        if let error {
            throw error
        }
        return URL(fileURLWithPath: "/tmp/\(release.tagName).zip")
    }
}

final class FakeStager: AppUpdateStaging {
    private struct State {
        var locationError: AppUpdateFailure?
        var loadResult: StagedAppUpdate?
    }

    private let state = Mutex(State())

    func setLocationError(_ error: AppUpdateFailure?) {
        state.withLock { $0.locationError = error }
    }

    func setLoadResult(_ stagedUpdate: StagedAppUpdate?) {
        state.withLock { $0.loadResult = stagedUpdate }
    }

    func validateInstallLocation() throws {
        if let error = state.withLock({ $0.locationError }) {
            throw error
        }
    }

    func stageDownloadedUpdate(release: AppUpdateRelease, downloadedZIPURL: URL) async throws -> StagedAppUpdate {
        makeStagedUpdate(release)
    }

    func loadValidatedStagedUpdate() async throws -> StagedAppUpdate? {
        state.withLock { $0.loadResult }
    }
}

final class FakeInstaller: AppUpdateInstalling {
    private let state = Mutex<(error: AppUpdateFailure?, installed: [StagedAppUpdate])>((nil, []))

    var installed: [StagedAppUpdate] {
        state.withLock { $0.installed }
    }

    func setError(_ error: AppUpdateFailure?) {
        state.withLock { $0.error = error }
    }

    func installAndRelaunch(stagedUpdate: StagedAppUpdate) async throws {
        let error = state.withLock { state in
            state.installed.append(stagedUpdate)
            return state.error
        }
        if let error {
            throw error
        }
    }
}
