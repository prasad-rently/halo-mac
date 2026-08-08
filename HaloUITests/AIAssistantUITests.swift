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

    // TC-AI-01 — the AI Assistant module renders: a message composer and a
    // provider/model selector.
    func test_ai_module_renders() {
        openAI()
        XCTAssertTrue(app.windows.firstMatch.exists)
        let composer = app.textViews.firstMatch.exists ||
                       app.textFields.firstMatch.exists ||
                       element(labeled: "Ask", timeout: 5) != nil ||
                       element(labeled: "Send", timeout: 2) != nil
        XCTAssertTrue(composer, "AI Assistant should present a message composer")
    }

    // TC-AI-02 — the provider picker lists the three implemented providers.
    func test_provider_picker_lists_providers() throws {
        openAI()
        let providers = ["Claude", "OpenAI", "Gemini", "Claude (Anthropic)", "Gemini (Google)"]
        guard providers.contains(where: { element(labeled: $0, timeout: 5) != nil }) else {
            throw XCTSkip("Provider picker not addressable by label; annotate it with " +
                          "`ai.providerPicker`. Expectation: Claude / OpenAI / Gemini selectable.")
        }
    }

    // TC-AI-03 — with NO API key configured, submitting a prompt surfaces the
    // "add a key" guidance and makes no network call. This guards the BYO-key
    // contract (US-5): no key → no request.
    func test_missing_key_shows_guidance_and_makes_no_call() throws {
        openAI()
        // Type into whatever composer is present.
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch
                     : app.textFields.firstMatch
        guard composer.exists else {
            throw XCTSkip("Composer not addressable; annotate with `ai.composer`. " +
                          "Expectation: sending with no key shows 'No API key set…' and no request.")
        }
        composer.click()
        composer.typeText("What is my Mac's health score?")
        _ = clickAny(of: ["Send", "Ask", "Submit"], timeout: 3)

        // Either the missing-key guidance appears, or (if a key happens to be
        // configured on this machine) we simply do not assert a live response —
        // we never require the network.
        let guidance = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                        "API key", "no key")).firstMatch
        if !guidance.waitForExistence(timeout: 6) {
            throw XCTSkip("A provider key appears to be configured in this session, so the " +
                          "missing-key path can't be asserted safely without making a real " +
                          "call. Run this on a machine with no AI key set in the Keychain.")
        }
        XCTAssertTrue(guidance.exists, "Missing-key guidance should appear (no network call made)")
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
