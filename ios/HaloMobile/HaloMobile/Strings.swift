import Foundation

/// All user-visible copy for the screens in this target lives here, grouped per area, so views carry
/// no scattered English literals and a future localisation pass has one place to start.
/// Add your own nested enum for new features instead of editing another area's.
enum HaloStrings {
    enum Tab {
        static let home = "Home"
        static let share = "Share"
        static let settings = "Settings"
    }

    enum Home {
        static let title = "Halo"
        static let nearby = "Nearby"
        static let nearbyUnit = "devices"
        static let nearbyUnitOne = "device"
        static let received = "Received"
        static let receivedUnit = "files"
        static let receivedUnitOne = "file"
        static let messagesToday = "Messages today"
        static let clipboardItems = "Clipboard items"
        static let quickActions = "Quick actions"
        static let recentActivity = "Recent activity"
        static let noActivity = "No activity yet"
        static let noActivityHint = "Scan for a device to send your first file."
        static let scanNearby = "Scan nearby"
        static let chooseFiles = "Send file"
        static let openInbox = "Received"
        static let setupCloudTitle = "Set up cloud"
        static let setupCloudSubtitle = "Messages and clipboard with your Mac"
        static let setupCloudAction = "Open Settings"
        static let shareService = "HaloShare"
        static let cloudService = "Cloud"
        static let ringReady = "Ready"
        static let ringStarting = "Starting"
        static let ringOffline = "Offline"
        static let ringSynced = "Synced"
        static let ringProblem = "Problem"
        static let lastTransfer = "Last transfer"
    }

    enum Share {
        static let title = "Share"
        static let thisDevice = "This device"
        static let nearbyDevices = "Nearby devices"
        static let scan = "Scan"
        static let stop = "Stop"
        static let scanning = "Scanning Wi-Fi…"
        static let noDevices = "No devices yet"
        static let noDevicesHint = "Open HaloShare or LocalSend on the same Wi-Fi."
        static let addByAddress = "Add by address"
        static let addTile = "Add"
        static let chooseFiles = "Choose files"
        static let chooseDeviceFirst = "Pick a device first"
        static let sendTo = "Send to"
        static let sending = "Sending"
        static let cancel = "Cancel"
        static let received = "Received"
        static let seeAll = "See all"
        static let nothingReceived = "Nothing received yet"
        static let addressPlaceholder = "192.168.1.20 or 192.168.1.20:53317"
        static let addAction = "Add"
        static let done = "Done"
        static let sendTest = "Send 5 MB test"
        static let selected = "Selected"
        static let dismiss = "Dismiss"
    }

    enum Inbox {
        static let title = "Received"
        static let emptyTitle = "Nothing received yet"
        static let emptyHint = "Files appear here and in Files → Halo → Received."
        static let shareFile = "Share file"
    }

    enum Settings {
        static let title = "Settings"
        static let thisDevice = "This device"
        static let name = "Name"
        static let cloud = "Cloud"
        static let receiving = "Receiving"
        static let status = "Status"
        static let savedTo = "Saved to"
        static let savedToValue = "Halo → Received"
        static let about = "About HaloShare"
        static let protocolLabel = "Protocol"
        static let protocolValue = "LocalSend v2 · HTTP"
        static let fingerprint = "Fingerprint"
        static let notEncrypted = "Not encrypted"
        static let cloudNotSetUp = "Not set up"
        static let cloudRowTitle = "Cloud sync"
        static let cloudRowSubtitle = "Messages and clipboard"
        static let viewerOnly = "Viewer only on iPhone"
    }

    enum Consent {
        static let accept = "Accept"
        static let decline = "Decline"
        static let moreFiles = "more…"
        static let footer = "Only accept from people you know. Files are saved to Halo → Received."
    }

    enum Info {
        static let receivingTitle = "Receiving"
        static let receivingSummary = "How Halo handles files sent to this phone."
        static let discoveryTitle = "Finding devices"
        static let discoverySummary = "How Halo finds other devices on your Wi-Fi."
        static let aboutTitle = "About HaloShare"
        static let deviceTitle = "Device name"
        static let cloudTitle = "Cloud"
    }
}
