import Testing
import Foundation
import Network
@testable import HaloShareKit

// MARK: - Local Network permission

@Suite("LocalNetworkPermission")
struct LocalNetworkPermissionTests {
    @Test("Browser states map to the permission they imply")
    func classify() {
        #expect(LocalNetworkPermission.classify(.ready) == .granted)
        #expect(LocalNetworkPermission.classify(.waiting(.dns(-65570))) == .denied, "kDNSServiceErr_PolicyDenied")
        #expect(LocalNetworkPermission.classify(.failed(.dns(-65570))) == .denied)
        // Other trouble is not a permission verdict.
        #expect(LocalNetworkPermission.classify(.waiting(.dns(-65537))) == nil)
        #expect(LocalNetworkPermission.classify(.waiting(.posix(.ENETDOWN))) == nil)
        #expect(LocalNetworkPermission.classify(.setup) == nil)
        #expect(LocalNetworkPermission.classify(.cancelled) == nil)
    }

    @Test("An empty scan is explained when — and only when — permission is the cause")
    func explanation() {
        let denied = LocalNetworkPermission.explanationForEmptyScan(access: .denied)
        #expect(denied?.contains("Local Network") == true)
        #expect(LocalNetworkPermission.explanationForEmptyScan(access: .granted) == nil)
        #expect(LocalNetworkPermission.explanationForEmptyScan(access: .undetermined) == nil)
    }
}

// MARK: - Peer directory

private func peer(_ alias: String, _ fp: String, host: String = "10.0.0.2", port: Int = 53317, seen: TimeInterval = 0) -> Peer {
    Peer(info: DeviceInfo(alias: alias, fingerprint: fp, port: port), host: host, lastSeen: Date(timeIntervalSince1970: seen))
}

@Suite("PeerDirectory")
struct PeerDirectoryTests {
    @Test("One row per fingerprint; the owning host refreshes it, last seen wins")
    func dedupe() {
        var d = PeerDirectory(ownFingerprint: "me")
        d.merge(peer("Mac", "aa", host: "10.0.0.2", seen: 1))
        d.merge(peer("Mac", "aa", host: "10.0.0.2", seen: 5))        // the same device, seen again
        d.merge(peer("Mac", "aa", host: "10.0.0.2", seen: 3))        // an older sighting must not win
        #expect(d.peers.count == 1)
        #expect(d.peers[0].lastSeen == Date(timeIntervalSince1970: 5))
    }

    @Test("Another host cannot claim a listed fingerprint and take over its row (first sighting wins)")
    func noTakeover() {
        var d = PeerDirectory(ownFingerprint: "me")
        #expect(d.mergeOutcome(peer("Gokul's Mac", "aa", host: "10.0.0.2", seen: 1)) == .added)
        // A host on the LAN announces itself with the same fingerprint (and a newer timestamp).
        #expect(d.mergeOutcome(peer("Gokul's Mac", "aa", host: "10.0.0.66", seen: 99)) == .ignoredConflict(existingHost: "10.0.0.2"))
        #expect(d.merge(peer("Evil", "aa", host: "10.0.0.66", seen: 100)) == false)
        #expect(d.peers.count == 1)
        #expect(d.peers[0].host == "10.0.0.2")
        #expect(d.peers[0].alias == "Gokul's Mac")
        // A genuine move arrives as a network change, which clears the list; the device is then found at its new address.
        d.removeAll()
        #expect(d.mergeOutcome(peer("Gokul's Mac", "aa", host: "172.20.10.2", seen: 120)) == .added)
        #expect(d.peers[0].host == "172.20.10.2")
    }

    @Test("We never list ourselves")
    func ignoresSelf() {
        var d = PeerDirectory(ownFingerprint: "me")
        #expect(d.merge(peer("This phone", "me", host: "127.0.0.1")) == false)
        #expect(d.peers.isEmpty)
        #expect(d.merge(peer("Mac", "aa")) == true)
    }

    @Test("A new identity at the same host:port replaces the stale one; a different port does not")
    func reinstalled() {
        var d = PeerDirectory(ownFingerprint: "me")
        d.merge(peer("Pixel", "old", host: "10.0.0.5", port: 53317))
        d.merge(peer("Pixel", "new", host: "10.0.0.5", port: 53317))
        #expect(d.peers.map(\.id) == ["new"])
        d.merge(peer("Other", "third", host: "10.0.0.5", port: 53400))
        #expect(Set(d.peers.map(\.id)) == ["new", "third"])
    }

    @Test("Sorted by name, stably")
    func order() {
        var d = PeerDirectory(ownFingerprint: "me")
        d.merge(peer("zeta", "1", host: "a")); d.merge(peer("Alpha", "2", host: "b")); d.merge(peer("alpha", "0", host: "c"))
        #expect(d.peers.map(\.id) == ["0", "2", "1"])
    }
}

// MARK: - Manual addresses

@Suite("ManualAddressBook")
struct ManualAddressBookTests {
    @Test("Remembered across instances (the persisted store), most recent first, no duplicates")
    func remembers() {
        let store = InMemoryIdentityStore()
        let book = ManualAddressBook(store: store)
        book.remember("192.168.1.20"); book.remember("192.168.1.30:53400"); book.remember("192.168.1.20:53317")
        #expect(ManualAddressBook(store: store).addresses == ["192.168.1.20:53317", "192.168.1.30:53400"])
    }

    @Test("Invalid input is never stored, and a corrupt store yields nothing rather than a probe target")
    func validation() {
        let store = InMemoryIdentityStore()
        let book = ManualAddressBook(store: store)
        for bad in ["", "   ", "http://evil.example/x", "a b", "host:99999", "10.0.0.1/../x"] {
            #expect(book.remember(bad) == nil, "\(bad)")
        }
        #expect(book.addresses.isEmpty)
        store.set(#"["10.0.0.4","javascript:alert(1)","x y"]"#, forKey: ManualAddressBook.key)
        #expect(book.addresses == ["10.0.0.4:53317"])
        store.set("garbage", forKey: ManualAddressBook.key)
        #expect(book.addresses.isEmpty)
    }

    @Test("Capped, and entries can be forgotten")
    func cap() {
        let book = ManualAddressBook(store: InMemoryIdentityStore(), limit: 3)
        for i in 1...5 { book.remember("10.0.0.\(i)") }
        #expect(book.addresses == ["10.0.0.5:53317", "10.0.0.4:53317", "10.0.0.3:53317"])
        book.forget("10.0.0.4:53317")
        #expect(book.addresses == ["10.0.0.5:53317", "10.0.0.3:53317"])
    }
}

// MARK: - Network change

@Suite("NetworkChangeDetector")
struct NetworkChangeTests {
    @Test("Baseline first; then only a real change fires — including losing the network")
    func detector() {
        var d = NetworkChangeDetector()
        let home = NetworkSignature(value: "en0=192.168.1.5/255.255.255.0")
        let cafe = NetworkSignature(value: "en0=10.1.2.3/255.255.0.0")
        let none = NetworkSignature(value: "")
        #expect(d.observe(home) == false)
        #expect(d.observe(home) == false)
        #expect(d.observe(cafe) == true)
        #expect(d.observe(cafe) == false)
        #expect(d.observe(none) == true)
        #expect(none.isOffline)
        #expect(d.observe(home) == true)
    }

    @Test("The signature ignores interface order")
    func order() {
        let a = LocalNetwork.Interface(name: "en0", address: "10.0.0.2", netmask: "255.255.255.0")
        let b = LocalNetwork.Interface(name: "en1", address: "10.0.1.2", netmask: "255.255.255.0")
        #expect(NetworkSignature.make(from: [a, b]) == NetworkSignature.make(from: [b, a]))
    }
}

// MARK: - Background policy

@MainActor
private final class FakeBackground: BackgroundTaskProviding {
    var begun = 0, ended: [Int] = [], refuse = false
    var expire: (@MainActor () -> Void)?
    func beginTask(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        if refuse { return nil }
        begun += 1; expire = expiration; return begun
    }
    func endTask(_ token: Int) { ended.append(token) }
}

@MainActor
private final class FakeNotifier: InterruptionNotifying {
    var posted: [Set<BackgroundTransferGuard.Work>] = []
    func notifyInterrupted(_ work: Set<BackgroundTransferGuard.Work>) { posted.append(work) }
}

@MainActor
@Suite("BackgroundTransferGuard")
struct BackgroundTransferGuardTests {

    private func make() -> (BackgroundTransferGuard, FakeBackground, FakeNotifier) {
        let bg = FakeBackground(), n = FakeNotifier()
        return (BackgroundTransferGuard(provider: bg, notifier: n), bg, n)
    }

    @Test("Nothing in flight: no background task, no notification — the app may stop listening at once")
    func idle() {
        let (g, bg, n) = make()
        #expect(g.appDidEnterBackground() == false)
        #expect(bg.begun == 0 && n.posted.isEmpty)
    }

    @Test("A send in flight when backgrounded holds a task; finishing in time releases it, silently")
    func finishInTime() {
        let (g, bg, n) = make()
        var idled = 0
        g.onIdleInBackground = { idled += 1 }
        g.setActive(.sending, true)
        #expect(g.appDidEnterBackground() == true)
        #expect(g.isHoldingTask)
        g.setActive(.sending, false)
        #expect(!g.isHoldingTask && bg.ended == [1])
        #expect(idled == 1, "owner told it can now stop the listener")
        #expect(n.posted.isEmpty, "no notification when it finished")
    }

    @Test("The system running out of time posts exactly one interruption notification and tells the owner")
    func expiry() {
        let (g, bg, n) = make()
        var expired: [Set<BackgroundTransferGuard.Work>] = []
        g.onExpired = { expired.append($0) }
        g.setActive(.sending, true); g.setActive(.receiving, true)
        g.appDidEnterBackground()
        bg.expire?()
        #expect(n.posted == [[.sending, .receiving]])
        #expect(expired == [[.sending, .receiving]])
        #expect(!g.isHoldingTask && bg.ended == [1])
    }

    @Test("If the system refuses a background task the outcome is the same as expiry — never silence")
    func refused() {
        let (g, bg, n) = make()
        bg.refuse = true
        g.setActive(.sending, true)
        #expect(g.appDidEnterBackground() == false)
        #expect(n.posted == [[.sending]])
    }

    @Test("Coming back to the foreground releases the task and posts nothing")
    func foregroundAgain() {
        let (g, bg, n) = make()
        g.setActive(.receiving, true)
        g.appDidEnterBackground()
        g.appDidBecomeActive()
        #expect(bg.ended == [1] && n.posted.isEmpty)
        #expect(g.activeWork == [.receiving], "the transfer itself carries on in the foreground")
    }

    @Test("Backgrounding twice doesn't stack tasks")
    func once() {
        let (g, bg, _) = make()
        g.setActive(.sending, true)
        g.appDidEnterBackground(); g.appDidEnterBackground()
        #expect(bg.begun == 1)
    }
}
