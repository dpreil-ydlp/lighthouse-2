import ServiceManagement
import Testing
@testable import LighthouseApp

/// M5: an installed copy that was never registered reports `.notFound`; Settings must read Off, not
/// "Unavailable".
@Suite struct LoginItemTests {
    @Test func neverRegisteredReadsOff() {
        #expect(LoginItem.text(for: .notFound) == "Off")
        #expect(LoginItem.text(for: .notRegistered) == "Off")
        #expect(LoginItem.text(for: .enabled) == "On")
        #expect(LoginItem.text(for: .requiresApproval).contains("System Settings"))
    }
}
