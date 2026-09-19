// ──────────────────────────────────────────────────────────────────────────────
// LetheView.swift — F-052
//
// The Lethe module: room list on the left, transcript on the right.
// Dark-only Halo design tokens throughout — no adaptive colours (CLAUDE.md).
// ──────────────────────────────────────────────────────────────────────────────

import SwiftUI
import AppKit

struct LetheView: View {

    @StateObject private var manager = LetheManager.shared
    @State private var selectedRoomID: String?
    @State private var draft = ""
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showInviteFor: LetheRoom?
    @State private var confirmLeave: LetheRoom?
    @State private var errorText: String?
    @State private var showSettings = false

    private var selectedRoom: LetheRoom? {
        manager.rooms.first { $0.id == selectedRoomID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.haloSurface2)
            if manager.rooms.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    roomList
                        .frame(width: 240)
                    Divider().overlay(Color.haloSurface2)
                    transcript
                }
            }
        }
        .background(Color.haloBackground)
        .onAppear {
            manager.start()
            if selectedRoomID == nil { selectedRoomID = manager.rooms.first?.id }
        }
        // Single-parameter form: the two-parameter onChange is macOS 14+, and
        // Halo's deployment target is 13.0.
        .onChange(of: selectedRoomID) { newValue in
            manager.activeRoomId = newValue
            if let newValue { manager.markRead(roomId: newValue) }
        }
        .onDisappear { manager.activeRoomId = nil }
        .sheet(isPresented: $showCreate) {
            LetheCreateRoomSheet { name in
                if let room = manager.createRoom(named: name) { selectedRoomID = room.id }
            }
        }
        .sheet(isPresented: $showJoin) {
            LetheJoinRoomSheet { link in
                do {
                    let room = try manager.join(inviteLink: link)
                    selectedRoomID = room.id
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            LetheSettingsSheet(manager: manager)
        }
        .sheet(item: $showInviteFor) { room in
            LetheInviteSheet(room: room, link: manager.inviteLink(for: room))
        }
        .confirmationDialog(
            "Leave “\(confirmLeave?.name ?? "")”?",
            isPresented: Binding(get: { confirmLeave != nil },
                                 set: { if !$0 { confirmLeave = nil } }),
            titleVisibility: .visible
        ) {
            Button("Leave and delete key", role: .destructive) {
                if let room = confirmLeave {
                    if selectedRoomID == room.id { selectedRoomID = nil }
                    manager.leave(room: room)
                }
                confirmLeave = nil
            }
            Button("Cancel", role: .cancel) { confirmLeave = nil }
        } message: {
            Text("The room key and this Mac's copy of the conversation are deleted. "
                 + "There is no server copy — you can only get back in with a new invite link.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lethe").font(HaloFont.display(20, weight: .heavy)).foregroundColor(.haloText)
                Text("Anonymous, ephemeral. The relay never sees your messages.")
                    .font(.caption).foregroundColor(.haloText3)
            }
            Spacer()
            connectionPill
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.bordered)
                .help("Handle, relay, and what the relay can see")
            Button { showJoin = true } label: { Label("Join", systemImage: "link") }
                .buttonStyle(.bordered)
            Button { showCreate = true } label: { Label("New Room", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle().fill(connectionColor).frame(width: 7, height: 7)
            Text(manager.connection.label).font(.caption).foregroundColor(.haloText2)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.haloSurface2))
        .help(manager.lastRelayError ?? manager.relayURLString)
    }

    private var connectionColor: Color {
        switch manager.connection {
        case .connected:                 return .haloGreen
        case .waking, .connecting,
             .reconnecting:              return .haloAmber
        case .offline:                   return .haloRed
        }
    }

    // MARK: - Empty state

    // Centred with `.frame(maxHeight: .infinity)` rather than a pair of
    // `Spacer()`s, and that distinction is the whole bug.
    //
    // Spacers make the *VStack itself* greedy, so it grew past the detail pane
    // and pushed the module header off the top of the window — measured via the
    // accessibility tree at y = -465, i.e. 495pt above the window. The frame
    // modifier instead takes the proposed height and centres a naturally-sized
    // child inside it, so the header keeps its place.
    //
    // The sibling modules (LocalShareView, PortManagerView) dodge this by
    // wrapping everything in a ScrollView; a chat cannot, because the header and
    // composer must stay pinned while only the transcript scrolls.
    // Rooted in a ScrollView, and that is the whole fix — not cosmetic.
    //
    // `NavigationSplitView` mis-lays-out the *sidebar* column when the detail
    // view is an unboundedly flexible sibling: the sidebar jumps/scrolls and
    // this module's header gets pushed off the top of the window (measured at
    // y = -443 against a window origin of y = 30).
    //
    // This is the same bug `f787e9c` fixed for AI Assistant's "connect your API
    // key" screen — "every other module's detail view roots itself in a
    // ScrollView; AIAssistantView's did not". The populated branch is fine
    // because `roomList` and `messageScroll` are both ScrollViews; only this
    // branch was missing one.
    //
    // `minHeight` rather than `maxHeight: .infinity` for the same reason:
    // it gives the content a floor without re-introducing an unbounded demand.
    // Three earlier attempts that kept an unbounded height all failed.
    private var emptyState: some View {
        ScrollView {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 42)).foregroundColor(.haloAccent)
            Text("No rooms yet").font(HaloFont.display(17, weight: .bold)).foregroundColor(.haloText)
            Text("Create a room and share its invite, or paste an invite you were sent.\n"
                 + "No account, no phone number — the relay only ever sees encrypted blobs.")
                .font(.callout).foregroundColor(.haloText3)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button { showCreate = true } label: { Label("New Room", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button { showJoin = true } label: { Label("Join with a link", systemImage: "link") }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 460)
        .padding(.top, 100)
        }
    }

    // MARK: - Room list

    private var roomList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(manager.rooms) { room in
                    roomRow(room)
                }
            }
            .padding(8)
        }
        .background(Color.haloSurface)
    }

    private func roomRow(_ room: LetheRoom) -> some View {
        Button { selectedRoomID = room.id } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name).font(.callout.weight(.medium))
                        .foregroundColor(.haloText).lineLimit(1)
                    Text(room.id).font(HaloFont.mono(9)).foregroundColor(.haloText3)
                }
                Spacer()
                if room.unreadCount > 0 {
                    Text("\(room.unreadCount)")
                        .font(.caption2.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.haloAccent))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selectedRoomID == room.id ? Color.haloAccent.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show invite…") { showInviteFor = room }
            Divider()
            Button("Leave room", role: .destructive) { confirmLeave = room }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if let room = selectedRoom {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(room.name).font(.headline).foregroundColor(.haloText)
                        Text("you are \(manager.handle)")
                            .font(HaloFont.mono(9)).foregroundColor(.haloText3)
                    }
                    Spacer()
                    Button { showInviteFor = room } label: {
                        Label("Invite", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.bordered)
                }
                .padding(12)
                Divider().overlay(Color.haloSurface2)

                messageScroll(room)

                if let errorText {
                    Text(errorText).font(.caption).foregroundColor(.haloRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 6)
                }
                composer(room)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a room").foregroundColor(.haloText3)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func messageScroll(_ room: LetheRoom) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(manager.messagesByRoom[room.id] ?? []) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: manager.messagesByRoom[room.id]?.count ?? 0) { _ in
                if let last = manager.messagesByRoom[room.id]?.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bubble(_ m: LetheMessage) -> some View {
        HStack {
            if m.isOwn { Spacer(minLength: 60) }
            VStack(alignment: m.isOwn ? .trailing : .leading, spacing: 3) {
                Text(m.isOwn ? "you" : m.handle)
                    .font(HaloFont.mono(9)).foregroundColor(.haloText3)
                Text(m.text)
                    .font(.callout).foregroundColor(.haloText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(m.isOwn ? Color.haloAccent.opacity(0.22) : Color.haloSurface2))
                Text(m.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundColor(.haloText3)
            }
            if !m.isOwn { Spacer(minLength: 60) }
        }
    }

    private func composer(_ room: LetheRoom) -> some View {
        HStack(spacing: 8) {
            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.haloSurface2))
                .onSubmit { sendDraft(room) }

            if draft.count > LetheLimits.maxMessageCharacters - 200 {
                Text("\(draft.count)/\(LetheLimits.maxMessageCharacters)")
                    .font(.caption2)
                    .foregroundColor(draft.count > LetheLimits.maxMessageCharacters ? .haloRed : .haloText3)
            }
            Button { sendDraft(room) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty ? .haloText3 : .haloAccent)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private func sendDraft(_ room: LetheRoom) {
        do {
            try manager.send(text: draft, to: room)
            draft = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
