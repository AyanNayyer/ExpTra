//
//  SettingsView.swift
//  ExpenseTracker
//
//  Category rules manager, bulk paste importer, CSV export,
//  Face ID toggle, and the automation setup guide.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CategoryRule.createdAt, order: .reverse)
    private var rules: [CategoryRule]
    @Query private var transactions: [Transaction]

    @AppStorage("faceIDEnabled") private var faceIDEnabled = false
    @State private var showAddRule = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: Category rules
                Section {
                    ForEach(rules) { rule in
                        HStack {
                            Text("\"\(rule.matchText)\"").lineLimit(1)
                            Spacer()
                            Text(rule.category)
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.blue.opacity(0.15), in: Capsule())
                        }
                    }
                    .onDelete(perform: deleteRule)

                    Button {
                        showAddRule = true
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                } header: {
                    Text("Category Rules")
                } footer: {
                    Text("Messages or merchants containing the text get the category. Your rules always override the built-in defaults. Newest rule wins.")
                }

                // MARK: Data
                Section("Data") {
                    NavigationLink {
                        ImportView()
                    } label: {
                        Label("Import old messages (paste)", systemImage: "square.and.arrow.down")
                    }

                    ShareLink(item: csvExport(),
                              preview: SharePreview("expenses.csv")) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }

                    LabeledContent("Transactions", value: "\(transactions.count)")
                }

                // MARK: Security
                Section("Security") {
                    Toggle("Require Face ID / passcode", isOn: $faceIDEnabled)
                }

                // MARK: Setup
                Section("Auto-capture setup") {
                    NavigationLink {
                        SetupGuideView()
                    } label: {
                        Label("Shortcuts automation guide", systemImage: "bolt.badge.automatic")
                    }
                    if let last = transactions
                        .filter({ $0.account != "manual" })
                        .map(\.date).max() {
                        LabeledContent("Last auto/import capture",
                                       value: last.formatted(date: .abbreviated,
                                                             time: .shortened))
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddRule) { AddRuleView() }
        }
    }

    private func deleteRule(at offsets: IndexSet) {
        for i in offsets { context.delete(rules[i]) }
        try? context.save()
    }

    private func csvExport() -> String {
        var csv = "date,amount,type,merchant,category,account\n"
        let df = ISO8601DateFormatter()
        for t in transactions.sorted(by: { $0.date < $1.date }) {
            let merchant = t.merchant.replacingOccurrences(of: ",", with: " ")
            csv += "\(df.string(from: t.date)),\(t.amount),\(t.type),\(merchant),\(t.category),\(t.account)\n"
        }
        return csv
    }
}

// MARK: - Add rule sheet

struct AddRuleView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var rules: [CategoryRule]

    @State private var matchText = ""
    @State private var category = DefaultData.categories.first ?? "Uncategorized"
    @State private var customCategory = ""
    @State private var applyToExisting = true

    private var allCategories: [String] {
        var set = Set(DefaultData.categories)
        rules.forEach { set.insert($0.category) }
        return set.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text to match (e.g. SWIGGY or shop@upi)",
                              text: $matchText)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Matched against the merchant name AND the full message, case-insensitive. UPI IDs work too.")
                }

                Section("Assign category") {
                    Picker("Category", selection: $category) {
                        ForEach(allCategories, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Or type a new category", text: $customCategory)
                        .autocorrectionDisabled()
                }

                Toggle("Apply to existing transactions", isOn: $applyToExisting)
            }
            .navigationTitle("New Category Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(matchText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let finalCategory = customCategory.trimmingCharacters(in: .whitespaces)
            .isEmpty ? category : customCategory.trimmingCharacters(in: .whitespaces)
        let rule = CategoryRule(matchText: matchText, category: finalCategory)
        context.insert(rule)

        if applyToExisting {
            let needle = matchText.lowercased()
            let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
            for t in all where !t.isManuallyEdited {
                if t.merchant.lowercased().contains(needle) ||
                    t.rawMessage.lowercased().contains(needle) {
                    t.category = finalCategory
                }
            }
        }

        try? context.save()
        dismiss()
    }
}

// MARK: - Setup guide

struct SetupGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("One-time setup on this iPhone:").font(.headline)

                Group {
                    step(1, "Open the Shortcuts app → Automation tab → + → New Automation → Message.")
                    step(2, "Leave Sender empty. In \"Message Contains\", type: debited")
                    step(3, "Select \"Run Immediately\" (not \"Run After Confirmation\"). Turn Notify When Run off. Tap Next.")
                    step(4, "Tap \"New Blank Automation\", add the action \"Log Expense From Message\" (search for this app's name).")
                    step(5, "Tap the Message Text field → select the magic variable \"Shortcut Input\". Done.")
                    step(6, "Repeat for these keywords, one automation each: spent, credited, withdrawn, paid, sent.")
                }

                Text("Notes").font(.headline).padding(.top, 6)
                Text("""
                • Automations only fire on NEW incoming messages — use Import in Settings to backfill history.
                • If \"Last auto capture\" on the Settings page looks stale, check that the automations are still enabled (iOS updates/restores can silently disable them).
                • Everything runs on this device. The app has no network access.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Setup Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(.blue.opacity(0.15), in: Circle())
            Text(text).font(.callout)
        }
    }
}
