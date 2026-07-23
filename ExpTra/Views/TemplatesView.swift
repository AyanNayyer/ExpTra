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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(templates) { t in
                        NavigationLink(value: t) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(t.name).fontWeight(.medium)
                                    Spacer()
                                    Text(t.type == "debit" ? "Debit" : "Credit")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            (t.type == "debit" ? Color.red : Color.green)
                                                .opacity(0.15),
                                            in: Capsule())
                                }
                                Text(t.template)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
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

    private func addNew() {
        let t = MessageTemplate(
            name: "New template",
            bank: "",
            template: "Rs.{amount} debited from A/c {account} to {merchant}",
            type: "debit",
            sortOrder: (templates.map(\.sortOrder).max() ?? 0) + 1
        )
        context.insert(t)
        try? context.save()
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

    @State private var testMessage = ""

    private var testResult: ParsedTransaction? {
        guard !testMessage.isEmpty else { return nil }
        return TemplateEngine.parse(testMessage, templates: [template])
    }

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name (e.g. HDFC UPI debit)", text: $template.name)
                TextField("Bank (optional)", text: $template.bank)
                Picker("Type", selection: $template.type) {
                    Text("Debit").tag("debit")
                    Text("Credit").tag("credit")
                }
                Toggle("Enabled", isOn: $template.isEnabled)
            }

            Section {
                TextEditor(text: $template.template)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 80)
                    .autocorrectionDisabled()
            } header: {
                Text("Pattern")
            } footer: {
                Text("""
                Paste one of your real bank messages, then replace the changing parts with tokens:

                {amount} — the number (write the Rs./INR prefix as literal text)
                {account} — account/card digits like XX1234
                {merchant} — shop/UPI name
                {skip} — ignore up to 60 characters

                Example: Rs.{amount} debited from A/c {account} to {merchant} on

                Spacing is flexible and matching is case-insensitive. Only include the stable part of the message — you can stop before the reference number.
                """)
            }

            Section("Test with a real message") {
                TextEditor(text: $testMessage)
                    .frame(minHeight: 80)
                    .autocorrectionDisabled()

                if testMessage.isEmpty {
                    Text("Paste a sample SMS above to test.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let r = testResult {
                    LabeledContent("Amount", value: "₹\(r.amount)")
                    LabeledContent("Merchant", value: r.merchant)
                    LabeledContent("Account", value: r.account)
                    LabeledContent("Type", value: r.type.capitalized)
                } else {
                    Label("No match — adjust the pattern",
                          systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Edit Template")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
    }
}
