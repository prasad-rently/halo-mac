import SwiftUI

// MARK: - SnippetEditorView

struct SnippetEditorView: View {
    @ObservedObject var manager: SnippetManager
    @Environment(\.dismiss) private var dismiss

    /// If non-nil, we're editing an existing snippet. Otherwise creating new.
    var editing: TextSnippet?

    @State private var name: String = ""
    @State private var trigger: String = "//"
    @State private var snippetBody: String = ""
    @State private var category: String = "General"
    @State private var customCategory: String = ""
    @State private var useCustomCategory = false

    private let placeholders: [(String, String)] = [
        ("{date}", "Today's date"),
        ("{time}", "Current time"),
        ("{clipboard}", "Clipboard text"),
        ("{uuid}", "Random UUID"),
        ("{random:8}", "Random 8-char string"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(editing == nil ? "New Snippet" : "Edit Snippet")
                    .font(HaloFont.display(16, weight: .bold))
                    .foregroundColor(.haloText)
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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(HaloFont.body(11, weight: .semibold))
                            .foregroundColor(.haloText3)
                        TextField("Email Signature, Console Log, etc.", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Trigger keyword
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trigger Keyword")
                            .font(HaloFont.body(11, weight: .semibold))
                            .foregroundColor(.haloText3)
                        HStack {
                            TextField("//sig", text: $trigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Text("Type this to trigger the snippet")
                                .font(HaloFont.body(10))
                                .foregroundColor(.haloText3)
                        }
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Category")
                            .font(HaloFont.body(11, weight: .semibold))
                            .foregroundColor(.haloText3)
                        HStack(spacing: 8) {
                            if !useCustomCategory {
                                Picker("", selection: $category) {
                                    ForEach(allCategories, id: \.self) { cat in
                                        Text(cat).tag(cat)
                                    }
                                }
                                .frame(width: 160)
                            } else {
                                TextField("New category name", text: $customCategory)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 160)
                            }
                            Button(useCustomCategory ? "Use existing" : "New category") {
                                useCustomCategory.toggle()
                            }
                            .font(HaloFont.body(10))
                            .foregroundColor(.haloAccent)
                            .buttonStyle(.plain)
                        }
                    }

                    // Body
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Snippet Body")
                                .font(HaloFont.body(11, weight: .semibold))
                                .foregroundColor(.haloText3)
                            Spacer()
                            // Placeholder insertion buttons
                            HStack(spacing: 4) {
                                ForEach(placeholders, id: \.0) { token, desc in
                                    Button {
                                        snippetBody += token
                                    } label: {
                                        Text(token)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.haloAccent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.haloAccent.opacity(0.08))
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help(desc)
                                }
                            }
                        }

                        TextEditor(text: $snippetBody)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 100, maxHeight: 200)
                            .padding(4)
                            .background(Color.haloSurface)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
                    }

                    // Live preview
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preview")
                            .font(HaloFont.body(11, weight: .semibold))
                            .foregroundColor(.haloText3)
                        Text(SnippetExpander.expand(snippetBody))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.haloText2)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.haloSurface)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.haloBorder, lineWidth: 1))
                    }
                }
                .padding(20)
            }

            Divider().background(Color.haloBorder)

            // Action buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.haloText2)

                Spacer()

                Button(editing == nil ? "Create Snippet" : "Save Changes") {
                    saveSnippet()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || trigger.isEmpty || snippetBody.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 520)
        .background(Color.haloSurface)
        .onAppear {
            if let s = editing {
                name = s.name
                trigger = s.trigger
                snippetBody = s.body
                category = s.category
            }
        }
    }

    private var allCategories: [String] {
        let existing = manager.categories
        let defaults = ["General", "Symbols", "Date & Time", "Dev", "Email"]
        return Array(Set(existing + defaults)).sorted()
    }

    private func saveSnippet() {
        let cat = useCustomCategory ? customCategory : category

        if var s = editing {
            s.name = name
            s.trigger = trigger
            s.body = snippetBody
            s.category = cat.isEmpty ? "General" : cat
            manager.update(s)
        } else {
            let s = TextSnippet(
                name: name,
                trigger: trigger,
                body: snippetBody,
                category: cat.isEmpty ? "General" : cat
            )
            manager.add(s)
        }
    }
}
