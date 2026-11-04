import Foundation

struct ProcessResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool {
        exitCode == 0
    }
}

/// Runs short-lived system tools (`ditto`, `codesign`, `spctl`); the seam that keeps tests off real binaries.
protocol ProcessRunning: Sendable {
    func run(executable: String, args: [String], timeout: Duration) async throws -> ProcessResult
}

struct ProcessRunner: ProcessRunning {
    func run(executable: String, args: [String], timeout: Duration) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            termination.continuation.yield(finished.terminationStatus)
            termination.continuation.finish()
        }
        try process.run()

        // Drain both pipes while the tool runs; a full pipe buffer would otherwise block it forever.
        async let stdoutData = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = Self.readToEnd(stderrPipe.fileHandleForReading)
        let handle = RunningProcess(process)
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            handle.terminate()
            return true
        }

        let exitCode = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await terminationStatus in termination.stream {
                status = terminationStatus
            }
            return status
        } onCancel: {
            handle.terminate()
        }
        timeoutTask.cancel()
        let (stdout, stderr) = await (stdoutData, stderrData)

        if await timeoutTask.value {
            throw AppUpdateFailure(message: "\(executable) timed out.")
        }
        try Task.checkCancellation()
        return ProcessResult(
            stdout: String(bytes: stdout, encoding: .utf8) ?? "",
            stderr: String(bytes: stderr, encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }

    private static func readToEnd(_ fileHandle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            // Blocking reads stay off Swift concurrency's cooperative pool.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? fileHandle.readToEnd()) ?? Data())
            }
        }
    }
}

/// Lets the timeout and cancellation paths signal a `Process`, which is not `Sendable`.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}
