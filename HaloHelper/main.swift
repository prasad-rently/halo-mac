import Foundation

// MARK: - HaloHelper  (F-002)
//
// Entry point for the HaloHelper XPC service.
// This runs as a separate sandboxed process embedded inside Halo.app/Contents/XPCServices/.
//
// The listener blocks indefinitely — the OS launches/terminates this process
// on demand. It never runs continuously in the background.

let delegate = HaloHelperDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
