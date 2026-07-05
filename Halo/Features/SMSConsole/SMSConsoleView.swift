import SwiftUI

// MARK: - SMSConsoleView  (F-044)
//
// Desktop SMS console: Device → SIM line → per-line contact thread → messages
// (F-044 §7.5). Preview build uses mock data.

struct SMSConsoleView: View {
    @StateObject private var vm = SMSConsoleViewModel()
    @State private var showSetup = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.haloBorder)
            content
        }
        .background(Color.haloSurface)
        .sheet(isPresented: $showSetup) { CloudSetupView(client: vm.client) }
        .sheet(isPresented: $showSettings) { CloudSettingsPane(client: vm.client) }
    }

    /// The gear opens management when connected, otherwise the connect/setup flow.
    private func openGear() {
        if case .connected = vm.state { showSettings = true } else { showSetup = true }
    }

    @ViewBuilder private var content: some View {
        if !vm.isConfigured {
            connectEmptyState
        } else if vm.allThreads.isEmpty {
            noMessagesState
        } else {
            HStack(spacing: 0) {
                linesColumn.frame(width: 240)
                Divider().background(Color.haloBorder)
                threadsColumn.frame(width: 320)
                Divider().background(Color.haloBorder)
                messagesColumn.frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "message.fill").foregroundColor(.haloAccent)
            Text("Messages").font(HaloFont.display(18)).foregroundColor(.haloText)
            if vm.totalUnread > 0 { HaloBadge(text: "\(vm.totalUnread) unread", color: .haloAccent) }
            statusBadge
            Spacer()
            if case .connected = vm.state {
                Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundColor(.haloText2)
            }
            Button { openGear() } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.plain).foregroundColor(.haloText2)
            if vm.isConfigured { searchField.frame(width: 220) }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder private var statusBadge: some View {
        switch vm.state {
        case .connected: HaloBadge(text: "Connected", color: .haloGreen)
        case .connecting: HaloBadge(text: "Connecting…", color: .haloAmber)
        case .error: HaloBadge(text: "Error", color: .haloRed)
        case .unconfigured: HaloBadge(text: "Not connected", color: .haloText2)
        }
    }

    // MARK: Empty states

    private var connectEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.icloud").font(.system(size: 40)).foregroundColor(.haloAccent)
            Text("Connect your Firebase").font(HaloFont.display(18)).foregroundColor(.haloText)
            Text("Halo uses your own Firebase (BYOB) — your SMS are end-to-end encrypted and stored only in your account. Connect once, then sync from your phone.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2)
                .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            HaloPrimaryButton("Connect Firebase", icon: "link") { showSetup = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMessagesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 36)).foregroundColor(.haloText2)
            Text("No messages synced yet").font(HaloFont.body(14, weight: .semibold)).foregroundColor(.haloText)
            Text("Sync SMS from the Halo mobile app, or seed sample data to see the round-trip.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                HaloGhostButton("Refresh", icon: "arrow.clockwise") { Task { await vm.refresh() } }
                HaloGhostButton("Setup / Seed", icon: "gearshape") { showSetup = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.haloText2)
            TextField("Search messages", text: $vm.search)
                .textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
            if !vm.search.isEmpty {
                Button { vm.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(.haloText2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.haloSurface2).cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
    }

    // MARK: Lines column

    private func columnLabel(_ text: String) -> some View {
        Text(text).font(HaloFont.body(10, weight: .semibold)).foregroundColor(.haloText2)
            .padding(.leading, 8).padding(.bottom, 2)
    }

    private var linesColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                columnLabel("LINES")
                lineRow(title: "All lines", subtitle: "\(vm.lines.count) SIMs · \(vm.devices.count) devices",
                        icon: "square.stack.3d.up.fill", unread: vm.totalUnread,
                        selected: vm.selectedLineID == nil) { vm.selectedLineID = nil }
                ForEach(vm.lines) { line in
                    lineRow(title: vm.lineTitle(line), subtitle: vm.lineSubtitle(line),
                            icon: vm.device(line.deviceId)?.iconName ?? "candybarphone",
                            unread: vm.unread(forLine: line.id),
                            selected: vm.selectedLineID == line.id) { vm.selectedLineID = line.id }
                }
            }
            .padding(12)
        }
        .background(Color.haloBackground)
    }

    private func lineRow(title: String, subtitle: String, icon: String, unread: Int,
                         selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundColor(selected ? .haloAccent : .haloText2).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText).lineLimit(1)
                    Text(subtitle).font(HaloFont.body(10)).foregroundColor(.haloText2).lineLimit(1)
                }
                Spacer(minLength: 0)
                if unread > 0 {
                    Text("\(unread)").font(HaloFont.body(10, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.haloAccent).clipShape(Capsule())
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .background(selected ? Color.haloAccent.opacity(0.12) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: Threads column

    private var threadsColumn: some View {
        VStack(spacing: 0) {
            categoryChips
            Divider().background(Color.haloBorder)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(vm.filteredThreads) { thread in threadRow(thread) }
                    if vm.filteredThreads.isEmpty {
                        Text("No conversations").font(HaloFont.body(12)).foregroundColor(.haloText2)
                            .padding(.top, 40)
                    }
                }
                .padding(8)
            }
        }
        .background(Color.haloSurface)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", color: .haloText2, selected: vm.categoryFilter == nil) { vm.categoryFilter = nil }
                ForEach(vm.presentCategories) { cat in
                    chip(label: cat.label, color: cat.color, selected: vm.categoryFilter == cat) {
                        vm.categoryFilter = (vm.categoryFilter == cat) ? nil : cat
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private func chip(label: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(HaloFont.body(10, weight: .semibold))
                .foregroundColor(selected ? .white : color)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(selected ? color : color.opacity(0.14)).clipShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func threadRow(_ thread: SMSThread) -> some View {
        let selected = vm.selectedThreadID == thread.id
        return Button {
            vm.selectedThreadID = thread.id
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(thread.category.color.opacity(0.18)).frame(width: 34, height: 34)
                    Image(systemName: thread.category.icon).font(.system(size: 13)).foregroundColor(thread.category.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(thread.contactNumber).font(HaloFont.body(12, weight: .semibold))
                            .foregroundColor(.haloText).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(SMSTime.short(thread.lastDate)).font(HaloFont.body(10)).foregroundColor(.haloText2)
                    }
                    HStack {
                        Text(thread.lastMessage?.body ?? "").font(HaloFont.body(11)).foregroundColor(.haloText2).lineLimit(1)
                        Spacer(minLength: 4)
                        if thread.unreadCount > 0 { Circle().fill(Color.haloAccent).frame(width: 7, height: 7) }
                    }
                    // "All lines" view: badge each row with its source SIM so per-line
                    // threads stay distinguishable (a contact on two SIMs = two rows).
                    if vm.isAllLines, let source = vm.sourceLabel(for: thread) {
                        HStack(spacing: 4) {
                            Image(systemName: "simcard").font(.system(size: 8)).foregroundColor(.haloText2)
                            Text(source).font(HaloFont.body(9)).foregroundColor(.haloText2).lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .background(selected ? Color.haloSurface2 : Color.clear).cornerRadius(8)
        }.buttonStyle(.plain)
    }

    // MARK: Messages column

    private var messagesColumn: some View {
        Group {
            if let thread = vm.selectedThread, let line = vm.line(thread.lineId) {
                VStack(spacing: 0) {
                    threadHeader(thread, line: line)
                    Divider().background(Color.haloBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(thread.messages.sorted { $0.date < $1.date }) { messageBubble($0) }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32)).foregroundColor(.haloText2)
                    Text("Select a conversation").font(HaloFont.body(13)).foregroundColor(.haloText2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.haloSurface)
    }

    private func threadHeader(_ thread: SMSThread, line: SMSLine) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.contactNumber).font(HaloFont.display(15)).foregroundColor(.haloText)
                Text("on \(vm.lineTitle(line)) · \(line.ownNumber)")
                    .font(HaloFont.body(11)).foregroundColor(.haloText2)
            }
            Spacer()
            HaloBadge(text: thread.category.label, color: thread.category.color)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func messageBubble(_ m: SMSMessage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.body).font(HaloFont.body(13)).foregroundColor(.haloText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: m.category.icon).font(.system(size: 8)).foregroundColor(m.category.color)
                    Text(m.category.label).font(HaloFont.body(9)).foregroundColor(m.category.color)
                    Text("·").foregroundColor(.haloText2)
                    Text(SMSTime.clock(m.date)).font(HaloFont.body(9)).foregroundColor(.haloText2)
                }
            }
            .padding(12)
            .background(Color.haloSurface2).cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.haloBorder, lineWidth: 1))
            .frame(maxWidth: 520, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
