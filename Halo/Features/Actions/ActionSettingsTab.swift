import SwiftUI

// MARK: - ActionSettingsTab

/// The "Quick Actions" tab inside Halo's Settings window.
/// Lets users:
///   • Enable / disable individual built-in actions per category
///   • Configure the ⌘⇧A keyboard shortcut
///   • Toggle voice-to-text search
struct ActionSettingsTab: View {

    @EnvironmentObject var appState: AppState
    @ObservedObject private var store   = ActionSettingsStore.shared
    @ObservedObject private var library = ActionLibrary.shared

    @State private var searchText        = ""
    @State private var selectedCategory: ActionCategory? = nil
    @State private var expandedCategories: Set<ActionCategory> = Set(ActionCategory.allCases)

    // Grouped built-in actions
    private var filteredGroups: [(ActionCategory, [ActionItem])] {
        let builtIns = library.actions.filter(\.isBuiltIn)
        let filtered: [ActionItem]
        if searchText.isEmpty {
            filtered = builtIns
        } else {
            let q = searchText.lowercased()
            filtered = builtIns.filter {
                $0.name.lowercased().contains(q) ||
                $0.subtitle.lowercased().contains(q) ||
                $0.keywords.contains { $0.contains(q) }
            }
        }
        return ActionCategory.allCases.compactMap { cat in
            let items = filtered.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    private var enabledCount: Int { store.enabledKeys.intersection(library.actions.map(\.stableKey)).count }
    private var totalCount:   Int { library.actions.filter(\.isBuiltIn).count }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    shortcutSection
                    voiceSection
                    Divider()
                    actionsSection
                }
                .padding(20)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search actions…", text: $searchText)
                .textFieldStyle(.plain)
            Spacer()
            Text("\(enabledCount) / \(totalCount) enabled")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Reset Defaults") { store.resetToDefaults() }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Keyboard Shortcut

    private var shortcutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Open Quick Actions picker", systemImage: "bolt.fill")
                        .font(.headline)
                    Spacer()
                    ShortcutRecorderView(
                        keyCode:   store.shortcutKeyCode,
                        modifiers: store.shortcutModifiers
                    ) { kc, mod in
                        store.updateShortcut(keyCode: kc, modifiers: mod)
                        appState.updateActionShortcut(keyCode: kc, modifiers: mod)
                    }
                }
                Text("Invokes the floating Quick Actions panel from any app when Accessibility is granted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(4)
        } label: {
            Text("Keyboard Shortcut")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Voice Search

    private var voiceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $store.voiceSearchEnabled) {
                    Label("Enable voice-to-text search", systemImage: "mic.fill")
                }
                .onChange(of: store.voiceSearchEnabled) { _ in
                    UserDefaults.standard.set(store.voiceSearchEnabled, forKey: "actionVoiceSearchEnabled")
                }
                Text("Shows a mic button in the Quick Actions panel. Tap it, speak your task (e.g. \"clear xcode cache\"), and matching actions are suggested. Requires Microphone + Speech Recognition permissions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        } label: {
            Text("Voice Search")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions List

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("QUICK ACTION LIBRARY")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .tracking(1)
                Spacer()
                Button("Enable All")   { store.enableAll()  }
                    .font(.caption).buttonStyle(.borderless).foregroundColor(.accentColor)
                Text("·").foregroundColor(.secondary)
                Button("Disable All")  { store.disableAll() }
                    .font(.caption).buttonStyle(.borderless).foregroundColor(.secondary)
            }

            ForEach(filteredGroups, id: \.0) { cat, items in
                categoryGroup(cat, items: items)
            }
        }
    }

    private func categoryGroup(_ cat: ActionCategory, items: [ActionItem]) -> some View {
        let isExpanded = expandedCategories.contains(cat)
        let allEnabled = items.allSatisfy { store.isEnabled($0.stableKey) }
        let anyEnabled = items.contains   { store.isEnabled($0.stableKey) }

        return GroupBox {
            VStack(spacing: 0) {
                // Category header row
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded { expandedCategories.remove(cat) }
                        else          { expandedCategories.insert(cat) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cat.icon)
                            .foregroundColor(cat.color)
                            .frame(width: 16)
                        Text(cat.rawValue)
                            .font(.subheadline).bold()
                        Text("(\(items.filter { store.isEnabled($0.stableKey) }.count)/\(items.count))")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        // Category-level enable/disable toggle
                        Button(allEnabled ? "Disable All" : "Enable All") {
                            if allEnabled { store.disableCategory(cat) }
                            else          { store.enableCategory(cat)  }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundColor(allEnabled ? .secondary : .accentColor)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)

                // Action rows (collapsible)
                if isExpanded {
                    Divider()
                    ForEach(items) { action in
                        actionRow(action)
                            .padding(.vertical, 3)
                        if action.id != items.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func actionRow(_ action: ActionItem) -> some View {
        let enabled = store.isEnabled(action.stableKey)
        return HStack(spacing: 10) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(action.iconColor.opacity(enabled ? 0.15 : 0.06))
                    .frame(width: 26, height: 26)
                Image(systemName: action.icon)
                    .font(.system(size: 12))
                    .foregroundColor(enabled ? action.iconColor : .secondary)
            }
            // Text
            VStack(alignment: .leading, spacing: 1) {
                Text(action.name)
                    .font(.body)
                    .foregroundColor(enabled ? .primary : .secondary)
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // Admin badge
            if action.requiresPrivilege {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .help("Requires administrator privileges")
            }
            // Toggle
            Toggle("", isOn: Binding(
                get: { store.isEnabled(action.stableKey) },
                set: { store.setEnabled($0, for: action.stableKey) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}
