import Foundation

/// Writes a data task's body straight to disk and reports progress, so a download never sits in memory or a cache.
final class AppUpdateDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let expectedSize: Int?
    private let progress: @Sendable (Double) async -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, any Error>?
    private var storedError: (any Error)?
    private var fileHandle: FileHandle?
    private var receivedByteCount: Int64 = 0
    private var responseExpectedByteCount: Int64 = 0
    private var didCreateDownloadedFile = false
    private var didResume = false
    private var lastReportedProgress = 0.0
    private var progressReports: [Task<Void, Never>] = []

    init(destinationURL: URL, expectedSize: Int?, progress: @escaping @Sendable (Double) async -> Void) {
        self.destinationURL = destinationURL
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func download(with task: URLSessionDataTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            task.resume()
        }
    }

    func waitForProgressReports() async {
        let reports = lock.withLock {
            progressReports
        }
        for report in reports {
            await report.value
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let error = Self.httpError(from: response) {
            lock.withLock {
                storedError = error
            }
            completionHandler(.cancel)
            return
        }

        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw AppUpdateFailure(message: "Caffeinate could not create the update download file.")
            }
            let handle = try FileHandle(forWritingTo: destinationURL)
            lock.withLock {
                fileHandle = handle
                responseExpectedByteCount = response.expectedContentLength
                didCreateDownloadedFile = true
            }
            completionHandler(.allow)
        } catch {
            lock.withLock {
                storedError = error
            }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let progressValue: Double?
        do {
            progressValue = try lock.withLock {
                guard let fileHandle else {
                    throw AppUpdateFailure(message: "Caffeinate could not write the update download.")
                }
                try fileHandle.write(contentsOf: data)
                receivedByteCount += Int64(data.count)
                let expectedByteCount = expectedDownloadByteCount()
                guard expectedByteCount > 0 else {
                    return nil
                }
                return min(max(Double(receivedByteCount) / Double(expectedByteCount), 0), 1)
            }
        } catch {
            lock.withLock {
                storedError = error
            }
            dataTask.cancel()
            return
        }

        if let progressValue {
            reportProgressIfNeeded(progressValue)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // GitHub redirects release downloads to its asset CDN; the new request drops the original's cache controls.
        var redirectedRequest = request
        redirectedRequest.cachePolicy = .reloadIgnoringLocalCacheData
        redirectedRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        redirectedRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        completionHandler(redirectedRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        closeFileHandle()
        let state = lock.withLock {
            (storedError: storedError, didCreateDownloadedFile: didCreateDownloadedFile)
        }
        let completionError = state.storedError ?? Self.normalizedCompletionError(error) ?? Self.httpError(from: task.response)
        if let completionError {
            try? FileManager.default.removeItem(at: destinationURL)
            resume(with: .failure(completionError))
        } else if !state.didCreateDownloadedFile {
            resume(with: .failure(AppUpdateFailure(message: "GitHub did not return the update asset.")))
        } else {
            resume(with: .success(()))
        }
    }
}

private extension AppUpdateDownloadDelegate {
    func expectedDownloadByteCount() -> Int64 {
        if let expectedSize, expectedSize > 0 {
            return Int64(expectedSize)
        }
        return max(responseExpectedByteCount, 0)
    }

    func reportProgressIfNeeded(_ progressValue: Double) {
        lock.withLock {
            guard progressValue >= 1 || progressValue - lastReportedProgress >= 0.01 else {
                return
            }
            lastReportedProgress = progressValue
            let progress = progress
            progressReports.append(Task {
                await progress(progressValue)
            })
        }
    }

    func closeFileHandle() {
        let handle = lock.withLock {
            defer {
                fileHandle = nil
            }
            return fileHandle
        }
        try? handle?.close()
    }

    func resume(with result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard !didResume, let continuation else {
                return nil
            }
            didResume = true
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    static func httpError(from response: URLResponse?) -> (any Error)? {
        guard let response = response as? HTTPURLResponse,
              !(200..<300).contains(response.statusCode) else {
            return nil
        }
        return AppUpdateFailure(message: "GitHub failed to download the update. (HTTP \(response.statusCode))")
    }

    static func normalizedCompletionError(_ error: (any Error)?) -> (any Error)? {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return error
    }
}
