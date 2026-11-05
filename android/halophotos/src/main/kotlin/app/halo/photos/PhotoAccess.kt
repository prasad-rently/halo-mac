package app.halo.photos

/** What Halo may see of the photo library right now. Pure so every Android version's rules are unit-testable. */
enum class MediaAccess { FULL, PARTIAL, NONE }

enum class DeleteMode {
    /** API 30+: MediaStore.createTrashRequest -> system dialog -> photos move to the gallery's Trash (recoverable). */
    TRASH_REQUEST,
    /** API < 30: the only way to delete another app's media is a silent/permanent call. Halo refuses; review still works. */
    DISABLED_BEFORE_API_30,
}

object PhotoPermissions {
    const val READ_MEDIA_IMAGES = "android.permission.READ_MEDIA_IMAGES"                         // API 33+
    const val READ_MEDIA_VISUAL_USER_SELECTED = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED" // API 34+
    const val READ_EXTERNAL_STORAGE = "android.permission.READ_EXTERNAL_STORAGE"                 // API <= 32

    /** The permission set to ask for in ONE request. On 34+ both are requested together so the system can offer "Select photos". */
    fun toRequest(sdk: Int): List<String> = when {
        sdk >= 34 -> listOf(READ_MEDIA_IMAGES, READ_MEDIA_VISUAL_USER_SELECTED)
        sdk >= 33 -> listOf(READ_MEDIA_IMAGES)
        else -> listOf(READ_EXTERNAL_STORAGE)
    }

    fun resolve(sdk: Int, granted: Set<String>): MediaAccess = when {
        sdk >= 33 && READ_MEDIA_IMAGES in granted -> MediaAccess.FULL
        sdk >= 34 && READ_MEDIA_VISUAL_USER_SELECTED in granted -> MediaAccess.PARTIAL
        sdk < 33 && READ_EXTERNAL_STORAGE in granted -> MediaAccess.FULL
        else -> MediaAccess.NONE
    }

    fun deleteMode(sdk: Int): DeleteMode = if (sdk >= 30) DeleteMode.TRASH_REQUEST else DeleteMode.DISABLED_BEFORE_API_30

    fun deleteExplanation(sdk: Int): String? =
        if (deleteMode(sdk) == DeleteMode.TRASH_REQUEST) null
        else "On Android ${if (sdk >= 29) "10" else if (sdk >= 28) "9" else "8"} the system has no way to move another app's photos to a recoverable Trash, " +
            "and Halo will not delete them permanently without that safety net. Review the groups here, then remove the photos in your Gallery app."
}
