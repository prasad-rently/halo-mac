package app.halo.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Manifest lint (H-15 + F-055 NFR): every exported component is either protected by a permission or is on an
 * explicit allow-list with the exact intent actions it may answer. A new exported component fails this test until
 * someone writes down why it is safe — which is the point.
 */
class ManifestExportTest {
    private val ns = "http://schemas.android.com/apk/res/android"

    private fun manifest(): Element {
        val f = listOf("src/main/AndroidManifest.xml", "app/src/main/AndroidManifest.xml").map(::File).first { it.exists() }
        return DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(f).documentElement
    }

    private fun children(e: Element, tag: String) = (0 until e.childNodes.length).map { e.childNodes.item(it) }.filter { it.nodeType == Node.ELEMENT_NODE && it.nodeName == tag }.map { it as Element }

    private fun components(): List<Element> {
        val app = children(manifest(), "application").single()
        return listOf("activity", "activity-alias", "service", "receiver", "provider").flatMap { children(app, it) }
    }

    private fun actions(c: Element) = children(c, "intent-filter").flatMap { children(it, "action") }.map { it.getAttributeNS(ns, "name") }.toSet()

    /** What each *unprotected* exported component may answer. Justification beside each. */
    private val publicAllowList = mapOf(
        ".MainActivity" to setOf("android.intent.action.MAIN"),                                  // the launcher
        ".cloud.SendToMacActivity" to setOf("android.intent.action.SEND"),                       // text share target; re-checks the action in onCreate
    )

    @Test fun `every exported component is permission-protected or explicitly allow-listed with its exact actions`() {
        val problems = ArrayList<String>()
        for (c in components()) {
            val name = c.getAttributeNS(ns, "name")
            val exported = c.getAttributeNS(ns, "exported")
            if (exported.isEmpty() && children(c, "intent-filter").isNotEmpty()) problems += "$name has an intent-filter but no explicit android:exported"
            if (exported != "true") continue
            if (c.getAttributeNS(ns, "permission").isNotEmpty()) continue
            val allowed = publicAllowList[name]
            if (allowed == null) { problems += "$name is exported with no permission and is not on the allow-list"; continue }
            val extra = actions(c) - allowed
            if (extra.isNotEmpty()) problems += "$name answers $extra beyond its allow-list $allowed"
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }

    @Test fun `the text share target answers only SEND and only text`() {
        val c = components().single { it.getAttributeNS(ns, "name") == ".cloud.SendToMacActivity" }
        assertEquals(setOf("android.intent.action.SEND"), actions(c))
        val mimes = children(c, "intent-filter").flatMap { children(it, "data") }.map { it.getAttributeNS(ns, "mimeType") }
        assertEquals(listOf("text/plain"), mimes)
    }

    @Test fun `the accessibility service is permission-protected and subscribes to no event type`() {
        val svc = components().single { it.getAttributeNS(ns, "name") == ".cloud.ClipboardAccessibilityService" }
        assertEquals("android.permission.BIND_ACCESSIBILITY_SERVICE", svc.getAttributeNS(ns, "permission"))
        val res = listOf("src/main/res/xml/accessibility_service_config.xml", "app/src/main/res/xml/accessibility_service_config.xml").map(::File).first { it.exists() }
        val cfg = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(res).documentElement
        // Matches the service's own comment ("subscribes to no accessibility events") and its no-window-content promise.
        assertFalse("config must not declare accessibilityEventTypes", cfg.hasAttributeNS(ns, "accessibilityEventTypes"))
        assertEquals("false", cfg.getAttributeNS(ns, "canRetrieveWindowContent"))
    }
}
