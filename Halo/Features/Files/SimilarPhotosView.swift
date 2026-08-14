import SwiftUI
import AppKit
import ImageIO
import Photos

// MARK: - Similar Photos (F-025 · Duplicate Photos Finder, perceptual hash)
//
// Near-duplicate finder for loose image files (fully tested via compilation +
// algorithm sanity checks) plus an experimental Photos Library scan (real
// PhotoKit code, but NOT runtime-tested this session — see PR notes).

struct SimilarPhotosView: View {
    @StateObject private var viewModel = SimilarPhotosViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.haloBorder)
            content
        }
        .background(Color.haloSurface)
        .onAppear { viewModel.loadPhotosAuthorizationStatus() }
        .alert("Could not access Photos Library", isPresented: Binding(
            get: { viewModel.photosLibraryError != nil },
            set: { if !$0 { viewModel.photosLibraryError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.photosLibraryError = nil }
        } message: {
            Text(viewModel.photosLibraryError ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Similar Photos")
                        .font(HaloFont.display(18, weight: .bold))
                        .foregroundColor(.haloText)
                    if !viewModel.groups.isEmpty {
                        Text("\(viewModel.groups.count) clusters · \(ByteCountFormatter.string(fromByteCount: viewModel.totalWastedBytes, countStyle: .file)) reclaimable")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                    } else {
                        Text("Finds photos that look alike even when their files differ — different exports, crops, or compression of the same shot.")
                            .font(HaloFont.body(12))
                            .foregroundColor(.haloText2)
                    }
                }
                Spacer()
                HaloGhostButton("Choose Folder", icon: "folder") { viewModel.chooseFolderAndScan() }
                    .disabled(viewModel.isScanning)
                HaloPrimaryButton(viewModel.isScanning ? "Scanning…" : "Scan Pictures",
                                  icon: "photo.on.rectangle.angled", isLoading: viewModel.isScanning) {
                    viewModel.scanDefaultLocations()
                }
                .accessibilityIdentifier("files.similarPhotos.scan.button")
            }

            HStack(spacing: 10) {
                Text("Similarity threshold")
                    .font(HaloFont.body(12))
                    .foregroundColor(.haloText2)
                Stepper(value: $viewModel.hammingThreshold, in: 1...20) {
                    Text("≤ \(viewModel.hammingThreshold) bits different")
                        .font(HaloFont.body(12, weight: .medium))
                        .foregroundColor(.haloText)
                }
                .fixedSize()
                .disabled(viewModel.isScanning)
                Text("Lower = stricter match, higher = catches more but risks false positives")
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                Spacer()
            }

            if viewModel.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: viewModel.progress)
                    if let location = viewModel.scannedLocation {
                        Text("Scanning \(location)…")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText3)
                    }
                }
            }

            photosLibrarySection
        }
        .padding(20)
    }

    // Experimental Photos Library scan — clearly separated so it reads as an
    // opt-in extra, not a required step.
    private var photosLibrarySection: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 12))
                .foregroundColor(.haloAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Photos Library scan (experimental)")
                    .font(HaloFont.body(11, weight: .semibold))
                    .foregroundColor(.haloText)
                Text("Requires Photos permission. Not yet verified end-to-end — try it and report issues.")
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
            }
            Spacer()
            if viewModel.isScanningPhotosLibrary {
                ProgressView().scaleEffect(0.6)
            } else {
                HaloGhostButton(photosLibraryButtonTitle, icon: "photo.badge.plus") {
                    viewModel.requestPhotosAccessAndScan()
                }
                .accessibilityIdentifier("files.similarPhotos.scanLibrary.button")
            }
        }
        .padding(10)
        .background(Color.haloSurface2)
        .cornerRadius(9)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.haloBorder, lineWidth: 1))
    }

    private var photosLibraryButtonTitle: String {
        switch viewModel.photosAuthorizationStatus {
        case .authorized, .limited: return "Scan Photos Library"
        case .denied, .restricted: return "Permission Denied"
        default: return "Grant Access & Scan"
        }
    }

    private var content: some View {
        Group {
            if viewModel.groups.isEmpty && viewModel.photoAssetGroups.isEmpty && !viewModel.isScanning {
                SimilarPhotosEmptyState()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !viewModel.groups.isEmpty {
                            ForEach(viewModel.groups) { group in
                                PhotoSimilarGroupCard(viewModel: viewModel, group: group)
                            }
                        }
                        if !viewModel.photoAssetGroups.isEmpty {
                            HaloSectionHeader(title: "Photos Library", subtitle: "Experimental — not runtime-tested this session")
                                .padding(.horizontal, 4)
                            ForEach(viewModel.photoAssetGroups) { group in
                                PhotoAssetSimilarGroupCard(viewModel: viewModel, group: group)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class SimilarPhotosViewModel: ObservableObject {
    @Published var groups: [PhotoSimilarGroup] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var scanError: String?
    @Published var scannedLocation: String?
    @Published var hammingThreshold: Int = 8

    // Photos Library path — experimental / stretch goal, see PR notes.
    @Published var photosAuthorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var photoAssetGroups: [PhotoAssetSimilarGroup] = []
    @Published var isScanningPhotosLibrary = false
    @Published var photosLibraryError: String?

    private let detector = PerceptualDuplicateDetector()
    private var scanTask: Task<Void, Never>?
    private var photosLibraryTask: Task<Void, Never>?

    var totalWastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    /// Scan the folders where near-duplicate photos actually accumulate:
    /// exports/screenshots in Pictures & Downloads, and Desktop screenshots.
    func scanDefaultLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = ["Pictures", "Downloads", "Desktop"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        start(scanning: dirs, label: "Pictures, Downloads, Desktop")
    }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan for similar photos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(scanning: [url], label: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }

    private func start(scanning dirs: [URL], label: String) {
        scanTask?.cancel()
        isScanning = true
        progress = 0
        scanError = nil
        groups = []
        scannedLocation = label
        let detector = self.detector
        let threshold = hammingThreshold
        scanTask = Task { [weak self] in
            let files = Self.enumerateImageFiles(in: dirs)
            do {
                let found = try await detector.detect(in: files, hammingThreshold: threshold) { p in
                    Task { @MainActor in self?.progress = p }
                }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.groups = found
                    self.isScanning = false
                }
            } catch is CancellationError {
                await MainActor.run { self?.isScanning = false }
            } catch {
                await MainActor.run {
                    self?.scanError = error.localizedDescription
                    self?.isScanning = false
                }
            }
        }
    }

    /// Enumerate image files under the given directories, bounded so an
    /// accidental huge scan can't run away — mirrors `DuplicateFinderViewModel`.
    private static func enumerateImageFiles(in dirs: [URL], cap: Int = 20_000) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for dir in dirs {
            guard fm.fileExists(atPath: dir.path),
                  let en = fm.enumerator(at: dir,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let url = en.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                   PerceptualDuplicateDetector.imageExtensions.contains(url.pathExtension.lowercased()) {
                    out.append(url)
                    if out.count >= cap { return out }
                }
            }
        }
        return out
    }

    func toggleMark(groupID: PhotoSimilarGroup.ID, itemID: PhotoHashItem.ID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }),
              let ii = groups[gi].items.firstIndex(where: { $0.id == itemID }) else { return }
        groups[gi].items[ii].isMarkedForDeletion.toggle()
    }

    /// Trash every marked copy in a group (mandatory: only ever `trashItem`).
    func deleteMarked(in groupID: PhotoSimilarGroup.ID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        for item in groups[gi].items where item.isMarkedForDeletion {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        groups[gi].items.removeAll { $0.isMarkedForDeletion }
        if groups[gi].items.count <= 1 { groups.remove(at: gi) }
    }

    // MARK: - Photos Library (experimental, stretch goal — see PR notes)

    func loadPhotosAuthorizationStatus() {
        photosAuthorizationStatus = PerceptualDuplicateDetector.photosLibraryAuthorizationStatus
    }

    func requestPhotosAccessAndScan() {
        photosLibraryTask?.cancel()
        photosLibraryTask = Task { [weak self] in
            let status = await PerceptualDuplicateDetector.requestPhotosLibraryAuthorization()
            await MainActor.run { self?.photosAuthorizationStatus = status }
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    self?.photosLibraryError = "Photos Library access was not granted. You can enable it later in System Settings > Privacy & Security > Photos."
                }
                return
            }
            await self?.scanPhotosLibrary()
        }
    }

    func scanPhotosLibrary() async {
        isScanningPhotosLibrary = true
        photosLibraryError = nil
        photoAssetGroups = []
        let threshold = hammingThreshold
        do {
            let found = try await detector.detectInPhotosLibrary(hammingThreshold: threshold) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
            photoAssetGroups = found
            isScanningPhotosLibrary = false
        } catch {
            photosLibraryError = error.localizedDescription
            isScanningPhotosLibrary = false
        }
    }

    func toggleAssetMark(groupID: PhotoAssetSimilarGroup.ID, itemID: PhotoAssetHashItem.ID) {
        guard let gi = photoAssetGroups.firstIndex(where: { $0.id == groupID }),
              let ii = photoAssetGroups[gi].items.firstIndex(where: { $0.id == itemID }) else { return }
        photoAssetGroups[gi].items[ii].isMarkedForDeletion.toggle()
    }

    /// Sends marked assets to Photos' "Recently Deleted" via `PHAssetChangeRequest`
    /// — the PhotoKit equivalent of `trashItem` (recoverable, not permanent).
    func deleteMarkedAssets(in groupID: PhotoAssetSimilarGroup.ID) {
        guard let gi = photoAssetGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let idsToDelete = photoAssetGroups[gi].items.filter(\.isMarkedForDeletion).map(\.localIdentifier)
        guard !idsToDelete.isEmpty else { return }
        let detector = self.detector
        Task { [weak self] in
            do {
                try await detector.deletePhotosLibraryAssets(localIdentifiers: idsToDelete)
                await MainActor.run {
                    guard let self, let gi2 = self.photoAssetGroups.firstIndex(where: { $0.id == groupID }) else { return }
                    self.photoAssetGroups[gi2].items.removeAll { $0.isMarkedForDeletion }
                    if self.photoAssetGroups[gi2].items.count <= 1 { self.photoAssetGroups.remove(at: gi2) }
                }
            } catch {
                await MainActor.run { self?.photosLibraryError = error.localizedDescription }
            }
        }
    }
}

// MARK: - Loose-file group card

struct PhotoSimilarGroupCard: View {
    @ObservedObject var viewModel: SimilarPhotosViewModel
    let group: PhotoSimilarGroup
    @State private var showDeleteConfirm = false

    private var markedCount: Int { group.items.filter(\.isMarkedForDeletion).count }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HaloBadge(text: "\(group.items.count) similar", color: .haloAmber)
                    Text(group.wastedFormatted + " reclaimable")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    Spacer()
                    HaloGhostButton("Delete marked\(markedCount > 0 ? " (\(markedCount))" : "")") {
                        showDeleteConfirm = true            // ask first
                    }
                    .disabled(markedCount == 0)
                    .accessibilityIdentifier("files.similarPhotos.deleteMarked.button")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(group.items) { item in
                        PhotoItemTile(item: item) {
                            viewModel.toggleMark(groupID: group.id, itemID: item.id)
                        }
                    }
                }
            }
            .padding(14)
        }
        // Mandatory confirmation before trashing marked copies (TC-SAFE-02).
        .confirmationDialog(
            "Move \(markedCount) marked \(markedCount == 1 ? "photo" : "photos") to Trash?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                viewModel.deleteMarked(in: group.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct PhotoItemTile: View {
    let item: PhotoHashItem
    let onToggle: () -> Void

    private var borderColor: Color {
        if item.isMarkedForDeletion { return .haloRed }
        if item.isRecommendedKeep { return .haloGreen }
        return .haloBorder
    }

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    PhotoThumbnailView(url: item.url)
                        .frame(height: 96)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(borderColor, lineWidth: item.isMarkedForDeletion || item.isRecommendedKeep ? 2 : 1)
                        )
                    if item.isRecommendedKeep {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.haloGreen))
                            .padding(4)
                    } else if item.isMarkedForDeletion {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.haloRed))
                            .padding(4)
                    }
                }
                Text(item.name)
                    .font(HaloFont.body(10, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.resolutionFormatted) · \(item.sizeFormatted)")
                    .font(HaloFont.body(9))
                    .foregroundColor(.haloText2)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Fast ImageIO-thumbnail loader — same technique the detector uses for
/// hashing, reused here purely for display so the grid stays responsive
/// even with hundreds of full-resolution originals on disk.
struct PhotoThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.haloSurface)
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        .task(id: url) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let target = url
        let img = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(target as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgThumbnail, size: NSSize(width: cgThumbnail.width, height: cgThumbnail.height))
        }.value
        await MainActor.run { self.image = img }
    }
}

// MARK: - Photos Library group card (experimental — see PR notes)

struct PhotoAssetSimilarGroupCard: View {
    @ObservedObject var viewModel: SimilarPhotosViewModel
    let group: PhotoAssetSimilarGroup
    @State private var showDeleteConfirm = false

    private var markedCount: Int { group.items.filter(\.isMarkedForDeletion).count }

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HaloBadge(text: "\(group.items.count) similar", color: .haloAccent)
                    Spacer()
                    HaloGhostButton("Delete marked\(markedCount > 0 ? " (\(markedCount))" : "")") {
                        showDeleteConfirm = true            // ask first
                    }
                    .disabled(markedCount == 0)
                    .accessibilityIdentifier("files.similarPhotos.deleteMarkedAssets.button")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(group.items) { item in
                        PhotoAssetItemTile(item: item) {
                            viewModel.toggleAssetMark(groupID: group.id, itemID: item.id)
                        }
                    }
                }
            }
            .padding(14)
        }
        // Mandatory confirmation before removing marked assets (TC-SAFE-02) —
        // this moves them to Photos' "Recently Deleted", not a permanent delete.
        .confirmationDialog(
            "Move \(markedCount) marked \(markedCount == 1 ? "photo" : "photos") to Recently Deleted?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) {
                viewModel.deleteMarkedAssets(in: group.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct PhotoAssetItemTile: View {
    let item: PhotoAssetHashItem
    let onToggle: () -> Void

    private var borderColor: Color {
        if item.isMarkedForDeletion { return .haloRed }
        if item.isRecommendedKeep { return .haloGreen }
        return .haloBorder
    }

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    PhotoAssetThumbnailView(localIdentifier: item.localIdentifier)
                        .frame(height: 96)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(borderColor, lineWidth: item.isMarkedForDeletion || item.isRecommendedKeep ? 2 : 1)
                        )
                    if item.isRecommendedKeep {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.haloGreen))
                            .padding(4)
                    } else if item.isMarkedForDeletion {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.haloRed))
                            .padding(4)
                    }
                }
                Text(item.resolutionFormatted)
                    .font(HaloFont.body(10, weight: .medium))
                    .foregroundColor(.haloText)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Thumbnail via `PHImageManager` — only reachable through the experimental
/// Photos Library path, so this too is untested at runtime this session.
struct PhotoAssetThumbnailView: View {
    let localIdentifier: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.haloSurface)
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        .task(id: localIdentifier) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let identifier = localIdentifier
        let img: NSImage? = await withCheckedContinuation { continuation in
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = fetchResult.firstObject else {
                continuation.resume(returning: nil)
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        await MainActor.run { self.image = img }
    }
}

// MARK: - Empty State

struct SimilarPhotosEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(.haloText3)
            Text("No similar photos scanned yet")
                .font(HaloFont.display(14, weight: .semibold))
                .foregroundColor(.haloText2)
            Text("Tap Scan Pictures to find near-duplicate photos in Pictures, Downloads, and Desktop")
                .font(HaloFont.body(12))
                .foregroundColor(.haloText3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
