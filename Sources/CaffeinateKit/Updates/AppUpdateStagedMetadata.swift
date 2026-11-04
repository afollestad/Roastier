import Foundation

/// The on-disk record of a staged update, so a relaunch can offer it without downloading again.
struct AppUpdateStagedMetadata: Codable {
    let tagName: String
    let version: String
    let htmlURL: URL
    let assetName: String
    let assetDownloadURL: URL
    let assetSize: Int?
    let assetDigest: String
    let appBundleURL: URL
    let stagedAt: Date

    init(stagedUpdate: StagedAppUpdate) {
        let release = stagedUpdate.release
        tagName = release.tagName
        version = release.version.description
        htmlURL = release.htmlURL
        assetName = release.asset.name
        assetDownloadURL = release.asset.downloadURL
        assetSize = release.asset.size
        assetDigest = release.asset.digest.gitHubDigest
        appBundleURL = stagedUpdate.appBundleURL
        stagedAt = stagedUpdate.stagedAt
    }

    func stagedUpdate(metadataURL: URL) throws -> StagedAppUpdate {
        guard let parsedVersion = AppUpdateVersion(string: version) else {
            throw AppUpdateFailure(message: "The staged update metadata has an invalid version.")
        }
        guard let parsedDigest = AppUpdateReleaseAssetDigest(gitHubDigest: assetDigest) else {
            throw AppUpdateFailure(message: "The staged update metadata has an invalid asset digest.")
        }
        return StagedAppUpdate(
            release: AppUpdateRelease(
                tagName: tagName,
                version: parsedVersion,
                htmlURL: htmlURL,
                asset: AppUpdateReleaseAsset(
                    name: assetName,
                    downloadURL: assetDownloadURL,
                    size: assetSize,
                    digest: parsedDigest
                )
            ),
            appBundleURL: appBundleURL,
            metadataURL: metadataURL,
            stagedAt: stagedAt
        )
    }
}

extension JSONEncoder {
    static var appUpdateMetadata: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var appUpdateMetadata: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
