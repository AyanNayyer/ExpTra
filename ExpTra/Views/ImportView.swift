//
//  ImportView.swift
//  ExpenseTracker
//
//  Paste a batch of old bank messages (one per line), preview what the
//  parser makes of each, then save everything in one tap. This is the backfill
//  path since Shortcuts automations only fire on NEW messages. Lines the parser
//  is unsure about can be saved for in-app review instead of being dropped.
//

import SwiftUI
import SwiftData

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \MessageTemplate.sortOrder) private var templates: [MessageTemplate]
    @Query private var rules: [CategoryRule]
    @Query private var decisions: [MessageDecision]

    @State private var pastedText = ""
    @State private var previews: [PreviewItem] = []
    @State private var savedCount: Int?
    @State private var reviewCount: Int?

    enum Kind {
        case transaction(ParsedTransaction, category: String)
        case ambiguous(reason: String, guess: ParsedTransaction)
        case ignored
        case notRecognized
    }

    struct PreviewItem: Identifiable {
        let id = UUID()
        let raw: String
        let kind: Kind
        let isDuplicate: Bool
        var include: Bool
    }

    private var willSaveCount: Int {
        previews.filter { $0.include && !$0.isDuplicate }.count
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
                Section("Preview (\(willSaveCount) will be saved)") {
                    ForEach($previews) { $item in
                        row(for: $item)
                    }
                }

                Button("Save selected") { saveAll() }
                    .fontWeight(.semibold)
                    .disabled(willSaveCount == 0)
            }

            if let savedCount {
                Text("Saved \(savedCount) transaction(s)."
                     + ((reviewCount ?? 0) > 0 ? " \(reviewCount!) saved for review." : ""))
                    .foregroundStyle(.green)
            }
        }
        .navigationTitle("Import Messages")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: rows

    @ViewBuilder
    private func row(for item: Binding<PreviewItem>) -> some View {
        switch item.wrappedValue.kind {
        case .transaction(let p, let category):
            Toggle(isOn: item.include) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("₹\(p.amount) — \(p.merchant)").fontWeight(.medium)
                    Text("\(category) · \(p.type) · via \(p.matchedBy)")
                        .font(.caption).foregroundStyle(.secondary)
                    if item.wrappedValue.isDuplicate {
                        Text("Duplicate — already saved")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .disabled(item.wrappedValue.isDuplicate)

        case .ambiguous(let reason, _):
            Toggle(isOn: item.include) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.wrappedValue.raw).font(.callout).lineLimit(2)
                    Label("Unsure — \(reason) Save for review.",
                          systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                    if item.wrappedValue.isDuplicate {
                        Text("Duplicate — already handled")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .disabled(item.wrappedValue.isDuplicate)

        case .ignored:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.wrappedValue.raw).font(.caption).lineLimit(2)
                    Text("Ignored by a template").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "nosign").foregroundStyle(.secondary)
            }

        case .notRecognized:
            Label {
                Text(item.wrappedValue.raw).font(.caption).lineLimit(2)
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    // MARK: actions

    private func parse() {
        savedCount = nil
        reviewCount = nil
        let lines = pastedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 }

        let existing = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let existingHashes = Set(existing.map(\.messageHash))
        let pendingHashes = Set(((try? context.fetch(FetchDescriptor<PendingMessage>())) ?? [])
            .map(\.messageHash))

        previews = lines.map { line in
            let hash = LogExpenseIntent.sha256(line)
            let isDup = existingHashes.contains(hash) || pendingHashes.contains(hash)

            switch MessageParser.classify(line, templates: templates, decisions: decisions) {
            case .transaction(let p):
                let category = Categorizer.category(merchant: p.merchant,
                                                    rawMessage: line,
                                                    type: p.type,
                                                    userRules: rules)
                return PreviewItem(raw: line, kind: .transaction(p, category: category),
                                   isDuplicate: isDup, include: !isDup)
            case .ambiguous(let reason, let guess):
                return PreviewItem(raw: line, kind: .ambiguous(reason: reason, guess: guess),
                                   isDuplicate: isDup, include: !isDup)
            case .ignored:
                return PreviewItem(raw: line, kind: .ignored, isDuplicate: isDup, include: false)
            case .notTransaction:
                return PreviewItem(raw: line, kind: .notRecognized, isDuplicate: isDup, include: false)
            }
        }
    }

    private func saveAll() {
        var saved = 0
        var review = 0
        for item in previews where item.include && !item.isDuplicate {
            switch item.kind {
            case .transaction(let p, let category):
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
                saved += 1
            case .ambiguous(let reason, let guess):
                let pending = PendingMessage(
                    rawMessage: item.raw,
                    messageHash: LogExpenseIntent.sha256(item.raw),
                    reason: reason,
                    guessedAmount: guess.amount,
                    guessedMerchant: guess.merchant,
                    guessedType: guess.type
                )
                context.insert(pending)
                review += 1
            case .ignored, .notRecognized:
                break
            }
        }
        try? context.save()
        savedCount = saved
        reviewCount = review
        previews = []
        pastedText = ""
    }
}
