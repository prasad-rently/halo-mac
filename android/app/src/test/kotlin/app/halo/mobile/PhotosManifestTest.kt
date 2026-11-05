package app.halo.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** F-025: Similar Photos adds media-READ permissions and nothing else in the storage/media family. */
class PhotosManifestTest {
    private val ns = "http://schemas.android.com/apk/res/android"

    private fun permissions(): Map<String, String?> {
        val f = listOf("src/main/AndroidManifest.xml", "app/src/main/AndroidManifest.xml").map(::File).first { it.exists() }
        val root = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(f).documentElement
        val nodes = root.getElementsByTagName("uses-permission")
        return (0 until nodes.length).map { nodes.item(it) as Element }.associate { it.getAttributeNS(ns, "name") to it.getAttributeNS(ns, "maxSdkVersion").ifEmpty { null } }
    }

    @Test fun `media and storage permissions are exactly the three read permissions`() {
        val family = permissions().filterKeys { it.contains("MEDIA") || it.contains("STORAGE") }
        assertEquals(
            mapOf(
                "android.permission.READ_MEDIA_IMAGES" to null,
                "android.permission.READ_MEDIA_VISUAL_USER_SELECTED" to null,
                "android.permission.READ_EXTERNAL_STORAGE" to "32",     // legacy read only up to API 32; 33+ uses READ_MEDIA_IMAGES
            ), family,
        )
    }

    @Test fun `no write, manage-all-files, location-metadata, video or audio access`() {
        val p = permissions().keys
        listOf("WRITE_EXTERNAL_STORAGE", "MANAGE_EXTERNAL_STORAGE", "ACCESS_MEDIA_LOCATION", "READ_MEDIA_VIDEO", "READ_MEDIA_AUDIO", "REQUEST_DELETE_PACKAGES")
            .forEach { assertTrue("$it must not be declared", "android.permission.$it" !in p) }
    }
}
