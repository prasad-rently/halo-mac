import SwiftUI

// MARK: - RosterPanelView

/// Everything that isn't the wheel: the entry list, the draw log, and per-roster
/// settings.
struct RosterPanelView: View {
    @ObservedObject var store: LuckyDrawStore
    @ObservedObject var viewModel: LuckyDrawViewModel
    /// Reported upward so the Space shortcut can stand down while a name is being
    /// typed — otherwise the space bar spins the wheel instead of separating two words.
    @Binding var addFieldIsFocused: Bool

    @FocusState private var fieldFocus: Bool
    @State private var newEntry = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var confirmReset = false
    @State private var confirmClear = false
    @State private var limitNotice: String?

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
    }

    // MARK: - Entries

    private var entrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Entries", count: roster?.entries.count ?? 0)

            TextField("Add a name — ⏎, or paste a list", text: $newEntry)
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
                RoundedRectangle(cornerRadius: 2)
                    .fill(colour(for: entry))
                    .frame(width: 8, height: 8)
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
                Capsule().stroke(entry.isExcluded ? Color.haloAmber.opacity(0.35) : Color.haloBorder,
                                 style: StrokeStyle(lineWidth: 1,
                                                    dash: entry.isExcluded ? [3, 2] : []))
            )
            .clipShape(Capsule())
            .opacity(entry.isEligible ? 1 : 0.55)
            .onTapGesture(count: 2) {
                editingText = entry.label
                editingID = entry.id
            }
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
                .help("Put everyone back on the wheel and clear this log")
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
            }
            .toggleStyle(.switch)
            .tint(.haloAccent)

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
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let added = store.addEntries(from: raw)
        let requested = raw.contains("\n")
            ? raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            : raw.components(separatedBy: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        limitNotice = added < requested
            ? "Roster is full at \(DrawRoster.entryCap) entries — \(requested - added) not added."
            : nil
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
