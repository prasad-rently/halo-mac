package app.halo.photos

import app.halo.photos.PhotoPermissions as P
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class PhotoAccessTest {
    @Test fun `permission requested per API level`() {
        assertEquals(listOf(P.READ_EXTERNAL_STORAGE), P.toRequest(32))
        assertEquals(listOf(P.READ_MEDIA_IMAGES), P.toRequest(33))
        assertEquals(listOf(P.READ_MEDIA_IMAGES, P.READ_MEDIA_VISUAL_USER_SELECTED), P.toRequest(34))
    }

    @Test fun `android 14 partial access is distinguished from full and none`() {
        assertEquals(MediaAccess.FULL, P.resolve(34, setOf(P.READ_MEDIA_IMAGES, P.READ_MEDIA_VISUAL_USER_SELECTED)))
        assertEquals(MediaAccess.PARTIAL, P.resolve(34, setOf(P.READ_MEDIA_VISUAL_USER_SELECTED)))
        assertEquals(MediaAccess.NONE, P.resolve(34, emptySet()))
    }

    @Test fun `visual-user-selected means nothing before android 14 and read-storage means nothing on 13`() {
        assertEquals(MediaAccess.NONE, P.resolve(33, setOf(P.READ_MEDIA_VISUAL_USER_SELECTED)))
        assertEquals(MediaAccess.NONE, P.resolve(33, setOf(P.READ_EXTERNAL_STORAGE)))
        assertEquals(MediaAccess.FULL, P.resolve(30, setOf(P.READ_EXTERNAL_STORAGE)))
        assertEquals(MediaAccess.NONE, P.resolve(30, setOf(P.READ_MEDIA_IMAGES)))
    }

    @Test fun `delete is only offered where a recoverable trash request exists`() {
        assertEquals(DeleteMode.DISABLED_BEFORE_API_30, P.deleteMode(29))
        assertNotNull(P.deleteExplanation(29))
        assertEquals(DeleteMode.TRASH_REQUEST, P.deleteMode(30))
        assertNull(P.deleteExplanation(30))
    }
}
