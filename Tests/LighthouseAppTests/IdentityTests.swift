import Foundation
import Testing
@testable import LighthouseApp

/// P1 (A1, A2): the app shows the name "Lighthouse 2" and version 0.0.6; the bundle file and id stay
/// `com.lighthouse.v2`, and the bundle file is `Lighthouse 2.app` (amendment); the release zip is `Lighthouse-2-<version>.zip`.
@Suite struct IdentityTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("App/Lighthouse/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func nameAndVersionLine() {
        #expect(AppIdentity.name == "Lighthouse 2")
        let line = AppIdentity.versionLine(info: ["CFBundleShortVersionString": "0.0.2", "CFBundleVersion": "6"])
        #expect(line == "Lighthouse 2 0.0.2 (6)")
        #expect(AppIdentity.versionLine(info: nil) == "Lighthouse 2 unknown (?)")
    }

    @Test func infoPlistCarriesNameAndVersion() throws {
        let info = try Self.plist()
        #expect(info["CFBundleDisplayName"] as? String == "Lighthouse 2")
        #expect(info["CFBundleShortVersionString"] as? String == "0.0.6")
        #expect(info["CFBundleVersion"] as? String == "10")
        // The bundle name and id come from build settings.
        #expect(info["CFBundleName"] as? String == "$(PRODUCT_NAME)")
        #expect(info["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }

    @Test func xcodeSpecAndPackagerAgree() throws {
        let yml = try String(contentsOf: Self.root.appendingPathComponent("App/project.yml"), encoding: .utf8)
        #expect(yml.contains("CFBundleDisplayName: \"Lighthouse 2\""))
        #expect(yml.contains("CFBundleShortVersionString: \"0.0.6\""))
        #expect(yml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.lighthouse.v2"))
        #expect(yml.contains("PRODUCT_NAME: \"Lighthouse 2\"\n"))
        let package = try String(contentsOf: Self.root.appendingPathComponent("scripts/package.sh"), encoding: .utf8)
        #expect(package.contains("ZIP=\"$DIST/Lighthouse-2-$VERSION.zip\""))
        #expect(package.contains("APP=\"$STAGE/Lighthouse 2.app\""))
        #expect(package.contains("s/$(PRODUCT_NAME)/Lighthouse 2/"))
        #expect(package.contains("--identifier com.lighthouse.v2"))
    }
}
