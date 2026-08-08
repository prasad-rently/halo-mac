import SwiftUI

// MARK: - SnippetListSection

/// Standalone snippet management view shown as a tab in ClipboardView or as a section.
struct SnippetListSection: View {
    @ObservedObject var manager: SnippetManager
    @State private var searchText = ""
    @State private var showEditor = false
    @State private var editingSnippet: TextSnippet?
    @State private var selectedCategory: String? = nil
    @State private var statusMessage: String?

    // Import/export
    @State private var showImportPicker = false
    @State private var showExportSave = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snippets")
                        .font(HaloFont.display(20, weight: .bold))
                        .foregroundColor(.haloText)
                    Text("\(manager.snippets.count) snippets · \(manager.categories.count) categories")
                        .font(HaloFont.body(12))
                        .foregroundColor(.haloText3)
                }
                Spacer()

                // Import button
                Menu {
                    Button("Import from JSON…") { showImportPicker = true }
                    Button("Export All to JSON…") { exportJSON() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13))
                        .foregroundColor(.haloText2)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)

                // New snippet button
                Button {
                    editingSnippet = nil
                    showEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(HaloFont.body(12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.haloAccent)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.haloText3)
                TextField("Search snippets…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(HaloFont.body(13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.haloText3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.haloSurface2)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Status message
            if let msg = statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.haloGreen)
                        .font(.system(size: 11))
                    Text(msg)
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                    Spacer()
                }
                .padding(10)
                .background(Color.haloGreen.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .transition(.opacity)
            }

            // Category filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    CategoryChip(label: "All", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(manager.categories, id: \.self) { cat in
                        CategoryChip(label: cat, isSelected: selectedCategory == cat) {
                            selectedCategory = selectedCategory == cat ? nil : cat
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 12)

            Divider().background(Color.haloBorder)

            // Snippet list
            ScrollView {
                let results = filteredSnippets
                if results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.cursor")
                            .font(.system(size: 28))
                            .foregroundColor(.haloText3)
                        Text(searchText.isEmpty ? "No snippets yet" : "No matches")
                            .font(HaloFont.body(13, weight: .medium))
                            .foregroundColor(.haloText2)
                        if searchText.isEmpty {
                            Text("Click + New to create your first snippet")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText3)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { snippet in
                            SnippetRow(snippet: snippet, manager: manager, onEdit: {
                                editingSnippet = snippet
                                showEditor = true
                            }, onCopy: {
                                copySnippet(snippet)
                            })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.haloSurface)
        .sheet(isPresented: $showEditor) {
            SnippetEditorView(manager: manager, editing: editingSnippet)
        }
        .fileImporter(isPresented: $showImportPicker,
                      allowedContentTypes: [.json, .commaSeparatedText]) { result in
            if case .success(let url) = result {
                if url.pathExtension == "csv" {
                    manager.importFromCSV(url: url)
                } else if let data = try? Data(contentsOf: url) {
                    manager.importFromJSON(data: data)
                }
                statusMessage = "Snippets imported"
                clearStatusAfterDelay()
            }
        }
    }

    private var filteredSnippets: [TextSnippet] {
        var results = manager.search(searchText)
        if let cat = selectedCategory {
            results = results.filter { $0.category == cat }
        }
        return results
    }

    private func copySnippet(_ snippet: TextSnippet) {
        let expanded = snippet.expanded()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(expanded, forType: .string)
        manager.recordUsage(snippet)
        statusMessage = "Copied: \(snippet.name)"
        clearStatusAfterDelay()
    }

    private func exportJSON() {
        guard let data = manager.exportToJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "halo-snippets.json"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? data.write(to: url)
                DispatchQueue.main.async {
                    statusMessage = "Exported \(manager.snippets.count) snippets"
                    clearStatusAfterDelay()
                }
            }
        }
    }

    private func clearStatusAfterDelay() {
        let msg = statusMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if statusMessage == msg { statusMessage = nil }
        }
    }
}

// MARK: - Category Chip

private struct CategoryChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(HaloFont.body(11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .haloText : .haloText3)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.haloAccent.opacity(0.15) : Color.haloSurface2)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.haloAccent.opacity(0.3) : Color.haloBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Snippet Row

private struct SnippetRow: View {
    let snippet: TextSnippet
    @ObservedObject var manager: SnippetManager
    let onEdit: () -> Void
    let onCopy: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Trigger badge
            Text(snippet.trigger)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.haloAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.haloAccent.opacity(0.1))
                .cornerRadius(5)
                .frame(width: 80, alignment: .leading)

            // Name + preview
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                    .font(HaloFont.body(12, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                Text(snippet.body)
                    .font(HaloFont.body(10))
                    .foregroundColor(.haloText3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Category tag
            Text(snippet.category)
                .font(HaloFont.body(9))
                .foregroundColor(.haloText3)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.haloSurface2)
                .cornerRadius(4)

            // Usage count
            if snippet.usageCount > 0 {
                Text("\(snippet.usageCount)×")
                    .font(HaloFont.mono(10))
                    .foregroundColor(.haloText3)
            }

            // Actions
            HStack(spacing: 6) {
                Button { onCopy() } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12))
                        .foregroundColor(.haloAccent)
                }
                .buttonStyle(.plain)
                .help("Copy expanded snippet")

                Menu {
                    Button("Copy") { onCopy() }
                    Button("Edit…") { onEdit() }
                    Button("Duplicate") { manager.duplicate(snippet) }
                    Divider()
                    Button("Delete", role: .destructive) { manager.delete(snippet) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.haloText3)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.haloAccent.opacity(0.04) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
    }
}
