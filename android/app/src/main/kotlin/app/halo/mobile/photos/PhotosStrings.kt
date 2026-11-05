package app.halo.mobile.photos

/** All user-visible copy for Similar Photos in one place (design directive: no strings scattered through views). */
internal object PhotosStrings {
    const val TITLE = "Similar Photos"
    const val SCAN = "Scan photos"
    const val RESCAN = "Scan again"
    const val CANCEL = "Cancel scan"
    const val ALLOW = "Allow access"
    const val SETTINGS = "Open settings"
    const val EMPTY_NO_ACCESS = "Photo access needed"
    const val EMPTY_IDLE = "Find look-alike photos"
    const val EMPTY_NONE_FOUND = "No look-alikes found"
    const val REVIEW = "Review & delete"
    const val BEST = "Best"
    const val PARTIAL_CHIP = "Selected photos only"
    const val MORE = "Choose more"
    const val DELETE_UNAVAILABLE = "Delete needs Android 11+"
    const val TILE_GROUPS = "Groups"
    const val TILE_FREE = "Reclaimable"
    const val TILE_SCANNED = "Scanned"
    const val STRICT = "Strict"; const val NORMAL = "Normal"; const val LOOSE = "Loose"
    const val INFO = "About Similar Photos"
    fun chained(diameter: Int) = "Loosely linked: some photos here differ by up to $diameter of 64 bits. Nothing is pre-selected; check each photo."

    val INFO_LINES = listOf(
        "Halo compares small previews on this phone to find photos that look alike. Nothing is uploaded and no hash is stored.",
        "Strict matches near-identical shots; Loose also catches similar ones, with more false matches. The slider sets the exact number of differing bits (1-20 of 64).",
        "Best is the highest-resolution, newest photo in each group. At least one photo per group always stays.",
        "Review & delete shows the count and total size first, then Android asks you to confirm. Photos go to your Gallery's Trash and can be restored.",
        "If you allowed selected photos only, just those are compared.",
        "On Android 10 and older, Halo can't move photos to Trash safely, so deletion is turned off; review groups here and remove them in your Gallery.",
    )
}
