import Testing
@testable import LighthouseApp

/// M2-04 round 2 (SPEC 2.5 §5.5): every local-token figure is labelled approximate, including the
/// VoiceOver label of each provider-page project row.
@Suite struct TokenWordingTests {
    @Test func everyFigureSaysApproximate() {
        #expect(TokenWording.projectAccessibility(name: "alpha", tokens: 412_300) == "alpha, approximately 412,300 local tokens this window, not quota share")
        #expect(TokenWording.projectHelp(tokens: 412_300).hasPrefix("Approximately 412,300 local tokens"))
        #expect(TokenWording.projectFigure(tokens: 412_300) == "≈ 412.3 K")
        let detail = TokenWording.threadDetail(window: 1234, session: 98000, partial: true)
        #expect(detail.hasPrefix("approximately 1,234 this window"))
        #expect(detail.contains("partial") && detail.contains("not quota share"))
    }
}
