import Foundation

/// Copy for the HaloShare surfaces. Short on the screen; the honest detail lives in info sheets.
enum ShareStrings {
    static let send = "Send"
    static let sendTo = "Send to"
    static let readyToSend = "Ready"
    static let notSentYet = "Not sent yet"
    static let chooseDevice = "Choose a device"
    static let discardTitle = "Discard these items?"
    static let discardDetail = "They won't be sent. The originals are not touched."

    static let receivingChip = "Receiving while open"
    static let noFiles = "No files yet"
    static let localNetwork = "Local Network"
    static let localNetworkOff = "Local Network off"

    static let receivingInfoTitle = "Receiving"
    static let receivingInfo = "Receiving works while Halo is open. iOS doesn't let apps listen in the background, so keep Halo open to receive. If you leave Halo mid-transfer it gets a short moment to finish, and notifies you if it couldn't. Interrupted transfers start again from the beginning."
    static let safetyInfo = "Nothing is saved until you accept. Files never overwrite each other. Items shared from other apps wait in Halo until you choose a device and tap Send."
    static let localNetworkInfoTitle = "Local Network"
    static let localNetworkInfo = "To find your other devices, Halo looks for HaloShare and LocalSend on your Wi-Fi. iOS asks you to allow this once. Nothing leaves your network."
    static let localNetworkDeniedInfo = "Without Local Network access Halo can't see other devices, and they can't send to this one. Turn it on in Settings → Privacy & Security → Local Network → Halo."
    static let sendingInfo = "Keep Halo open until this finishes. If you leave, iOS gives it a short moment to wrap up."
}
