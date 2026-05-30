import SwiftUI

// MARK: - CustomActionEditor

/// Sheet for creating or editing a custom ActionItem.
struct CustomActionEditor: View {

    enum Mode { case create, edit(ActionItem) }

    let mode: Mode
    var onSave:   (ActionItem) -> Void
    var onCancel: () -> Void

    // Form fields
    @State private var name:              String         = ""
    @State private var subtitle:          String         = ""
    @State private var icon:              String         = "terminal.fill"
    @State private var iconColorHex:      String         = "#f5a623"
    @State private var category:          ActionCategory = .custom
    @State private var keywordsText:      String         = ""    // comma-separated
    @State private var scriptText:        String         = ""
    @State private var requiresPrivilege: Bool           = false
    @State private var showIconPicker:    Bool           = false
    @State private var validationError:   String?        = nil

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Title bar ────────────────────────────────────────────────
            HStack {
                Text(isEdit ? "Edit Action" : "New Custom Action")
                    .font(HaloFont.display(16, weight: .bold))
                    .foregroundColor(.haloText)
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().background(Color.haloBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    // ── Icon + Name row ──────────────────────────────────
                    HStack(alignment: .center, spacing: 14) {
                        iconButton
                        VStack(alignment: .leading, spacing: 8) {
                            field("Name", placeholder: "e.g. Remove node_modules", text: $name)
                            field("Description", placeholder: "Brief one-line description", text: $subtitle)
                        }
                    }

                    Divider().background(Color.haloBorder)

                    // ── Category ─────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 6) {
                        label("Category")
                        Picker("", selection: $category) {
                            ForEach(ActionCategory.allCases) { cat in
                                Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // ── Keywords ─────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 6) {
                        label("Search Keywords")
                        caption("Comma-separated aliases used to find this action (e.g. node, npm, clean).")
                        TextField("node, npm clean, remove modules", text: $keywordsText)
                            .textFieldStyle(.plain)
                            .font(HaloFont.body(13))
                            .foregroundColor(.haloText)
                            .padding(10)
                            .background(Color.haloSurface2)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
                    }

                    Divider().background(Color.haloBorder)

                    // ── Script ────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            label("Shell Script / Command")
                            Spacer()
                            Text("Runs in /bin/zsh")
                                .font(HaloFont.body(10))
                                .foregroundColor(.haloText3)
                        }
                        caption("Write any bash/zsh command or multi-line script. Use $HOME instead of ~.")
                        TextEditor(text: $scriptText)
                            .font(HaloFont.mono(12))
                            .foregroundColor(.haloText)
                            .frame(minHeight: 160)
                            .padding(10)
                            .background(Color.haloSurface2)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
                    }

                    // ── Privilege toggle ─────────────────────────────────
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(requiresPrivilege ? .haloAmber : .haloText3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Run with Administrator Privileges")
                                .font(HaloFont.body(13, weight: .medium))
                                .foregroundColor(.haloText)
                            Text("Enables 'sudo' commands via macOS authentication dialog.")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloText3)
                        }
                        Spacer()
                        Toggle("", isOn: $requiresPrivilege)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(14)
                    .background(Color.haloSurface2)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(requiresPrivilege ? Color.haloAmber.opacity(0.35) : Color.haloBorder, lineWidth: 1))

                    // ── Validation error ─────────────────────────────────
                    if let err = validationError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.haloRed)
                            Text(err).font(HaloFont.body(12)).foregroundColor(.haloRed)
                        }
                    }
                }
                .padding(20)
            }

            Divider().background(Color.haloBorder)

            // ── Buttons ──────────────────────────────────────────────────
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(HaloSecondaryButtonStyle())
                Button(isEdit ? "Save Changes" : "Add Action") { attemptSave() }
                    .buttonStyle(HaloPrimaryButtonStyle())
            }
            .padding(20)
        }
        .frame(width: 560)
        .background(Color.haloBackground)
        .onAppear { populateFields() }
    }

    // MARK: - Sub-views

    private var iconButton: some View {
        Button { showIconPicker.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: iconColorHex).opacity(0.18))
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color(hex: iconColorHex))
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: iconColorHex).opacity(0.4), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showIconPicker) {
            IconColorPicker(icon: $icon, colorHex: $iconColorHex)
        }
    }

    @ViewBuilder
    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(HaloFont.body(13))
                .foregroundColor(.haloText)
                .padding(10)
                .background(Color.haloSurface2)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(HaloFont.body(11, weight: .semibold))
            .foregroundColor(.haloText3)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(HaloFont.body(11))
            .foregroundColor(.haloText3)
    }

    // MARK: - Logic

    private func populateFields() {
        if case .edit(let a) = mode {
            name              = a.name
            subtitle          = a.subtitle
            icon              = a.icon
            iconColorHex      = a.iconColorHex
            category          = a.category
            keywordsText      = a.keywords.joined(separator: ", ")
            requiresPrivilege = a.requiresPrivilege
            if case .shell(let s) = a.command { scriptText = s }
        }
    }

    private func attemptSave() {
        validationError = nil
        let n = name.trimmingCharacters(in: .whitespaces)
        let s = scriptText.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { validationError = "Name is required."; return }
        guard !s.isEmpty else { validationError = "Script / command cannot be empty."; return }

        let keywords = keywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        var item: ActionItem
        if case .edit(let existing) = mode {
            item = existing
        } else {
            item = ActionItem(
                name: n, subtitle: subtitle.trimmingCharacters(in: .whitespaces),
                icon: icon, iconColorHex: iconColorHex, category: category,
                keywords: keywords, command: .shell(s),
                requiresPrivilege: requiresPrivilege, isBuiltIn: false)
        }
        item.name              = n
        item.subtitle          = subtitle.trimmingCharacters(in: .whitespaces)
        item.icon              = icon
        item.iconColorHex      = iconColorHex
        item.category          = category
        item.keywords          = keywords
        item.command           = .shell(s)
        item.requiresPrivilege = requiresPrivilege
        onSave(item)
    }
}

// MARK: - Icon + Colour Picker Popover

private struct IconColorPicker: View {
    @Binding var icon:     String
    @Binding var colorHex: String

    private let icons: [String] = [
        "terminal.fill", "folder.fill", "trash.fill", "bolt.fill",
        "hammer.fill", "gearshape.fill", "network", "shippingbox.fill",
        "doc.text.fill", "arrow.clockwise", "iphone.slash", "lock.shield.fill",
        "globe", "magnifyingglass", "wrench.and.screwdriver.fill", "chart.bar.fill",
        "cpu.fill", "memorychip.fill", "externaldrive.fill", "wifi.slash",
        "ant.fill", "flame.fill", "star.fill", "tag.fill",
        "play.fill", "stop.fill", "archivebox.fill", "tray.fill"
    ]

    private let colors: [String] = [
        "#4f7cff", "#7b5ea7", "#22d97a", "#f5a623",
        "#ff4d6a", "#00d4e8", "#ff9f0a", "#30d158",
        "#64d2ff", "#ff375f", "#bf5af2", "#ac8e68"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon").font(HaloFont.body(11, weight: .semibold)).foregroundColor(.haloText3)
            LazyVGrid(columns: Array(repeating: .init(.fixed(36)), count: 7), spacing: 6) {
                ForEach(icons, id: \.self) { sym in
                    Button {
                        icon = sym
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(icon == sym ? Color(hex: colorHex).opacity(0.25) : Color.haloSurface2)
                                .frame(width: 34, height: 34)
                            Image(systemName: sym)
                                .font(.system(size: 14))
                                .foregroundColor(icon == sym ? Color(hex: colorHex) : .haloText2)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(icon == sym ? Color(hex: colorHex).opacity(0.5) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().background(Color.haloBorder)
            Text("Colour").font(HaloFont.body(11, weight: .semibold)).foregroundColor(.haloText3)
            LazyVGrid(columns: Array(repeating: .init(.fixed(30)), count: 6), spacing: 6) {
                ForEach(colors, id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(colorHex == hex ? .white : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color.haloBackground)
        .frame(width: 280)
    }
}

// MARK: - Button styles (reused)

private struct HaloPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HaloFont.body(13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(
                LinearGradient(colors: [.haloAccent, .haloAccent2],
                               startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct HaloSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HaloFont.body(13))
            .foregroundColor(.haloText2)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Color.haloSurface2)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
