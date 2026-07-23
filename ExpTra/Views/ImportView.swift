//
//  ImportView.swift
//  ExpenseTracker
//
//  Paste a batch of old bank messages (one per line), preview what the
//  parser extracts, then save everything in one tap. This is the backfill
//  path since Shortcuts automations only fire on NEW messages.
//

import SwiftUI
import SwiftData

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \MessageTemplate.sortOrder) private var templates: [MessageTemplate]
    @Query private var rules: [CategoryRule]

    @State private var pastedText = ""
    @State private var previews: [PreviewItem] = []
    @State private var savedCount: Int?

    struct PreviewItem: Identifiable {
        let id = UUID()
        let raw: String
        let parsed: ParsedTransaction?
        let category: String?
        let isDuplicate: Bool
        var include: Bool
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $pastedText)
                    .frame(minHeight: 140)
                    .autocorrectionDisabled()
            } header: {
                Text("Paste messages — one per line")
            } footer: {
                Text("Copy bank SMS texts from Messages and paste them here. Each line is treated as one message.")
            }

            Button("Parse") { parse() }
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !previews.isEmpty {
                Section("Preview (\(previews.filter { $0.include && $0.parsed != nil && !$0.isDuplicate }.count) will be saved)") {
                    ForEach($previews) { $item in
                        VStack(alignment: .leading, spacing: 4) {
                            if let p = item.parsed {
                                Toggle(isOn: $item.include) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("₹\(p.amount) — \(p.merchant)")
                                            .fontWeight(.medium)
                                        Text("\(item.category ?? "?") · \(p.type) · via \(p.matchedBy)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if item.isDuplicate {
                                            Text("Duplicate — already saved")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .disabled(item.isDuplicate)
                            } else {
                                Label {
                                    Text(item.raw).font(.caption).lineLimit(2)
                                } icon: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }

                Button("Save selected") { saveAll() }
                    .fontWeight(.semibold)
            }

            if let savedCount {
                Text("Saved \(savedCount) transaction(s).")
                    .foregroundStyle(.green)
            }
        }
        .navigationTitle("Import Messages")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func parse() {
        savedCount = nil
        let lines = pastedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 }

        let existing = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let existingHashes = Set(existing.map(\.messageHash))

        previews = lines.map { line in
            let parsed = TemplateEngine.parse(line, templates: templates)
                ?? GenericParser.parse(line)
            let category = parsed.map {
                Categorizer.category(merchant: $0.merchant,
                                     rawMessage: line,
                                     type: $0.type,
                                     userRules: rules)
            }
            let hash = LogExpenseIntent.sha256(line)
            return PreviewItem(raw: line,
                               parsed: parsed,
                               category: category,
                               isDuplicate: existingHashes.contains(hash),
                               include: parsed != nil)
        }
    }

    private func saveAll() {
        var count = 0
        for item in previews {
            guard item.include, !item.isDuplicate,
                  let p = item.parsed, let category = item.category else { continue }
            let tx = Transaction(
                amount: p.amount,
                merchant: p.merchant,
                category: category,
                account: p.account,
                type: p.type,
                date: .now,   // adjust per-transaction afterwards if needed
                rawMessage: item.raw,
                messageHash: LogExpenseIntent.sha256(item.raw)
            )
            context.insert(tx)
            count += 1
        }
        try? context.save()
        savedCount = count
        previews = []
        pastedText = ""
    }
}
