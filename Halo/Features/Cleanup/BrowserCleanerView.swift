import SwiftUI

// MARK: - Browser Cleaner (F-024) — "Browsers" tab of the Cleanup module
//
// Per-category breakdown of each detected browser's clearable data (HTTP cache,
// GPU shader cache, history, cookies, sessions, crash reports, site data), so a
// user can e.g. keep cookies while clearing cache. All clearing goes through
// `BrowserCleanerScanner.clear(_:categories:)`, which only ever calls
// `FileManager.trashItem` — never `removeItem` — and only after this view's
// review sheet has been explicitly confirmed.

@MainActor
final class BrowserCleanerViewModel: ObservableObject {
    @Published var browsers: [BrowserProfile] = []
    @Published var isLoading = false
    @Published var isClearing = false
    @Published var clearError: String? = nil
    @Published var lastFreedBytes: Int64? = nil
    @Published var reviewTarget: ReviewTarget? = nil

    private let scanner = BrowserCleanerScanner()

    enum ReviewTarget: Identifiable, Equatable {
        case all
        case single(UUID)
        var id: String {
            switch self {
            case .all: return "all"
            case .single(let id): return id.uuidString
            }
        }
    }

    var totalBytes: Int64 { browsers.reduce(0) { $0 + $1.totalBytes } }
    var totalFormatted: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    var hasAnyData: Bool { browsers.contains(where: \.hasData) }

    func loadAll() async {
        isLoading = true
        clearError = nil
        let detected = await scanner.detectBrowsers()
        let order = detected.map(\.id)

        var measured: [BrowserProfile] = []
        await withTaskGroup(of: BrowserProfile.self) { group in
            for browser in detected {
                group.addTask { await self.scanner.measure(browser) }
            }
            for await result in group { measured.append(result) }
        }
        // Task group completion order is nondeterministic — restore detection order.
        measured.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }

        // Pre-select only categories that actually have data, matching the
        // Protection module's Privacy Cleaner convention.
        for i in measured.indices {
            for j in measured[i].categories.indices {
                measured[i].categories[j].isSelected = measured[i].categories[j].hasData
            }
        }
        browsers = measured
        isLoading = false
    }

    func toggleCategory(browserID: UUID, categoryID: UUID) {
        guard let bi = browsers.firstIndex(where: { $0.id == browserID }),
              let ci = browsers[bi].categories.firstIndex(where: { $0.id == categoryID }) else { return }
        browsers[bi].categories[ci].isSelected.toggle()
    }

    /// Executes the confirmed clear for either every browser or a single one.
    func performClear(_ target: ReviewTarget) async {
        isClearing = true
        clearError = nil
        var totalFreed: Int64 = 0
        var firstError: String?

        let targetIDs: [UUID]
        switch target {
        case .all: targetIDs = browsers.map(\.id)
        case .single(let id): targetIDs = [id]
        }

        for id in targetIDs {
            guard let idx = browsers.firstIndex(where: { $0.id == id }) else { continue }
            let profile = browsers[idx]
            let selected = Set(profile.categories.filter(\.isSelected).map(\.id))
            guard !selected.isEmpty else { continue }
            let result = await scanner.clear(profile, categories: selected)
            totalFreed += result.freed
            if let error = result.error, firstError == nil { firstError = error }
            browsers[idx] = await scanner.measure(profile)
            // Keep prior selections for categories still holding data; clear the rest.
            for j in browsers[idx].categories.indices {
                browsers[idx].categories[j].isSelected = browsers[idx].categories[j].hasData
            }
        }

        if let firstError { clearError = firstError }
        lastFreedBytes = totalFreed
        isClearing = false
        reviewTarget = nil

        if totalFreed > 1_073_741_824 {
            CelebrationManager.shared.trigger(.spaceRecovered)
        }
    }
}

// MARK: - Sidebar Row (mirrors CleanupCategoryRow's styling for the .browsers kind)

struct BrowserCleanupCategoryRow: View {
    @ObservedObject var browserViewModel: BrowserCleanerViewModel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: CleanupKind.browsers.icon)
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .haloAccent : .haloText2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CleanupKind.browsers.rawValue)
                        .font(HaloFont.body(13, weight: .medium))
                        .foregroundColor(isSelected ? .haloText : .haloText2)
                    if browserViewModel.isLoading {
                        Text("Scanning…")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    } else {
                        Text(browserViewModel.totalFormatted)
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.haloAccent.opacity(0.08) : Color.clear)
            .overlay(
                Rectangle()
                    .fill(isSelected ? Color.haloAccent : Color.clear)
                    .frame(width: 3)
                , alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main Pane

struct BrowserCleanerPane: View {
    @ObservedObject var viewModel: BrowserCleanerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if let freed = viewModel.lastFreedBytes {
                freedBanner(freed)
            }
            if let error = viewModel.clearError {
                errorBanner(error)
            }
            Divider().background(Color.haloBorder)

            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2).tint(.haloAccent)
                    Text("Detecting installed browsers…")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.browsers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.haloGreen)
                    Text("No supported browsers detected")
                        .font(HaloFont.display(15, weight: .semibold))
                        .foregroundColor(.haloText)
                    Text("Safari, Chrome, Arc, Brave, Edge, Opera, Vivaldi, and Firefox are supported.")
                        .font(HaloFont.body(13))
                        .foregroundColor(.haloText2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.browsers) { browser in
                            BrowserSummaryCard(browser: browser) {
                                viewModel.reviewTarget = .single(browser.id)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color.haloSurface)
        .sheet(item: $viewModel.reviewTarget) { target in
            BrowserCleanerReviewSheet(viewModel: viewModel, target: target)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browsers")
                    .font(HaloFont.display(15, weight: .semibold))
                    .foregroundColor(.haloText)
                if !viewModel.browsers.isEmpty {
                    Text("\(viewModel.browsers.count) browser\(viewModel.browsers.count == 1 ? "" : "s") · \(viewModel.totalFormatted) clearable")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
            }
            Spacer()
            if viewModel.isLoading {
                ProgressView().scaleEffect(0.6).tint(.haloAccent)
            } else {
                Button {
                    Task { await viewModel.loadAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.haloText2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
            if viewModel.hasAnyData {
                Button {
                    viewModel.reviewTarget = .all
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isClearing {
                            ProgressView().scaleEffect(0.6).tint(.white)
                        } else {
                            Image(systemName: "trash.fill").font(.system(size: 12, weight: .semibold))
                        }
                        Text("Clean All Browsers")
                            .font(HaloFont.body(13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.haloRed.opacity(viewModel.isClearing ? 0.5 : 1))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isClearing)
                .accessibilityIdentifier("browserCleaner.cleanAll.button")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func freedBanner(_ freed: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.haloGreen)
            Text("Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
                .font(HaloFont.body(12, weight: .medium))
                .foregroundColor(.haloText)
            Spacer()
            Button {
                viewModel.lastFreedBytes = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(.haloText2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.haloGreen.opacity(0.08))
        .overlay(Rectangle().fill(Color.haloGreen).frame(height: 1), alignment: .bottom)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.haloAmber)
            Text(error).font(HaloFont.body(12)).foregroundColor(.haloText).lineLimit(2)
            Spacer()
            Button {
                viewModel.clearError = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(.haloText2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.haloAmber.opacity(0.08))
        .overlay(Rectangle().fill(Color.haloAmber).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - Per-Browser Summary Card

struct BrowserSummaryCard: View {
    let browser: BrowserProfile
    let onReview: () -> Void

    private var topCategories: [BrowserCategoryItem] {
        Array(browser.categories.filter(\.hasData).sorted { $0.size > $1.size }.prefix(4))
    }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: browser.icon)
                        .font(.system(size: 16))
                        .foregroundColor(.haloAccent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(browser.name)
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText)
                        Text("\(browser.categories.filter(\.hasData).count) of \(browser.categories.count) categories have data")
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloText3)
                    }
                    Spacer()
                    if browser.hasData {
                        Text(browser.totalFormatted)
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloAmber)
                    } else {
                        HaloBadge(text: "Clean", color: .haloGreen)
                    }
                }

                if !topCategories.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(topCategories) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.category.icon)
                                    .font(.system(size: 10))
                                    .foregroundColor(.haloText3)
                                    .frame(width: 14)
                                Text(item.category.rawValue)
                                    .font(HaloFont.body(11))
                                    .foregroundColor(.haloText2)
                                Spacer()
                                Text(item.sizeFormatted)
                                    .font(HaloFont.body(11))
                                    .foregroundColor(.haloText3)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.haloSurface)
                    .cornerRadius(8)
                }

                HStack {
                    Spacer()
                    Button("Review & Clear", action: onReview)
                        .font(HaloFont.body(12, weight: .semibold))
                        .foregroundColor(.haloAccent)
                        .buttonStyle(.plain)
                        .disabled(!browser.hasData)
                        .opacity(browser.hasData ? 1 : 0.4)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Review Sheet (per-category checklist + confirmation)

struct BrowserCleanerReviewSheet: View {
    @ObservedObject var viewModel: BrowserCleanerViewModel
    let target: BrowserCleanerViewModel.ReviewTarget
    @Environment(\.dismiss) private var dismiss

    private var browsersInScope: [BrowserProfile] {
        switch target {
        case .all: return viewModel.browsers.filter(\.hasData)
        case .single(let id): return viewModel.browsers.filter { $0.id == id }
        }
    }

    private var selectedBytes: Int64 {
        browsersInScope.reduce(0) { $0 + $1.selectedBytes }
    }

    private var hasSelection: Bool {
        browsersInScope.contains { $0.hasAnySelected }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.id == "all" ? "Review & Clear All Browsers" : "Review & Clear Browser Data")
                        .font(HaloFont.display(16, weight: .semibold))
                        .foregroundColor(.haloText)
                    Text("Selected items will be moved to Trash.")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText2)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().background(Color.haloBorder)

            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundColor(.haloAmber)
                Text("Close the affected browser(s) before clearing to avoid data corruption. Clearing cookies signs you out of every site.")
                    .font(HaloFont.body(12)).foregroundColor(.haloText)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.haloAmber.opacity(0.08))

            Divider().background(Color.haloBorder)

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(browsersInScope) { browser in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: browser.icon)
                                    .font(.system(size: 13))
                                    .foregroundColor(.haloText2)
                                Text(browser.name)
                                    .font(HaloFont.body(13, weight: .semibold))
                                    .foregroundColor(.haloText)
                                Spacer()
                                Text(browser.selectedFormatted)
                                    .font(HaloFont.body(12, weight: .medium))
                                    .foregroundColor(.haloAmber)
                            }

                            VStack(spacing: 6) {
                                ForEach(browser.categories.filter(\.hasData)) { item in
                                    CategoryReviewRow(
                                        item: item,
                                        isSelected: item.isSelected
                                    ) {
                                        viewModel.toggleCategory(browserID: browser.id, categoryID: item.id)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.haloSurface2)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
                    }
                }
                .padding(20)
            }

            Divider().background(Color.haloBorder)

            if let err = viewModel.clearError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.haloAmber)
                    Text(err).font(HaloFont.body(12)).foregroundColor(.haloText).lineLimit(2)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.haloAmber.opacity(0.08))
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .font(HaloFont.body(13)).foregroundColor(.haloText2).buttonStyle(.plain)
                Spacer()
                Button {
                    Task { await viewModel.performClear(target) }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isClearing {
                            ProgressView().scaleEffect(0.6).tint(.white)
                        } else {
                            Image(systemName: "trash.fill").font(.system(size: 12))
                        }
                        Text("Clear Selected (\(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)))")
                            .font(HaloFont.body(13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(hasSelection ? Color.haloRed : Color.haloRed.opacity(0.4))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(!hasSelection || viewModel.isClearing)
                .accessibilityIdentifier("browserCleaner.clearSelected.button")
            }
            .padding(20)
        }
        .background(Color.haloSurface)
        .frame(width: 600, height: 560)
    }
}

struct CategoryReviewRow: View {
    let item: BrowserCategoryItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .haloAccent : .haloText3)
            }
            .buttonStyle(.plain)

            Image(systemName: item.category.icon)
                .font(.system(size: 12))
                .foregroundColor(.haloText2)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.category.rawValue)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                Text(item.category.subtitle)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.sizeFormatted)
                .font(HaloFont.body(11, weight: .semibold))
                .foregroundColor(.haloText2)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSelected ? Color.haloAccent.opacity(0.06) : Color.haloSurface)
        .cornerRadius(8)
    }
}
