package app.halo.mobile.design

/**
 * UI copy for the restyled screens, in one place (no English strings scattered through views). Rules: titles <= 3 words,
 * subtitles one short line; anything longer is a [HaloInfo] body shown in a bottom sheet. Honest limits are moved, never deleted.
 */
object HaloCopy {
    // Navigation
    const val TAB_HOME = "Home"; const val TAB_MESSAGES = "Messages"; const val TAB_CLIPBOARD = "Clipboard"; const val TAB_SHARE = "Share"; const val TAB_SETTINGS = "Settings"

    // Home
    const val HOME_TITLE = "Halo"
    const val QUICK_ACTIONS = "Quick actions"; const val RECENT = "Recent activity"; const val MORE = "More"
    const val QA_SEND_CLIPBOARD = "Send clipboard"; const val QA_SEND_FILE = "Send file"; const val QA_SCAN = "Scan nearby"; const val QA_CHECK = "Check sync"
    const val TILE_MESSAGES = "Messages today"; const val TILE_CLIPBOARD = "Clipboard items"; const val TILE_NEARBY = "Nearby devices"; const val TILE_LAST_SYNC = "Last sync"
    const val NO_ACTIVITY = "Nothing yet"; const val NO_ACTIVITY_SUB = "Sync or send something and it shows up here."
    const val CONNECT_TO_MAC = "Connect to Mac"

    // Messages
    const val MESSAGES_TITLE = "Messages"; const val SYNC_TO_MAC = "Sync to Mac"; const val SYNC_NOW = "Sync now"; const val OLDER_HISTORY = "Older history"
    const val RETRY_SKIPPED = "Retry skipped"; const val ALL_LINES = "All"; const val SIM_LINES = "SIM lines"; const val WHO_TO_SYNC = "Who to sync"
    const val NO_MESSAGES = "No messages"; const val NO_MESSAGES_SUB = "Your inbox is empty."; const val ALLOW_SMS = "Allow SMS access"
    const val NEEDS_PERMISSION = "Needs permission"

    // Clipboard
    const val CLIPBOARD_TITLE = "Clipboard"; const val SEND_CURRENT = "Send current clipboard"; const val SYNC_CLIPBOARD = "Sync clipboard"
    const val HISTORY = "History"; const val NOTHING_SYNCED = "Nothing synced"; const val NOTHING_SYNCED_SUB = "Copies you send or receive appear here."
    const val AUTO_CAPTURE = "Automatic capture"; const val KEEP_SECRETS = "Keep secrets off cloud"

    // Share
    const val SHARE_TITLE = "Share"; const val NEARBY = "Nearby devices"; const val CHOOSE_FILES = "Choose files"; const val RECEIVED = "Received"
    const val NO_DEVICES = "No devices yet"; const val NO_DEVICES_SUB = "Open Halo on another device on this Wi-Fi."; const val SCAN = "Scan"
    const val NOTHING_RECEIVED = "Nothing received"; const val ADD_BY_ADDRESS = "Add by address"

    // Settings
    const val SETTINGS_TITLE = "Settings"

    // Info sheets (the long explanations that used to sit on the main surface)
    val INFO_SMS_PERMISSION = HaloInfo("Why SMS access?",
        "Halo reads your inbox so your Mac can show it, and is told when a message arrives so it appears promptly. Your phone's phone-number permission is only used to name your SIM lines.",
        listOf("Nothing is sent unencrypted, and you can turn this off at any time."))
    val INFO_SMS_SYNC = HaloInfo("About message sync",
        "Inbox only, encrypted on this phone before upload. The first sync covers the last 90 days; \"Older history\" goes back a year.",
        listOf("Messages you delete on this phone are removed from the cloud too."))
    val INFO_FILTERS = HaloInfo("Sender filters",
        "Numbers or sender names, separated by commas. \"Only these senders\" limits what syncs; \"Never these senders\" always wins over it.")
    val INFO_NO_SIM_NAMES = HaloInfo("SIM names",
        "Allow phone access to see each SIM's name and number. Until then everything syncs as one line.")
    val INFO_CLIPBOARD_SYNC = HaloInfo("About clipboard sync",
        "Text and links. What you copy on your Mac shows up in History - it never replaces what you're about to paste.",
        listOf("You can also share text from any app to \"Send to Mac (Halo)\". That works on every Android version."))
    val INFO_AUTOMATIC_CAPTURE = HaloInfo("Automatic capture",
        "Android only lets an app read the clipboard in the background through an accessibility service, so to sync automatically turn Halo on in Accessibility settings.",
        listOf("Halo does not read your screen or what you type."))
    val INFO_SECRETS = HaloInfo("Keep secrets off cloud", "Off by default. When on, copies that look like passwords or keys are not sent.")
    val INFO_BACKGROUND = HaloInfo("Background receiving",
        "Off by default. Lets Halo receive files and your Mac's clipboard when the app is closed.",
        listOf("Battery: Halo keeps a connection open while this is on, which costs some battery, and Android's battery saver or your phone maker's app-killer may still stop it. Stop it any time from the notification."))
    val INFO_NOTIFICATION_GATE = HaloInfo("Why notifications?",
        "Halo must show a notification while it listens, so you can see it is on and stop it. Turn notifications on for Halo, then switch background receiving on again.")
    val INFO_DISCONNECT = HaloInfo("About disconnecting", "Forgets the connection and the key on this phone. Your messages and cloud data are not deleted.")
    val INFO_RECEIVING = HaloInfo("Receiving files", "Nothing is saved until you accept. Files never overwrite each other.")
    val INFO_TRANSPORT = HaloInfo("About HaloShare", "Protocol: LocalSend v2 over HTTP.",
        listOf("Transfers stay on your Wi-Fi and are not encrypted in transit. Only accept files from people you trust."))
    val INFO_ADDRESS = HaloInfo("Add by address", "For networks that block discovery. Use the address shown on the other device.")
    val INFO_PAIRING = HaloInfo("About pairing",
        "On your Mac: Messages, the gear, Pair a phone, Show pairing code. The code contains your sign-in, not your passphrase.",
        listOf("The passphrase is the one you set on your Mac. It is never sent anywhere and is not stored on this phone - only the key derived from it is, sealed in the Android Keystore."))
    val INFO_PROFILE_UNAVAILABLE = HaloInfo("Secure storage",
        "Android's secure storage isn't answering right now. Your pairing is safe and nothing was changed; Halo tries again whenever you open this screen.")
    val INFO_KEY_LOST = HaloInfo("Lost key",
        "The secure key that protected it was lost (this can happen after a system reset of the phone's key store). The connection can't be recovered; pair again with a new code from your Mac. Nothing in your cloud data is deleted.")
    val INFO_OTP = HaloInfo("One-time codes", "Halo spots codes in your messages. Copying one does not send it to your Mac.")
}
