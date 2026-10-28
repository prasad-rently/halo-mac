package app.halo.mobile

import app.halo.mobile.background.SharedUris
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedUrisTest {
    @Test fun `only content URIs from other apps are accepted`() {
        assertTrue(SharedUris.acceptable("content", "com.android.providers.media.documents"))
        assertTrue(SharedUris.acceptable("CONTENT", "media"))
    }

    @Test fun `file, resource, http and our own providers are refused - a shared file URI must not read our private storage`() {
        assertFalse(SharedUris.acceptable("file", ""))
        assertFalse(SharedUris.acceptable("file", null))
        assertFalse(SharedUris.acceptable("android.resource", "app.halo.mobile"))
        assertFalse(SharedUris.acceptable("http", "evil.example"))
        assertFalse(SharedUris.acceptable(null, "media"))
        assertFalse(SharedUris.acceptable("content", null))
        assertFalse(SharedUris.acceptable("content", "app.halo.mobile.fileprovider"))
        assertFalse(SharedUris.acceptable("content", "APP.HALO.MOBILE.x"))
    }
}
