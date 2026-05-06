import SwiftUI
import AppKit

struct ClipboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ClipboardViewModel()

    var body: some View {
        HStack(spacing: 0) {
            ClipboardSidebar(viewModel: viewModel)
                .frame(width: 230)
            Divider().background(Color.haloBorder)
            ClipboardItemList(viewModel: viewModel)
        }
        .background(Color.haloSurface)
        .onAppear {
            viewModel.setItems(appState.clipboardItems)
            viewModel.appState = appState
        }
        .onChange(of: appState.clipboardItems) { newItems in viewModel.setItems(newItems) }
        .onChange(of: viewModel.deleteRequest) { item in
            if let item { appState.deleteClipboardItem(item) }
        }
        .onChange(of: viewModel.pinToggleRequest) { item in
            if let item { appState.togglePinClipboard(item) }
        }
        .onChange(of: viewModel.clearAllRequest) { newVal in if newVal { appState.clearAllClipboard() } }
    }
}

// MARK: - ViewModel

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var allItems: [ClipboardItem] = []
    @Published var selectedFilter: ClipboardFilter = .all
    @Published var searchText: String = ""
    @Published var selectedItem: ClipboardItem? = nil

    // Action requests piped back to AppState
    @Published var deleteRequest: ClipboardItem? = nil
    @Published var pinToggleRequest: ClipboardItem? = nil
    @Published var clearAllRequest: Bool = false

    weak var appState: AppState?

    enum ClipboardFilter: String, CaseIterable {
        case all = "All Items"
        case pinned = "Pinned"
        case text = "Text"
        case url = "URLs"
        case code = "Code"
        case image = "Images"

        var icon: String {
            switch self {
            case .all: return "clock.fill"
            case .pinned: return "pin.fill"
            case .text: return "doc.text.fill"
            case .url: return "link"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .image: return "photo.fill"
            }
        }
    }

    var filteredItems: [ClipboardItem] {
        var items = allItems
        // Filter by kind
        switch selectedFilter {
        case .all: break
        case .pinned: items = items.filter(\.isPinned)
        case .text: items = items.filter { $0.kind == .text }
        case .url: items = items.filter { $0.kind == .url }
        case .code: items = items.filter { $0.kind == .code }
        case .image: items = items.filter { $0.kind == .image }
        }
        // Search
        if !searchText.isEmpty {
            items = items.filter { $0.preview.localizedCaseInsensitiveContains(searchText) }
        }
        return items
    }

    var groupedItems: [(label: String, items: [ClipboardItem])] {
        let calendar = Calendar.current
        var groups: [(String, [ClipboardItem])] = []
        var todayItems: [ClipboardItem] = []
        var yesterdayItems: [ClipboardItem] = []
        var olderItems: [ClipboardItem] = []
        for item in filteredItems {
            if calendar.isDateInToday(item.copiedDate) { todayItems.append(item) }
            else if calendar.isDateInYesterday(item.copiedDate) { yesterdayItems.append(item) }
            else { olderItems.append(item) }
        }
        if !todayItems.isEmpty { groups.append(("Today", todayItems)) }
        if !yesterdayItems.isEmpty { groups.append(("Yesterday", yesterdayItems)) }
        if !olderItems.isEmpty { groups.append(("Earlier", olderItems)) }
        return groups
    }

    var storageUsedBytes: Int {
        allItems.reduce(0) { $0 + ($1.preview.data(using: .utf8)?.count ?? 0) }
    }

    var storageRatio: Double {
        Double(storageUsedBytes) / (10 * 1024 * 1024) // 10 MB limit
    }

    func setItems(_ items: [ClipboardItem]) {
        allItems = items
    }

    func count(for filter: ClipboardFilter) -> Int {
        switch filter {
        case .all: return allItems.count
        case .pinned: return allItems.filter(\.isPinned).count
        case .text: return allItems.filter { $0.kind == .text }.count
        case .url: return allItems.filter { $0.kind == .url }.count
        case .code: return allItems.filter { $0.kind == .code }.count
        case .image: return allItems.filter { $0.kind == .image }.count
        }
    }

    func pasteItem(_ item: ClipboardItem) {
        if let state = appState {
            state.pasteToSystemClipboard(item)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            switch item.content {
            case .text(let s): pb.setString(s, forType: .string)
            case .url(let u): pb.setString(u.absoluteString, forType: .string)
            case .code(let c, _): pb.setString(c, forType: .string)
            case .image(let d, _): pb.setData(d, forType: .tiff)
            case .color(let hex): pb.setString(hex, forType: .string)
            }
        }
    }

}

// MARK: - Sidebar

struct ClipboardSidebar: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text("Clipboard")
                    .font(HaloFont.display(16, weight: .bold))
                    .foregroundColor(.haloText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.haloText2)
                TextField("Search history…", text: $viewModel.searchText)
                    .font(HaloFont.body(12))
                    .textFieldStyle(.plain)
                    .foregroundColor(.haloText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.haloSurface2)
            .cornerRadius(9)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.haloBorder, lineWidth: 1))
            .padding(.horizontal, 10)

            Spacer().frame(height: 8)

            // Filters
            VStack(spacing: 2) {
                ForEach(ClipboardViewModel.ClipboardFilter.allCases, id: \.self) { filter in
                    ClipboardFilterRow(
                        filter: filter,
                        count: viewModel.count(for: filter),
                        isSelected: viewModel.selectedFilter == filter
                    ) {
                        viewModel.selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal, 6)

            Spacer()

            // Storage indicator
            VStack(alignment: .leading, spacing: 6) {
                Text("History Storage")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
                HaloMiniBar(value: viewModel.storageRatio,
                            color: viewModel.storageRatio > 0.8 ? .haloAmber : .haloAccent)
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(viewModel.storageUsedBytes), countStyle: .file))
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    Spacer()
                    Text("/ 10 MB")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText3)
                }
            }
            .padding(12)
            .background(Color.haloSurface2)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
            .padding(10)
        }
    }
}

struct ClipboardFilterRow: View {
    let filter: ClipboardViewModel.ClipboardFilter
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: filter.icon)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .haloAccent : .haloText2)
                    .frame(width: 18)
                Text("\(filter.rawValue)")
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(isSelected ? .haloAccent : .haloText2)
                Spacer()
                Text("\(count)")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.haloAccent.opacity(0.1) : Color.clear)
            .cornerRadius(9)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Item List

struct ClipboardItemList: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack(spacing: 8) {
                Text("History")
                    .font(HaloFont.display(15, weight: .semibold))
                    .foregroundColor(.haloText)
                Spacer()
                HaloGhostButton("Clear All", icon: "trash") {
                    viewModel.clearAllRequest = true
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().background(Color.haloBorder)

            if viewModel.groupedItems.isEmpty {
                ClipboardEmptyState()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(viewModel.groupedItems, id: \.label) { group in
                            Section {
                                ForEach(group.items) { item in
                                    ClipboardItemRow(
                                        item: item,
                                        isSelected: viewModel.selectedItem?.id == item.id,
                                        onSelect: { viewModel.selectedItem = item },
                                        onPaste: { viewModel.pasteItem(item) },
                                        onPin: { viewModel.pinToggleRequest = item },
                                        onDelete: { viewModel.deleteRequest = item }
                                    )
                                }
                            } header: {
                                HStack {
                                    Text(group.label)
                                        .font(HaloFont.body(10, weight: .semibold))
                                        .foregroundColor(.haloText3)
                                        .tracking(1.2)
                                        .textCase(.uppercase)
                                    Spacer()
                                }
                                .padding(.horizontal, 18)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                                .background(Color.haloSurface)
                            }
                        }
                    }
                    .padding(.bottom, 60)
                }

                // Bottom action strip
                ClipboardActionStrip(viewModel: viewModel)
            }
        }
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 16))
                    .foregroundColor(item.kind.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.preview)
                        .font(item.kind == .code ? HaloFont.mono(12) : HaloFont.body(12))
                        .foregroundColor(.haloText)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        // Type badge
                        Text(item.kind.rawValue.uppercased())
                            .font(HaloFont.body(9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(item.kind.accentColor.opacity(0.12))
                            .foregroundColor(item.kind.accentColor)
                            .cornerRadius(4)

                        Text(item.copiedDateFormatted)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)

                        if let app = item.sourceApp {
                            Text("· \(app)")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText3)
                        }
                    }
                }

                Spacer()

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.haloAmber)
                }

                // Inline actions (hover)
                if isHovered {
                    HStack(spacing: 6) {
                        ClipboardActionButton(icon: "doc.on.clipboard", tooltip: "Paste") { onPaste() }
                        ClipboardActionButton(icon: item.isPinned ? "pin.slash" : "pin", tooltip: "Pin") { onPin() }
                        ClipboardActionButton(icon: "trash", tooltip: "Delete", isDestructive: true) { onDelete() }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                isSelected
                    ? Color.haloAccent.opacity(0.08)
                    : isHovered ? Color.haloSurface2 : Color.clear
            )
            .overlay(
                Rectangle()
                    .fill(item.isPinned ? Color.haloAmber.opacity(0.15) : Color.clear)
                    .frame(width: 3),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Paste", action: onPaste)
            Button(item.isPinned ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

struct ClipboardActionButton: View {
    let icon: String
    let tooltip: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(isDestructive ? .haloRed : .haloText2)
                .padding(5)
                .background(Color.haloSurface)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.haloBorder2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

struct ClipboardActionStrip: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        HStack(spacing: 8) {
            Divider().background(Color.haloBorder).frame(height: 1)
        }
        .padding(0)
        .overlay(alignment: .top) { Divider().background(Color.haloBorder) }
        HStack(spacing: 8) {
            ForEach(["Paste", "Pin", "Preview", "Delete"], id: \.self) { action in
                Button(action) {
                    switch action {
                    case "Paste":
                        if let item = viewModel.selectedItem { viewModel.pasteItem(item) }
                    case "Pin":
                        if let item = viewModel.selectedItem { viewModel.pinToggleRequest = item }
                    case "Delete":
                        if let item = viewModel.selectedItem { viewModel.deleteRequest = item }
                    default: break
                    }
                }
                .font(HaloFont.body(11))
                .foregroundColor(.haloText2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.haloSurface2)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
                .buttonStyle(.plain)
                .disabled(viewModel.selectedItem == nil && action != "Paste")
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.haloSurface)
        .overlay(alignment: .top) { Divider().background(Color.haloBorder) }
    }
}

struct ClipboardEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundColor(.haloText3)
            Text("No clipboard history")
                .font(HaloFont.display(14, weight: .semibold))
                .foregroundColor(.haloText2)
            Text("Copy something to get started")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
