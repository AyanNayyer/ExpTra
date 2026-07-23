//
//  TransactionsView.swift
//  ExpenseTracker
//
//  Searchable transaction list + edit screen. Editing a category offers
//  "Always use this category for this merchant" → creates a CategoryRule
//  and can re-apply it to existing transactions.
//

import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var searchText = ""
    @State private var showManualAdd = false

    private var filtered: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        let q = searchText.lowercased()
        return transactions.filter {
            $0.merchant.lowercased().contains(q) ||
            $0.category.lowercased().contains(q) ||
            $0.rawMessage.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { tx in
                    NavigationLink(value: tx) {
                        TransactionRow(tx: tx)
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Transactions")
            .navigationDestination(for: Transaction.self) { tx in
                TransactionEditView(tx: tx)
            }
            .searchable(text: $searchText,
                        prompt: "Search merchant, category, text")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showManualAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showManualAdd) {
                ManualAddView()
            }
            .overlay {
                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("They'll appear automatically when bank messages arrive, or add one with +.")
                    )
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(filtered[index])
        }
        try? context.save()
    }
}

// MARK: - Row

struct TransactionRow: View {
    let tx: Transaction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.merchant).font(.body.weight(.medium)).lineLimit(1)
                Text("\(tx.category) · \(tx.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(tx.amountDouble,
                 format: .currency(code: "INR").precision(.fractionLength(0)))
                .fontWeight(.semibold)
                .foregroundStyle(tx.type == "debit" ? Color.primary : .green)
        }
    }
}

// MARK: - Edit

struct TransactionEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var tx: Transaction

    @Query private var rules: [CategoryRule]
    @Query(sort: \ExpenseCategory.name) private var customCategories: [ExpenseCategory]

    @State private var createRule = false
    @State private var applyToExisting = true
    @State private var customCategory = ""

    private var allCategories: [String] {
        DefaultData.allCategories(custom: customCategories, rules: rules)
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Merchant", text: $tx.merchant)
                TextField("Account", text: $tx.account)
                DatePicker("Date", selection: $tx.date)
                Picker("Type", selection: $tx.type) {
                    Text("Debit").tag("debit")
                    Text("Credit").tag("credit")
                }
            }

            Section("Category") {
                Picker("Category", selection: $tx.category) {
                    ForEach(allCategories, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or type a new category", text: $customCategory)
                    .autocorrectionDisabled()

                Toggle("Always use this category for \"\(tx.merchant)\"",
                       isOn: $createRule)
                if createRule {
                    Toggle("Apply to existing transactions", isOn: $applyToExisting)
                }
            }

            Section("Original message") {
                Text(tx.rawMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button("Save") { save() }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
        }
        .navigationTitle("Edit Transaction")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        let newCategory = customCategory.trimmingCharacters(in: .whitespaces)
        if !newCategory.isEmpty { tx.category = newCategory }
        tx.isManuallyEdited = true

        if createRule && !tx.merchant.isEmpty {
            let rule = CategoryRule(matchText: tx.merchant, category: tx.category)
            context.insert(rule)

            if applyToExisting {
                let needle = tx.merchant.lowercased()
                let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
                for other in all where other.persistentModelID != tx.persistentModelID {
                    if other.merchant.lowercased().contains(needle) && !other.isManuallyEdited {
                        other.category = tx.category
                    }
                }
            }
        }

        try? context.save()
        dismiss()
    }
}

// MARK: - Manual add

struct ManualAddView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var rules: [CategoryRule]
    @Query(sort: \ExpenseCategory.name) private var customCategories: [ExpenseCategory]

    @State private var amountText = ""
    @State private var merchant = ""
    @State private var category = "Uncategorized"
    @State private var type = "debit"
    @State private var date = Date()

    private var allCategories: [String] {
        DefaultData.allCategories(custom: customCategories, rules: rules)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Amount (₹)", text: $amountText)
                    .keyboardType(.decimalPad)
                TextField("Merchant / description", text: $merchant)
                Picker("Category", selection: $category) {
                    ForEach(allCategories, id: \.self) { Text($0).tag($0) }
                }
                Picker("Type", selection: $type) {
                    Text("Debit").tag("debit")
                    Text("Credit").tag("credit")
                }
                DatePicker("Date", selection: $date)
            }
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(Decimal(string: amountText) == nil || merchant.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let amount = Decimal(string: amountText), amount > 0 else { return }
        let raw = "MANUAL|\(merchant)|\(amount)|\(date.timeIntervalSince1970)"
        let tx = Transaction(
            amount: amount,
            merchant: merchant,
            category: category,
            account: "manual",
            type: type,
            date: date,
            rawMessage: raw,
            messageHash: LogExpenseIntent.sha256(raw),
            isManuallyEdited: true
        )
        context.insert(tx)
        try? context.save()
        dismiss()
    }
}
