//
//  AIAssistantUITests.swift
//  HaloUITests
//
//  AI Assistant (F-046 — cloud providers, BYO key). Extends the manual plan
//  with a new section; test IDs TC-AI-01… (add these to MANUAL_TEST_PLAN.md
//  §16.x when the plan is refreshed for F-046).
//
//  CRITICAL: these tests must NOT make real network calls or require an API
//  key. With no key configured the assistant surfaces a "missing key" state
//  (AIProviderError.missingKey / AIKeyStore.hasKey == false). We assert the UI
//  and that state — never a live completion.
//

import XCTest

final class AIAssistantUITests: HaloUITestCase {

    private func openAI() {
        XCTAssertTrue(HaloSidebar(test: self).navigate(to: .ai),
                      "AI Assistant sidebar module should open")
    }

    // TC-AI-01 — the AI Assistant module renders with its provider selector.
    // (The composer only appears once a key is configured; the provider picker
    // is always present, so it's the stable render signal.)
    func test_ai_module_renders() {
        openAI()
        XCTAssertTrue(app.windows.firstMatch.exists)
        assertID("ai.providerPicker", "AI Assistant should present a provider selector")
    }

    // TC-AI-02 — the provider picker is present and interactive.
    func test_provider_picker_present() {
        openAI()
        let picker = assertID("ai.providerPicker")
        XCTAssertTrue(picker.isHittable, "Provider picker should be interactive")
    }

    // TC-AI-03 — with NO API key configured, the assistant shows the BYO-key
    // setup guidance ("Connect your … API key") and NO composer — proving the
    // no-key path makes no network call (US-5). If a key is already configured
    // on this machine we can't assert the no-key path without a real call, so we
    // skip rather than hit the network.
    func test_no_key_shows_setup_guidance_and_no_composer() throws {
        openAI()
        let keySetup = waitForID("ai.keySetup.title", timeout: 6)
        guard keySetup != nil else {
            throw XCTSkip("A provider key appears to be configured in this session (the key " +
                          "setup screen isn't shown). Run on a machine with no AI key in the " +
                          "Keychain to assert the no-key/no-network path.")
        }
        // No composer must be present without a key — nothing can be sent.
        XCTAssertFalse(element(id: "ai.composer").exists,
                       "Composer must not appear until a key is configured (no key → no request)")
    }

    // TC-AI-04 — the ⌘⇧I quick-ask overlay is documented. Global hotkeys and
    // floating NSPanels are not reliably drivable from the app's a11y tree in a
    // sandboxed test host, so this stays a documented expectation.
    func test_quick_ask_overlay_shortcut() throws {
        throw XCTSkip("⌘⇧I opens a floating quick-ask NSPanel via a global NSEvent monitor, " +
                      "which requires Accessibility permission and is out of XCUITest's reach. " +
                      "Expectation: pressing ⌘⇧I toggles the quick-ask overlay; second press dismisses.")
    }

    // TC-AI-05 / TC-SAFE-02 — an assistant "act" tool (e.g. Run Smart Scan,
    // Export Report) must be confirmation-gated; read tools auto-run. This is
    // enforced in AgentRunner (unit-tested in AIAssistantTests). Documented here
    // as the E2E expectation for when a live key is available in CI.
    func test_act_tools_are_confirmation_gated() throws {
        throw XCTSkip("Requires a live API key + a model that calls an `.act` tool. " +
                      "Expectation: read tools (get_health_score, get_cpu_usage, …) run " +
                      "automatically; act tools (run_smart_scan, export_health_report) prompt " +
                      "for confirmation before executing (ToolRegistry.actToolNames).")
    }
}
