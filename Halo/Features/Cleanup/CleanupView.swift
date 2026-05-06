import SwiftUI

struct CleanupView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = CleanupViewModel()
    @State private var selectedCategory: CleanupKind = .systemCaches

    var body: some View {
        HStack(spacing: 0) {
            // Left Panel — Categories
            CleanupSidebar(selectedCategory: $selectedCategory, viewModel: viewModel)
                .frame(width: 260)
            Divider().background(Color.haloBorder)
            // Right Panel — File List
            CleanupFileList(category: selectedCategory, viewModel: viewModel)
        }
        .background(Color.haloSurface)
        .task { await viewModel.scanAll() }
    }
}

// MARK: - ViewModel

@MainActor
final class CleanupViewModel: ObservableObject {
    @Published var categories: [CleanupCategory] = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var cleanError: String? = nil
    @Published var lastCleanResult: (deleted: Int, freed: Int64)? = nil

    private let coordinator = ScanCoordinator()

    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.allBytes } }
    var totalFormatted: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    func scanAll() async {
        isScanning = true
        categories = CleanupKind.allCases.map { CleanupCategory(kind: $0) }
        await withTaskGroup(of: CleanupCategory.self) { group in
            for kind in CleanupKind.allCases {
                group.addTask { await self.coordinator.scanCategory(kind) }
            }
            for await cat in group {
                if let idx = categories.firstIndex(where: { $0.kind == cat.kind }) {
                    categories[idx] = cat
                }
            }
        }
        isScanning = false
    }

    /// Clean every item in the given category at once.
    func cleanAll(for kind: CleanupKind) async {
        guard let idx = categories.firstIndex(where: { $0.kind == kind }) else { return }
        isCleaning = true
        cleanError = nil
        let (deleted, freed, error) = await coordinator.executeCleanup(
            items: categories[idx].items
        )
        if let error { cleanError = error }
        lastCleanResult = (deleted, freed)
        categories[idx].items.removeAll { _ in deleted > 0 }   // remove all on success
        // Re-scan the category so sizes stay accurate
        let refreshed = await coordinator.scanCategory(kind)
        categories[idx] = refreshed
        isCleaning = false
    }

    /// Clean a single item — called from the per-row trash button.
    func cleanSingleItem(_ item: ScannedItem, for kind: CleanupKind) async {
        guard let idx = categories.firstIndex(where: { $0.kind == kind }) else { return }
        isCleaning = true
        cleanError = nil
        do {
            try await coordinator.deleteSingleItem(item)
            categories[idx].items.removeAll { $0.id == item.id }
            lastCleanResult = (1, item.size)
        } catch {
            cleanError = error.localizedDescription
        }
        isCleaning = false
    }

    func category(for kind: CleanupKind) -> CleanupCategory? {
        categories.first { $0.kind == kind }
    }

    func categoryIndex(for kind: CleanupKind) -> Int? {
        categories.firstIndex(where: { $0.kind == kind })
    }
}

// MARK: - Left Panel

struct CleanupSidebar: View {
    @Binding var selectedCategory: CleanupKind
    @ObservedObject var viewModel: CleanupViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header + Total
            VStack(spacing: 12) {
                HStack {
                    Text("Cleanup")
                        .font(HaloFont.display(17, weight: .bold))
                        .foregroundColor(.haloText)
                    Spacer()
                    if viewModel.isScanning {
                        ProgressView().scaleEffect(0.6).tint(.haloAccent)
                    }
                }

                VStack(spacing: 3) {
                    Text(viewModel.isScanning ? "Scanning…" : viewModel.totalFormatted)
                        .font(HaloFont.display(30, weight: .heavy))
                        .foregroundColor(.haloAccent)
                        .animation(.easeOut, value: viewModel.totalFormatted)
                    Text("total removable")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [Color.haloAccent.opacity(0.1), Color.haloAccent2.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.haloAccent.opacity(0.2), lineWidth: 1))
            }
            .padding(16)

            Divider().background(Color.haloBorder)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(CleanupKind.allCases) { kind in
                        let cat = viewModel.category(for: kind)
                        CleanupCategoryRow(
                            kind: kind,
                            category: cat,
                            isSelected: selectedCategory == kind
                        ) { selectedCategory = kind }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

struct CleanupCategoryRow: View {
    let kind: CleanupKind
    let category: CleanupCategory?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .haloAccent : .haloText2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.rawValue)
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(isSelected ? .haloText : .haloText2)
                    if let cat = category, !cat.isScanning {
                        Text(cat.allFormatted)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    } else {
                        Text("Scanning…")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(isSelected ? Color.haloAccent.opacity(0.08) : Color.clear)
            .overlay(
                Rectangle()
                    .fill(isSelected ? Color.haloAccent : Color.clear)
                    .frame(width: 3)
                , alignment: .leading
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right Panel

struct CleanupFileList: View {
    let category: CleanupKind
    @ObservedObject var viewModel: CleanupViewModel
    @State private var showCleanAllConfirm = false
    @State private var showErrorAlert = false

    private var currentCategory: CleanupCategory? {
        viewModel.category(for: category)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(HaloFont.display(15, weight: .semibold))
                        .foregroundColor(.haloText)
                    if let cat = currentCategory, !cat.items.isEmpty {
                        Text("\(cat.items.count) item\(cat.items.count == 1 ? "" : "s") · \(cat.allFormatted)")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    }
                }
                Spacer()
                if let cat = currentCategory, !cat.items.isEmpty {
                    // Clean All button — trashes every item in this category
                    Button {
                        showCleanAllConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.isCleaning {
                                ProgressView().scaleEffect(0.6).tint(.white)
                            } else {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text("Clean All (\(cat.allFormatted))")
                                .font(HaloFont.body(13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.haloRed.opacity(viewModel.isCleaning ? 0.5 : 1))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isCleaning)
                    .confirmationDialog(
                        "Move all \(cat.items.count) items (\(cat.allFormatted)) to Trash?",
                        isPresented: $showCleanAllConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Move to Trash", role: .destructive) {
                            Task { await viewModel.cleanAll(for: category) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Error banner
            if let error = viewModel.cleanError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.haloAmber)
                    Text(error)
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        viewModel.cleanError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundColor(.haloText2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.haloAmber.opacity(0.08))
                .overlay(Rectangle().fill(Color.haloAmber).frame(height: 1), alignment: .bottom)
            }

            Divider().background(Color.haloBorder)

            if viewModel.isScanning {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2).tint(.haloAccent)
                    Text("Scanning \(category.rawValue)…")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let cat = currentCategory, !cat.items.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(cat.items) { item in
                            FileItemRow(
                                item: item,
                                category: category,
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding(16)
                }
                .accessibilityIdentifier("fileListView")
            } else {
                EmptyCleanupState(category: category)
            }
        }
    }
}

// MARK: - File Item Row

struct FileItemRow: View {
    let item: ScannedItem
    let category: CleanupKind
    @ObservedObject var viewModel: CleanupViewModel
    @State private var showTrashConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            // File type icon
            Image(systemName: item.kind.icon)
                .font(.system(size: 14))
                .foregroundColor(.haloText2)
                .frame(width: 20)

            // Path + filename
            VStack(alignment: .leading, spacing: 2) {
                Text(item.parentDisplayPath + "/")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
                    .lineLimit(1)
                Text(item.name)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
            }

            Spacer()

            // Size
            Text(item.sizeFormatted)
                .font(HaloFont.body(12, weight: .medium))
                .foregroundColor(.haloText2)
                .frame(width: 72, alignment: .trailing)

            // Modified date
            if let modified = item.modifiedDate {
                Text(RelativeDateTimeFormatter().localizedString(for: modified, relativeTo: Date()))
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText3)
                    .frame(width: 80, alignment: .trailing)
            }

            // Per-item trash button (red)
            Button {
                showTrashConfirm = true
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color.haloRed)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCleaning)
            .confirmationDialog(
                "Move \"\(item.name)\" (\(item.sizeFormatted)) to Trash?",
                isPresented: $showTrashConfirm,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    Task { await viewModel.cleanSingleItem(item, for: category) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.haloSurface2)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
        .opacity(viewModel.isCleaning ? 0.6 : 1)
    }
}

// MARK: - Empty State

struct EmptyCleanupState: View {
    let category: CleanupKind

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.haloGreen)
            Text("\(category.rawValue) is clean!")
                .font(HaloFont.display(15, weight: .semibold))
                .foregroundColor(.haloText)
            Text("No files found that need cleanup.")
                .font(HaloFont.body(13))
                .foregroundColor(.haloText2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
