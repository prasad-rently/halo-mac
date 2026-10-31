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

    @Test fun `a user-id prefix cannot smuggle our own provider past the check, and the telephony providers are refused`() {
        // content://<userId>@<authority>/… addresses the same provider, so the authority must be judged after the '@'
        assertFalse(SharedUris.acceptable("content", "0@app.halo.mobile.fileprovider"))
        assertFalse(SharedUris.acceptable("content", "evil@app.halo.mobile.fileprovider"))
        assertFalse(SharedUris.acceptable("content", "a@b@app.halo.mobile"))
        assertFalse(SharedUris.acceptable("content", "10@"))
        // Halo holds READ_SMS; a hostile sharer must not be able to name those providers
        for (a in listOf("sms", "mms", "mms-sms", "SMS", "0@sms", "telephony")) assertFalse(a, SharedUris.acceptable("content", a))
        assertTrue(SharedUris.acceptable("content", "10@com.android.providers.media.documents"))     // legitimate cross-user form
    }
}
