import SwiftUI
import UniformTypeIdentifiers

// MARK: - RosterPanelView

/// Everything that isn't the wheel: the entry list, the draw log, and per-roster
/// settings.
struct RosterPanelView: View {
    @ObservedObject var store: LuckyDrawStore
    @ObservedObject var viewModel: LuckyDrawViewModel
    /// Reported upward so the Space shortcut can stand down while a name is being
    /// typed — otherwise the space bar spins the wheel instead of separating two words.
    @Binding var addFieldIsFocused: Bool
    /// True while a text field *outside* this panel (the roster-rename field) has focus,
    /// so ⌫ edits that text rather than deleting the selected chip.
    var externalFieldActive = false

    @FocusState private var fieldFocus: Bool
    @State private var newEntry = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var confirmReset = false
    @State private var confirmClear = false
    @State private var limitNotice: String?
    @State private var selectedEntryID: UUID?
    @State private var pendingImport: RosterImport.Plan?
    @State private var dropTargeted = false
    @State private var pickerEntryID: UUID?
    @State private var pendingPhotoMatch: AvatarFolderMatcher.Result?

    private var roster: DrawRoster? { store.selected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                entrySection
                drawnSection
                settingsSection
            }
            .padding(16)
        }
        .background(Color.haloBackground)
        .confirmationDialog(duplicateTitle(pendingImport),
                            isPresented: Binding(get: { pendingImport != nil },
                                                 set: { if !$0 { pendingImport = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingImport) { plan in
            // FR-4: never silently merged — two people can share a name.
            Button("Keep both") { finishImport(plan.labels(for: .keepBoth), skipped: 0) }
            Button("Skip duplicates") {
                finishImport(plan.labels(for: .skipDuplicates), skipped: plan.duplicateCount)
            }
            Button("Cancel", role: .cancel) { }
        } message: { plan in
            Text(duplicateMessage(plan))
        }
    }

    // MARK: - Entries

    private var entrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Entries", count: roster?.entries.count ?? 0)

            TextField("Add a name — ⏎, paste a list, or drop a .txt/.csv", text: $newEntry)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.haloText)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.haloSurface2)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .focused($fieldFocus)
                .onSubmit(commitNewEntry)
                .onChange(of: fieldFocus) { addFieldIsFocused = $0 }

            if let limitNotice {
                Text(limitNotice)
                    .font(.system(size: 11))
                    .foregroundColor(.haloAmber)
            }

            if let roster, !roster.entries.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(roster.entries) { entry in
                        entryChip(entry)
                    }
                }
            } else {
                Text("No entries yet. Type a name, or paste a whole list at once.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.haloText3)
            }

            if let roster, !roster.entries.isEmpty {
                Button("Clear all entries") { confirmClear = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.haloText3)
            }
        }
        // FR-3: drop a .txt / .csv on the entries to import it.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.haloAccent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .padding(-6)
                .opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .background(deleteShortcut)
        .confirmationDialog("Remove every entry from this roster?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { store.clearEntries() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The draw log is cleared too. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func entryChip(_ entry: DrawEntry) -> some View {
        if editingID == entry.id {
            TextField("", text: $editingText, onCommit: {
                store.rename(entry, to: editingText)
                editingID = nil
            })
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.haloText)
            .frame(width: 130)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.haloSurface2)
            .overlay(Capsule().stroke(Color.haloAccent, lineWidth: 1))
            .clipShape(Capsule())
        } else {
            HStack(spacing: 6) {
                // F-053: the avatar replaces the colour swatch, and keeps its job — the ring is the
                // same colour as the entry's wheel segment, so list and wheel still read as one object.
                Button { pickerEntryID = entry.id } label: {
                    AvatarView(avatar: entry.avatar, label: entry.label, rosterID: roster?.id,
                               diameter: 22, ringColor: colour(for: entry), dimmed: !entry.isEligible)
                }
                .buttonStyle(.plain)
                .help("Choose an avatar")
                .popover(isPresented: Binding(get: { pickerEntryID == entry.id },
                                              set: { if !$0 { pickerEntryID = nil } })) {
                    AvatarPickerView(store: store, entry: entry, rosterID: roster?.id) { pickerEntryID = nil }
                }
                Text(entry.label)
                    .font(.system(size: 12))
                    .foregroundColor(entry.isEligible ? .haloText : .haloText3)
                    .strikethrough(entry.isExcluded)
                    .lineLimit(1)
                    .frame(maxWidth: 128, alignment: .leading)

                if entry.isRetired {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.haloGreen)
                        .help("Already drawn — off the wheel until put back")
                }

                Button {
                    store.setExcluded(!entry.isExcluded, for: entry)
                } label: {
                    Image(systemName: entry.isExcluded ? "arrow.uturn.backward" : "slash.circle")
                        .font(.system(size: 10))
                        .foregroundColor(entry.isExcluded ? .haloAmber : .haloText3)
                }
                .buttonStyle(.plain)
                .help(entry.isExcluded ? "Put back on the wheel" : "Exclude for now — keeps the entry")

                Button {
                    store.removeEntry(entry)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
                .help("Remove from the roster")
            }
            .padding(.leading, 9).padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(Color.haloSurface2)
            .overlay(
                Capsule().stroke(selectedEntryID == entry.id ? Color.haloAccent
                                    : (entry.isExcluded ? Color.haloAmber.opacity(0.35) : Color.haloBorder),
                                 style: StrokeStyle(lineWidth: selectedEntryID == entry.id ? 1.5 : 1,
                                                    dash: entry.isExcluded && selectedEntryID != entry.id ? [3, 2] : []))
            )
            .clipShape(Capsule())
            .opacity(entry.isEligible ? 1 : 0.55)
            // Order matters: the double-tap has to be declared before the single tap or
            // the single tap swallows it.
            .onTapGesture(count: 2) {
                editingText = entry.label
                editingID = entry.id
            }
            // FR-17: a selected chip is what ⌫ removes.
            .onTapGesture { selectedEntryID = entry.id }
            .accessibilityAddTraits(selectedEntryID == entry.id ? .isSelected : [])
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// The chip swatch matches the wheel, so the two views read as one object.
    private func colour(for entry: DrawEntry) -> Color {
        guard let roster else { return .haloAccent }
        let pool = roster.eligible
        if let i = pool.firstIndex(where: { $0.id == entry.id }) {
            return SegmentPalette.rim(for: i, of: pool.count)
        }
        return Color.haloText3
    }

    // MARK: - Already drawn

    private var drawnSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Already drawn", count: roster?.history.count ?? 0)
                Spacer()
                Button {
                    confirmReset = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(store.canReset ? .haloAccent : .haloText3)
                .disabled(!store.canReset)
                // FR-17: ⌘⇧R. It opens the same confirmation as clicking — a shortcut
                // is not a reason to skip "this clears the log".
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Put everyone back on the wheel and clear this log (⌘⇧R)")
            }

            if let roster, !roster.history.isEmpty {
                VStack(spacing: 5) {
                    ForEach(roster.history) { row in
                        drawnRow(row)
                    }
                }
                Button("Export log as CSV") { viewModel.exportHistoryCSV() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.haloText3)
            } else {
                Text("Nobody yet. Winners are logged here — and, while Retire winners is on, taken off the wheel.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.haloText3)
            }
        }
        .confirmationDialog("Reset the draw?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset draw", role: .destructive) { store.resetDraw() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everyone goes back on the wheel and this log is cleared. Entries themselves are untouched.")
        }
    }

    private func drawnRow(_ row: DrawResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.wasReturned ? "arrow.uturn.backward.circle.fill" : "trophy.fill")
                .font(.system(size: 11))
                .foregroundColor(row.wasReturned ? .haloAmber : .haloGreen)

            if let roster, roster.avatarDisplay != .nameOnly {
                // The entry may have been deleted since — the row keeps its label, so it falls back to a monogram.
                let entry = roster.entries.first { $0.id == row.entryID }
                if entry.map({ roster.avatarDisplay.showsAvatar(for: $0) }) ?? (roster.avatarDisplay != .auto) {
                    AvatarView(avatar: entry?.avatar, label: row.label, rosterID: roster.id, diameter: 24,
                               ringColor: .haloAmber, dimmed: row.wasReturned)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(row.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.haloText)
                    .lineLimit(1)
                Text(row.wasReturned ? "Back on the wheel" : row.drawnAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(row.wasReturned ? .haloAmber : .haloText3)
            }

            Spacer(minLength: 4)

            if !row.wasReturned {
                Button("Put back") { store.putBack(row) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.haloAccent)
                    .help("Return to the wheel for the next draw — this row stays")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.haloSurface2.opacity(row.wasReturned ? 0.5 : 1))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(row.wasReturned ? Color.haloAmber.opacity(0.2) : Color.haloGreen.opacity(0.22),
                    lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.haloBorder)

            Toggle(isOn: Binding(
                get: { roster?.autoRetireWinner ?? true },
                set: { store.setAutoRetire($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Retire winners").font(.system(size: 12)).foregroundColor(.haloText)
                    Text("Takes the winner off the wheel so the round can't repeat")
                        .font(.system(size: 10)).foregroundColor(.haloText3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .tint(.haloAccent)

            Toggle(isOn: Binding(
                get: { roster?.soundEnabled ?? false },
                set: { store.setSoundEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sound").font(.system(size: 12)).foregroundColor(.haloText)
                    Text("A soft tick as the wheel turns and a chime for the winner. Off by default")
                        .font(.system(size: 10)).foregroundColor(.haloText3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .tint(.haloAccent)

            VStack(alignment: .leading, spacing: 6) {
                Text("AVATARS ON THE WHEEL")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundColor(.haloText3)
                Picker("", selection: Binding(
                    get: { roster?.avatarDisplay ?? .auto },
                    set: { store.setAvatarDisplay($0) }
                )) {
                    ForEach(AvatarDisplayMode.allCases) { m in Text(m.title).tag(m) }
                }
                .labelsHidden()
                Text("Automatic shows an avatar only where you've chosen one. Above \(SpinnerWheelView.avatarLimit) entries the wheel stays plain; the winner card still shows the avatar.")
                    .font(.system(size: 10)).foregroundColor(.haloText3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Import photos from a folder…") { chooseFolderForPhotos() }
                    Button("Clear all photos") { store.clearAllPhotos(); AvatarImageCache.shared.forget(rosterID: roster?.id ?? UUID()) }
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.haloAccent)
                Text("Photos stay on this Mac, as small copies, and are deleted with the roster.")
                    .font(.system(size: 10)).foregroundColor(.haloText3)
            }
            .confirmationDialog(photoMatchTitle(pendingPhotoMatch),
                                isPresented: Binding(get: { pendingPhotoMatch != nil },
                                                     set: { if !$0 { pendingPhotoMatch = nil } }),
                                titleVisibility: .visible, presenting: pendingPhotoMatch) { match in
                if !match.matches.isEmpty {
                    Button("Add \(match.matches.count) photo\(match.matches.count == 1 ? "" : "s")") { applyPhotoMatch(match) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { match in
                Text(photoMatchMessage(match))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SPIN DURATION")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundColor(.haloText3)
                Picker("", selection: Binding(
                    get: { roster?.spinDuration ?? .standard },
                    set: { store.setSpinDuration($0) }
                )) {
                    ForEach(SpinDuration.allCases) { d in
                        Text(d.title).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(.haloText3)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.haloText2)
        }
    }

    private func commitNewEntry() {
        let raw = newEntry
        newEntry = ""
        beginImport(RosterImport.labels(fromPasted: raw))
    }

    // MARK: - Photo import from a folder (F-053 FR-B1)

    private func chooseFolderForPhotos() {
        guard let roster else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of pictures named after the entries (for example “Anna Maria.jpg”)"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        pendingPhotoMatch = AvatarFolderMatcher.match(files: files, entries: roster.entries)
    }

    private func photoMatchTitle(_ m: AvatarFolderMatcher.Result?) -> String {
        guard let m else { return "Photos" }
        return m.matches.isEmpty ? "No photos matched" : "Matched \(m.matches.count) photo\(m.matches.count == 1 ? "" : "s")"
    }

    private func photoMatchMessage(_ m: AvatarFolderMatcher.Result) -> String {
        var parts = ["\(m.unmatchedFiles.count) picture\(m.unmatchedFiles.count == 1 ? "" : "s") didn't match a name.",
                     "\(m.entriesWithoutPhoto.count) entr\(m.entriesWithoutPhoto.count == 1 ? "y" : "ies") still without a photo."]
        if !m.ambiguousLabels.isEmpty {
            parts.append("Shared names were skipped: \(m.ambiguousLabels.prefix(4).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    private func applyPhotoMatch(_ match: AvatarFolderMatcher.Result) {
        Task {
            let r = await store.applyPhotoMatches(match.matches)
            limitNotice = r.failed == 0 ? "Added \(r.applied) photo\(r.applied == 1 ? "" : "s")."
                                        : "Added \(r.applied); \(r.failed) couldn't be used."
        }
    }

    // MARK: - Import (FR-2, FR-3, FR-4)

    /// Classifies first, adds second. Anything that duplicates a name already there — or
    /// repeats within the batch — raises the Keep both / Skip prompt instead of being
    /// merged or added blindly.
    private func beginImport(_ labels: [String]) {
        guard !labels.isEmpty else { return }
        let plan = store.prepareImport(labels)
        if plan.hasDuplicates {
            pendingImport = plan
        } else {
            finishImport(labels, skipped: 0)
        }
    }

    private func finishImport(_ labels: [String], skipped: Int) {
        let requested = labels.count
        let added = store.commitImport(labels)
        var notes: [String] = []
        if added < requested {
            notes.append("Roster is full at \(DrawRoster.entryCap) entries — \(requested - added) not added.")
        }
        if skipped > 0 {
            notes.append("Skipped \(skipped) duplicate\(skipped == 1 ? "" : "s").")
        }
        limitNotice = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private func duplicateTitle(_ plan: RosterImport.Plan?) -> String {
        guard let plan else { return "Duplicate names" }
        return plan.duplicateCount == 1 ? "1 name is already on the roster"
                                        : "\(plan.duplicateCount) names are already on the roster"
    }

    private func duplicateMessage(_ plan: RosterImport.Plan) -> String {
        let shown = plan.duplicateLabels.prefix(5).joined(separator: ", ")
        let more = plan.duplicateCount > 5 ? " and \(plan.duplicateCount - 5) more" : ""
        return "\(shown)\(more). Two people can share a name, so you choose: keep both, or skip the repeats."
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = item as? URL }
            guard let url else { return }
            let result = Result { try RosterImport.read(fileAt: url) }
            DispatchQueue.main.async {
                switch result {
                case .success(let labels):
                    if labels.isEmpty { limitNotice = "No names found in \(url.lastPathComponent)." }
                    else { beginImport(labels) }
                case .failure(let error):
                    limitNotice = Self.message(for: error)
                }
            }
        }
        return true
    }

    private static func message(for error: Error) -> String {
        switch error as? RosterImport.ReadError {
        case .unsupportedType: return "Only .txt and .csv files can be dropped here."
        case .tooLarge:        return "That file is over 1 MB — too big for a name list."
        default:               return "Couldn't read that file."
        }
    }

    // MARK: - Keyboard (FR-17)

    private var selectedEntry: DrawEntry? {
        guard let id = selectedEntryID else { return nil }
        return roster?.entries.first { $0.id == id }
    }

    /// ⌫ removes the selected chip — but never while any text is being typed, where
    /// Backspace has to keep meaning "delete a character".
    private var canDeleteSelected: Bool {
        selectedEntry != nil && !fieldFocus && editingID == nil && !externalFieldActive
    }

    private var deleteShortcut: some View {
        Button("Remove selected entry") {
            if let entry = selectedEntry {
                store.removeEntry(entry)
                selectedEntryID = nil
            }
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(!canDeleteSelected)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - FlowLayout

/// Wrapping chip layout. `LazyVGrid` can't do variable-width cells and an `HStack`
/// won't wrap, so this is the small amount of `Layout` the chip rail needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
