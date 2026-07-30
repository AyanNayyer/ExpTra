//
//  TemplatesView.swift
//  ExpenseTracker
//
//  Manage the message templates that identify YOUR banks' SMS formats.
//  Templates use tokens: {amount} {account} {merchant} {skip}
//  Includes a live tester: paste a real SMS and see what gets extracted.
//

import SwiftUI
import SwiftData

struct TemplatesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MessageTemplate.sortOrder)
    private var templates: [MessageTemplate]

    @State private var path: [MessageTemplate] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(templates) { t in
                        NavigationLink(value: t) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(t.name).fontWeight(.medium)
                                    Spacer()
                                    Text(typeLabel(t.type))
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(typeColor(t.type).opacity(0.15),
                                                    in: Capsule())
                                }
                                Text(t.template.isEmpty
                                     ? "Tap to build from an example message"
                                     : t.template)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .italic(t.template.isEmpty)
                            }
                            .opacity(t.isEnabled ? 1 : 0.4)
                        }
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("Message Templates")
                } footer: {
                    Text("Templates are tried top-down; the first match wins. Messages that match no template fall back to the built-in generic parser.")
                }
            }
            .navigationTitle("Templates")
            .navigationDestination(for: MessageTemplate.self) { t in
                TemplateEditView(template: t)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { addNew() } label: { Image(systemName: "plus") }
                }
            }
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "debit": return "Debit"
        case "credit": return "Credit"
        default: return "Ignore"
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "debit": return .red
        case "credit": return .green
        default: return .gray
        }
    }

    private func addNew() {
        let t = MessageTemplate(
            name: "New template",
            bank: "",
            template: "",
            type: "debit",
            sortOrder: (templates.map(\.sortOrder).max() ?? 0) + 1
        )
        context.insert(t)
        try? context.save()
        // Navigate straight into the editor so it's obvious a template was added.
        path.append(t)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(templates[index]) }
        try? context.save()
    }
}

// MARK: - Editor with live tester

struct TemplateEditView: View {
    @Environment(\.modelContext) private var context
    @Bindable var template: MessageTemplate

    @Query(sort: \MessageTemplate.sortOrder) private var allTemplates: [MessageTemplate]

    @State private var exampleMessage = ""
    @State private var capturedAmount = ""
    @State private var capturedAccount = ""
    @State private var capturedMerchant = ""
    @State private var generationFailed = false

    private var hasExample: Bool {
        !exampleMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isIgnore: Bool { template.type == "ignore" }

    /// What the current template actually extracts from the example — the honest
    /// truth, which can differ slightly from the typed fields for a trailing token.
    private var preview: ParsedTransaction? {
        guard hasExample, !template.template.isEmpty else { return nil }
        return TemplateEngine.parse(exampleMessage, templates: [template])
    }

    /// Another template that already uses this exact pattern, if any.
    private var duplicate: MessageTemplate? {
        let mine = normalizedPattern(template.template)
        guard !mine.isEmpty else { return nil }
        return allTemplates.first {
            $0.persistentModelID != template.persistentModelID
                && normalizedPattern($0.template) == mine
        }
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Name (e.g. HDFC UPI debit)", text: $template.name)
                TextField("Bank (optional)", text: $template.bank)
                Picker("Type", selection: $template.type) {
                    Text("Debit").tag("debit")
                    Text("Credit").tag("credit")
                    Text("Ignore").tag("ignore")
                }
                Toggle("Enabled", isOn: $template.isEnabled)
            }
            .onChange(of: template.type) { _, _ in
                if isIgnore { rebuildIgnore() } else { rebuild() }
            }

            if let dup = duplicate {
                Section {
                    Label("Another template (\"\(dup.name)\") already uses this exact pattern.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section {
                TextEditor(text: $exampleMessage)
                    .frame(minHeight: 90)
                    .autocorrectionDisabled()
            } header: {
                Text("Example message")
            } footer: {
                Text(isIgnore
                     ? "Paste an example of a message you want to ignore. The app builds a pattern that skips messages like it."
                     : "Paste one real SMS from your bank. The app fills in what it will capture below — you don't need to write anything with tokens.")
            }
            .onChange(of: exampleMessage) { _, _ in detect() }

            if generationFailed && !isIgnore {
                Section {
                    Label("Couldn't find an amount in that message. Paste a real debit/credit SMS.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            if isIgnore {
                ignoreSection
            } else if hasExample {
                captureSection
                resultSection
            } else if !template.template.isEmpty {
                Section {
                    Text(template.template)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Current pattern")
                } footer: {
                    Text("Paste an example message above to review or change what this template captures.")
                }
            }
        }
        .navigationTitle("Edit Template")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Discard a template that was never given a pattern (e.g. the user
            // tapped + then backed out) so blanks don't accumulate.
            if template.template.trimmingCharacters(in: .whitespaces).isEmpty {
                context.delete(template)
            }
            try? context.save()
        }
    }

    // MARK: sections

    private var captureSection: some View {
        Section {
            captureRow("Amount", text: $capturedAmount)
            captureRow("Account", text: $capturedAccount)
            captureRow("Merchant", text: $capturedMerchant)
        } header: {
            Text("What to capture")
        } footer: {
            Text("These come from your example. Edit any field to point it at the right part of the message and the template updates automatically. A ⚠︎ means that text isn't in the message. Leave a field blank to not capture it.")
        }
        .onChange(of: capturedAmount) { _, _ in rebuild() }
        .onChange(of: capturedAccount) { _, _ in rebuild() }
        .onChange(of: capturedMerchant) { _, _ in rebuild() }
    }

    private var resultSection: some View {
        Section {
            if let p = preview {
                LabeledContent("Amount", value: "₹\(p.amount)")
                LabeledContent("Account", value: p.account)
                LabeledContent("Merchant", value: p.merchant)
            } else {
                Text("Fill in at least the amount above to capture transactions.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Generated pattern") {
                if template.template.isEmpty {
                    Text("No pattern yet — fill in at least one field above.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(template.template)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Result on your example")
        } footer: {
            Text("What the pattern actually pulls out. A field like Merchant may capture a little more than you typed when there's no clear boundary after it in the message.")
        }
    }

    @ViewBuilder
    private var ignoreSection: some View {
        Section {
            if template.template.isEmpty {
                Text("Paste an example above of the message you want to ignore.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(template.template)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if hasExample, case .ignored = TemplateEngine.match(exampleMessage, templates: [template]) {
                    Label("Messages like your example will be ignored.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
        } header: {
            Text("Ignore pattern")
        } footer: {
            Text("Any incoming message matching this pattern is skipped — never logged. The amount and account are generalized so it works for any values.")
        }
    }

    // MARK: rows & helpers

    /// An editable captured value with an inline warning when its text isn't
    /// present in the example message.
    private func captureRow(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                if !text.wrappedValue.isEmpty,
                   !TemplateInferer.contains(text.wrappedValue, in: exampleMessage) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField(label, text: text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
        }
    }

    private func normalizedPattern(_ pattern: String) -> String {
        TemplateInferer.normalized(pattern).lowercased()
    }

    /// Runs when the example message changes: auto-fill the captured fields, or
    /// (for ignore templates) regenerate the ignore pattern.
    private func detect() {
        guard hasExample else {
            generationFailed = false
            return
        }
        if isIgnore {
            generationFailed = false
            rebuildIgnore()
            return
        }
        if let d = TemplateInferer.detect(from: exampleMessage) {
            capturedAmount = d.amount
            capturedAccount = d.account
            capturedMerchant = d.merchant
            template.type = d.type
            generationFailed = false
            rebuild()
        } else {
            generationFailed = true
        }
    }

    /// Rebuilds a capture template from the current captured fields.
    private func rebuild() {
        guard hasExample else { return }
        if let pattern = TemplateInferer.buildTemplate(
            from: exampleMessage,
            amount: capturedAmount,
            account: capturedAccount,
            merchant: capturedMerchant) {
            template.template = pattern
        }
    }

    /// Rebuilds an ignore pattern from the example message.
    private func rebuildIgnore() {
        guard hasExample else { return }
        if let pattern = TemplateInferer.buildIgnorePattern(from: exampleMessage) {
            template.template = pattern
        }
    }
}
