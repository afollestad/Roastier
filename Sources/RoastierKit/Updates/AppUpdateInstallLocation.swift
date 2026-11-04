import Foundation

/// Where the running app lives, and whether an update can replace it there.
struct AppUpdateInstallLocation: @unchecked Sendable {
    let bundle: Bundle
    let fileManager: FileManager

    var runningVersion: AppUpdateVersion? {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppUpdateVersion.init(string:))
    }

    /// The running bundle's URL, once it is an app bundle outside a translocation or build folder, in a writable
    /// parent the install helper can swap it within.
    func validatedBundleURL() throws -> URL {
        let bundleURL = bundle.bundleURL.standardizedFileURL
        let path = bundleURL.path
        guard bundleURL.pathExtension == "app" else {
            throw AppUpdateFailure(message: "Roastier is not running from an app bundle.")
        }
        guard !path.contains("/AppTranslocation/") else {
            throw AppUpdateFailure(message: "Move Roastier to your Applications folder to install updates.")
        }
        guard !path.contains("/.build/"), !path.contains("/DerivedData/"), !path.contains("/Build/Products/") else {
            throw AppUpdateFailure(message: "Updates cannot be installed over a development build.")
        }
        guard fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            throw AppUpdateFailure(message: "Roastier's install location is not writable.")
        }
        return bundleURL
    }
}

extension String {
    /// Keeps letters, digits, `.`, `-`, and `_`, so a release tag can name a file or directory.
    var sanitizedForPathComponent: String {
        components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
