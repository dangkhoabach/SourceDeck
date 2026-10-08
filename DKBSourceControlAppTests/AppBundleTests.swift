import Foundation
import Testing
@testable import DKB_Source_Control

/// The test host is the app itself, so `Bundle.main` is the built app.
@Suite struct AppBundleTests {
    /// Without these keys macOS doesn't ask for access to a repository in a
    /// protected folder — git just fails with "Operation not permitted"
    /// (PoC 0.5: the prompt appears once, the grant survives rebuilds).
    @Test func protectedFolderUsageDescriptionsArePresent() {
        for key in ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription"] {
            let text = Bundle.main.object(forInfoDictionaryKey: key) as? String
            #expect(text?.isEmpty == false, "\(key) missing")
        }
    }

    @Test func versionIsTheSameInBothFields() {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String
        #expect(short?.split(separator: ".").count == 3)
        #expect(short == info["CFBundleVersion"] as? String)
    }

    @Test func debugBuildsUseTheirOwnDatabaseInTheBundleFolder() {
        let url = AppDatabaseLocation.productionPath()
        #expect(url.lastPathComponent == "dkb-source-control-debug.db")
        #expect(url.deletingLastPathComponent().lastPathComponent == "com.dangkhoabach.dkb-source-control")
    }
}
