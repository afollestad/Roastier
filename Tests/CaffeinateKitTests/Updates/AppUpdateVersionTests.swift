import Testing
@testable import CaffeinateKit

struct AppUpdateVersionTests {
    @Test(arguments: ["1.2.3", "v1.2.3", "V1.2.3", " v1.2.3\n"])
    func parsesPlainAndPrefixedVersions(_ string: String) {
        let version = AppUpdateVersion(string: string)
        #expect(version?.description == "1.2.3")
    }

    @Test(arguments: ["1.2", "1.2.3.4", "1.2.3-beta", "-1.0.0", "v", "", "nightly"])
    func rejectsMalformedVersions(_ string: String) {
        #expect(AppUpdateVersion(string: string) == nil)
    }

    @Test
    func comparesNumericallyByComponent() throws {
        let older = try #require(AppUpdateVersion(string: "0.9.9"))
        let newer = try #require(AppUpdateVersion(string: "0.10.0"))
        #expect(older < newer)
        #expect(try #require(AppUpdateVersion(string: "1.0.0")) > newer)
    }
}
