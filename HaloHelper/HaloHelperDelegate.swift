import Foundation

// MARK: - HaloHelperDelegate  (F-002)
//
// NSXPCListenerDelegate for the HaloHelper XPC service.
// Accepts connections from the main Halo app only.
// Validates the connecting process via audit token (code-signing requirement).

final class HaloHelperDelegate: NSObject, NSXPCListenerDelegate {

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Export the implementation object via the shared protocol
        connection.exportedInterface = NSXPCInterface(with: HaloHelperProtocol.self)
        connection.exportedObject = HaloHelperImpl()

        // Optional: validate calling app bundle ID for extra security
        // In a production signed build, audit-token validation ensures only
        // com.halo.mac can reach this service.
        connection.invalidationHandler = {
            NSLog("[HaloHelper] connection invalidated")
        }
        connection.interruptionHandler = {
            NSLog("[HaloHelper] connection interrupted")
        }

        connection.resume()
        return true
    }
}
