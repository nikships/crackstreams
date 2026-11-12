import XCTest

/// Keeps the Sparkle settings in Info.plist and the sandbox entitlements in step. A mismatch
/// only shows up when a signed, sandboxed release tries to install an update.
final class ReleaseConfigurationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testSandboxedSparkleCanReachItsInstaller() throws {
        let info = try plist("Info.plist")
        let entitlements = try plist("Config/Entitlements.plist")
        let bundleID = try XCTUnwrap(info["CFBundleIdentifier"] as? String)

        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(info["SUEnableInstallerLauncherService"] as? Bool, true)
        XCTAssertEqual(
            entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String],
            ["\(bundleID)-spks", "\(bundleID)-spki"]
        )
        // The Downloader service is only for sandboxed apps without outgoing network access.
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
        XCTAssertNil(info["SUEnableDownloaderService"])
    }

    func testFeedAndKeyAreConfigured() throws {
        let info = try plist("Info.plist")
        let feed = try XCTUnwrap((info["SUFeedURL"] as? String).flatMap(URL.init(string:)))
        XCTAssertEqual(feed.scheme, "https")
        XCTAssertEqual(feed.lastPathComponent, "appcast.xml")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)

        let appcast = try String(contentsOf: root.appendingPathComponent("appcast.xml"), encoding: .utf8)
        XCTAssertTrue(appcast.contains("<language>en</language>"), "Scripts/update-appcast.sh inserts after this tag")
    }
}
