import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - RAGContextView  (F-047 FR-8 / FR-9 — manage the context set)
//
// Add files or folders, see what is indexed, re-check for changes, and try a search — all
// local. The one switch that matters for privacy is at the top: whether the *cloud* assistant
// may search these files. It is off by default and says plainly what turning it on does.

@MainActor
final class RAGContextViewModel: ObservableObject {
    @Published private(set) var documents: [RAGDocument] = []
    @Published private(set) var chunkCount = 0
    @Published private(set) var isWorking = false
    @Published private(set) var status: String?
    @Published private(set) var problems: [String] = []
    @Published private(set) var indexWasDiscarded = false
    @Published var testQuery = ""
    @Published private(set) var hits: [RAGHit] = []
    @Published private(set) var searched = false

    @Published var assistantMaySearch: Bool = RAGSettings.assistantMaySearch {
        didSet { RAGSettings.assistantMaySearch = assistantMaySearch }
    }

    /// Reported to the assistant so `send()` knows whether the tool should be offered.
    var onChange: (() -> Void)?

    private let service = RAGService.shared

    /// Folders: only files the parsers handle, skipping hidden items, packages and the usual
    /// dependency/build directories (indexing node_modules would drown the real documents).
    nonisolated static let skippedDirectories: Set<String> = ["node_modules", ".git", ".build", "DerivedData", "Pods", "build", "dist", "Library"]
    nonisolated static let maxFilesPerAdd = 500

    func refresh() async {
        documents = await service.documents()
        chunkCount = await service.chunkCount()
        indexWasDiscarded = await service.indexWasDiscarded()
        onChange?()
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add files to the context set"
        panel.message = "Halo reads these on this Mac and keeps a searchable index. Nothing is uploaded."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentParsers.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a folder to the context set"
        panel.message = "Every readable document inside (up to \(Self.maxFilesPerAdd)) is indexed. Nothing is uploaded."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        add([folder])
    }

    func add(_ urls: [URL]) {
        guard !isWorking else { return }
        let targets = urls.flatMap(Self.expand)
        guard !targets.isEmpty else {
            status = "Nothing readable there — Halo reads text, Markdown, CSV, code, PDF, Word, RTF and HTML."
            return
        }
        isWorking = true
        problems = []
        Task {
            var added = 0, unchanged = 0
            for (i, url) in targets.enumerated() {
                status = "Indexing \(i + 1) of \(targets.count): \(url.lastPathComponent)…"
                do {
                    switch try await service.index(url: url) {
                    case .indexed:   added += 1
                    case .unchanged: unchanged += 1
                    }
                } catch {
                    problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            await refresh()
            status = "Indexed \(added) file\(added == 1 ? "" : "s")" + (unchanged > 0 ? ", \(unchanged) already up to date" : "")
                + (problems.isEmpty ? "." : ", \(problems.count) skipped.")
            isWorking = false
        }
    }

    func recheck() {
        guard !isWorking else { return }
        isWorking = true; problems = []; status = "Checking for changes…"
        Task {
            let s = await service.reindexChangedDocuments()
            problems = s.failed + s.missing.map { "\($0): the file is no longer where it was" }
            await refresh()
            status = "\(s.reindexed) updated, \(s.unchanged) unchanged" + (s.missing.isEmpty ? "." : ", \(s.missing.count) missing.")
            isWorking = false
        }
    }

    func remove(_ doc: RAGDocument) {
        Task { try? await service.remove(documentId: doc.id); await refresh(); hits = []; searched = false }
    }

    func clearAll() {
        Task { await service.clear(); await refresh(); hits = []; searched = false; status = "Context set cleared. Your files were not touched." }
    }

    func runTestSearch() {
        let q = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task { hits = await service.search(q, k: 5); searched = true }
    }

    /// A dropped/chosen URL becomes itself (a file) or the supported files beneath it (a folder).
    nonisolated static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return DocumentParsers.parser(forExtension: url.pathExtension) == nil ? [] : [url] }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }      // never follow links out of the folder
            if values?.isDirectory == true {
                if skippedDirectories.contains(item.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            if DocumentParsers.parser(forExtension: item.pathExtension) != nil { out.append(item) }
            if out.count >= maxFilesPerAdd { break }
        }
        return out
    }
}

struct RAGContextView: View {
    @StateObject private var vm = RAGContextViewModel()
    @Environment(\.dismiss) private var dismiss
    var onChange: () -> Void = {}
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                privacyCard
                filesCard
                searchCard
            }
            .padding(24)
        }
        .frame(width: 560, height: 640)
        .background(Color.haloSurface)
        .task { vm.onChange = onChange; await vm.refresh() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in vm.add([url]) } }
                }
            }
            return true
        }
        .confirmationDialog("Clear the context set?", isPresented: $confirmClear) {
            Button("Clear index", role: .destructive) { vm.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Halo's searchable index only. Your files are not touched.")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass").foregroundColor(.haloPurple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Context files").font(HaloFont.display(20, weight: .bold)).foregroundColor(.haloText)
                Text("Searchable on this Mac. Drop files or folders anywhere on this sheet.")
                    .font(HaloFont.body(11)).foregroundColor(.haloText2)
            }
            Spacer()
            HaloPrimaryButton("Done", icon: "checkmark") { dismiss() }
        }
    }

    private var privacyCard: some View {
        HaloCard(accentTop: vm.assistantMaySearch ? .haloAmber : .haloGreen) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $vm.assistantMaySearch) {
                    Text("Let the assistant search these files").font(HaloFont.body(13)).foregroundColor(.haloText)
                }
                .toggleStyle(.switch).tint(.haloAccent)
                .accessibilityIdentifier("rag.assistantToggle")
                if vm.assistantMaySearch {
                    Label("When the assistant searches, the matching excerpts of your files are sent to your AI provider as part of the conversation.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(HaloFont.body(11)).foregroundColor(.haloAmber)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Off: your files stay on this Mac. Indexing and the search box below never leave it.",
                          systemImage: "lock.fill")
                        .font(HaloFont.body(11)).foregroundColor(.haloText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var filesCard: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(vm.documents.count) file\(vm.documents.count == 1 ? "" : "s") · \(vm.chunkCount) passages")
                        .font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
                    Spacer()
                    HaloGhostButton("Add files", icon: "doc.badge.plus") { vm.chooseFiles() }.disabled(vm.isWorking)
                    HaloGhostButton("Add folder", icon: "folder.badge.plus") { vm.chooseFolder() }.disabled(vm.isWorking)
                    HaloGhostButton("Re-check", icon: "arrow.clockwise") { vm.recheck() }
                        .disabled(vm.isWorking || vm.documents.isEmpty)
                }
                if vm.indexWasDiscarded {
                    Text("The saved index was built with a different text model (or was damaged), so it was set aside. Add your files again to rebuild it.")
                        .font(HaloFont.body(11)).foregroundColor(.haloAmber).fixedSize(horizontal: false, vertical: true)
                }
                if let status = vm.status {
                    HStack(spacing: 6) {
                        if vm.isWorking { ProgressView().controlSize(.small) }
                        Text(status).font(HaloFont.body(11)).foregroundColor(.haloText2)
                    }
                }
                ForEach(vm.problems, id: \.self) { p in
                    Text(p).font(HaloFont.body(10)).foregroundColor(.haloRed).fixedSize(horizontal: false, vertical: true)
                }
                if vm.documents.isEmpty && !vm.isWorking {
                    Text("Nothing here yet. Halo reads text, Markdown, CSV, source code, PDF, Word, RTF and HTML.")
                        .font(HaloFont.body(11)).foregroundColor(.haloText2).padding(.vertical, 6)
                }
                ForEach(vm.documents) { doc in
                    HStack {
                        Image(systemName: icon(for: doc.fileExtension)).foregroundColor(.haloAccent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(doc.name).font(HaloFont.body(12)).foregroundColor(.haloText).lineLimit(1)
                            Text("\(doc.chunkCount) passages · \(ByteCountFormatter.string(fromByteCount: doc.byteCount, countStyle: .file))")
                                .font(HaloFont.body(10)).foregroundColor(.haloText2)
                        }
                        Spacer()
                        Button { vm.remove(doc) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundColor(.haloText2).help("Remove from the context set")
                    }
                }
                if !vm.documents.isEmpty {
                    HStack { Spacer(); HaloGhostButton("Clear index", icon: "trash") { confirmClear = true } }
                }
            }
        }
    }

    private var searchCard: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Try a search").font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
                HStack {
                    TextField("e.g. what did the contract say about renewal?", text: $vm.testQuery)
                        .textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                        .padding(8).background(Color.haloSurface2).cornerRadius(7)
                        .onSubmit { vm.runTestSearch() }
                        .accessibilityIdentifier("rag.testQuery")
                    HaloPrimaryButton("Search", icon: "magnifyingglass") { vm.runTestSearch() }
                        .disabled(vm.testQuery.trimmingCharacters(in: .whitespaces).isEmpty || vm.documents.isEmpty)
                }
                if vm.searched && vm.hits.isEmpty {
                    Text("No matching passages.").font(HaloFont.body(11)).foregroundColor(.haloText2)
                }
                ForEach(Array(vm.hits.enumerated()), id: \.element.id) { i, hit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("[\(i + 1)] \(hit.citation)").font(HaloFont.body(11, weight: .semibold)).foregroundColor(.haloAccent)
                            Spacer()
                            Text(String(format: "%.2f", hit.score)).font(HaloFont.body(10)).foregroundColor(.haloText2)
                        }
                        Text(hit.chunk.text.count > 280 ? String(hit.chunk.text.prefix(280)) + "…" : hit.chunk.text)
                            .font(HaloFont.body(11)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8).background(Color.haloSurface2).cornerRadius(7)
                }
            }
        }
    }

    private func icon(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "csv", "tsv": return "tablecells"
        case "docx", "doc", "odt", "rtf": return "doc.text"
        case "html", "htm": return "globe"
        case "md", "markdown", "txt", "text", "log": return "text.alignleft"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
