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

/// A lightweight copy of a Transaction so a delete can be undone by re-inserting.
struct TxSnapshot {
    let amount: Decimal
    let merchant, category, account, type: String
    let date: Date
    let rawMessage, messageHash: String
    let isManuallyEdited: Bool

    init(_ t: Transaction) {
        amount = t.amount; merchant = t.merchant; category = t.category
        account = t.account; type = t.type; date = t.date
        rawMessage = t.rawMessage; messageHash = t.messageHash
        isManuallyEdited = t.isManuallyEdited
    }

    func makeTransaction() -> Transaction {
        Transaction(amount: amount, merchant: merchant, category: category,
                    account: account, type: type, date: date,
                    rawMessage: rawMessage, messageHash: messageHash,
                    isManuallyEdited: isManuallyEdited)
    }
}

/// Friendly label for an account code.
func accountLabel(_ account: String) -> String {
    switch account {
    case "manual": return "Added manually"
    case "unknown", "": return "Unset"
    default: return account
    }
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]
    @Query(sort: \PendingMessage.createdAt, order: .reverse)
    private var pending: [PendingMessage]
    @Query private var rules: [CategoryRule]
    @Query(sort: \ExpenseCategory.name) private var customCategories: [ExpenseCategory]

    @State private var searchText = ""
    @State private var showManualAdd = false
    @State private var filterCategory: String?
    @State private var filterType: String?
    @State private var filterAccount: String?
    @State private var lastDeleted: [TxSnapshot] = []
    @State private var undoToken = 0

    private var allCategories: [String] {
        DefaultData.allCategories(custom: customCategories, rules: rules)
    }
    private var categoriesInUse: [String] { Set(transactions.map(\.category)).sorted() }
    private var accountsInUse: [String] { Set(transactions.map(\.account)).sorted() }
    private var hasActiveFilter: Bool {
        filterCategory != nil || filterType != nil || filterAccount != nil
    }

    private var filtered: [Transaction] {
        var result = transactions
        if let c = filterCategory { result = result.filter { $0.category == c } }
        if let t = filterType { result = result.filter { $0.type == t } }
        if let a = filterAccount { result = result.filter { $0.account == a } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.merchant.lowercased().contains(q) ||
                $0.category.lowercased().contains(q) ||
                $0.rawMessage.lowercased().contains(q)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if !pending.isEmpty {
                    Section {
                        NavigationLink {
                            ReviewView()
                        } label: {
                            Label("\(pending.count) message\(pending.count == 1 ? "" : "s") need review",
                                  systemImage: "questionmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    ForEach(filtered) { tx in
                        NavigationLink(value: tx) {
                            TransactionRow(tx: tx)
                        }
                        .contextMenu { rowMenu(tx) }
                    }
                    .onDelete(perform: delete)
                } header: {
                    if hasActiveFilter {
                        Text("\(filtered.count) shown · filtered")
                    }
                }
            }
            .navigationTitle("Transactions")
            .navigationDestination(for: Transaction.self) { tx in
                TransactionEditView(tx: tx)
            }
            .searchable(text: $searchText,
                        prompt: "Search merchant, category, text")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .primaryAction) {
                    Button { showManualAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showManualAdd) {
                ManualAddView()
            }
            .overlay { emptyOverlay }
            .overlay(alignment: .bottom) { undoBanner }
        }
    }

    // MARK: subviews

    private var filterMenu: some View {
        Menu {
            Picker("Category", selection: $filterCategory) {
                Text("All Categories").tag(String?.none)
                ForEach(categoriesInUse, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker("Type", selection: $filterType) {
                Text("All Types").tag(String?.none)
                Text("Debit").tag(Optional("debit"))
                Text("Credit").tag(Optional("credit"))
            }
            Picker("Account", selection: $filterAccount) {
                Text("All Accounts").tag(String?.none)
                ForEach(accountsInUse, id: \.self) { acc in
                    Text(accountLabel(acc)).tag(Optional(acc))
                }
            }
            if hasActiveFilter {
                Divider()
                Button(role: .destructive) {
                    filterCategory = nil; filterType = nil; filterAccount = nil
                } label: {
                    Label("Clear Filters", systemImage: "xmark")
                }
            }
        } label: {
            Image(systemName: hasActiveFilter
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private func rowMenu(_ tx: Transaction) -> some View {
        Menu("Set Category") {
            ForEach(allCategories, id: \.self) { c in
                Button {
                    setCategory(c, for: tx)
                } label: {
                    if tx.category == c {
                        Label(c, systemImage: "checkmark")
                    } else {
                        Text(c)
                    }
                }
            }
        }
        Button(role: .destructive) {
            snapshotAndDelete([tx])
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if transactions.isEmpty && pending.isEmpty {
            ContentUnavailableView(
                "No transactions yet",
                systemImage: "list.bullet.rectangle",
                description: Text("They'll appear automatically when bank messages arrive, or add one with +.")
            )
        } else if filtered.isEmpty && pending.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No transactions match your search or filters.")
            )
        }
    }

    @ViewBuilder
    private var undoBanner: some View {
        if !lastDeleted.isEmpty {
            HStack {
                Text("Deleted \(lastDeleted.count) transaction\(lastDeleted.count == 1 ? "" : "s")")
                    .font(.callout)
                Spacer()
                Button("Undo") { undoDelete() }
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undoToken) {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { lastDeleted = [] }
            }
        }
    }

    // MARK: actions

    private func setCategory(_ category: String, for tx: Transaction) {
        tx.category = category
        tx.isManuallyEdited = true
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        snapshotAndDelete(offsets.map { filtered[$0] })
    }

    private func snapshotAndDelete(_ txns: [Transaction]) {
        guard !txns.isEmpty else { return }
        let snaps = txns.map(TxSnapshot.init)
        for t in txns { context.delete(t) }
        try? context.save()
        withAnimation { lastDeleted = snaps }
        undoToken += 1
    }

    private func undoDelete() {
        for snap in lastDeleted { context.insert(snap.makeTransaction()) }
        try? context.save()
        withAnimation { lastDeleted = [] }
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
    @State private var amountText = ""
    @State private var loaded = false

    private var allCategories: [String] {
        // Always include the transaction's own category so the Picker can show it,
        // even if it's a one-off that has no rule or custom-category backing it.
        var set = Set(DefaultData.allCategories(custom: customCategories, rules: rules))
        set.insert(tx.category)
        return set.sorted()
    }

    private var amountIsValid: Bool {
        if let a = Decimal(string: amountText), a > 0 { return true }
        return false
    }

    /// The stable identifier a "always use this category" rule will match on —
    /// the UPI VPA when present, otherwise the merchant name.
    private var ruleKey: String {
        Categorizer.stableMatchKey(merchant: tx.merchant, rawMessage: tx.rawMessage)
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Amount (₹)", text: $amountText)
                    .keyboardType(.decimalPad)
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

                Toggle("Always use this category for \"\(ruleKey)\"",
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
                .disabled(!amountIsValid)
        }
        .navigationTitle("Edit Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            amountText = "\(tx.amount)"
        }
    }

    private func save() {
        if let amount = Decimal(string: amountText), amount > 0 {
            tx.amount = amount
        }
        let newCategory = customCategory.trimmingCharacters(in: .whitespaces)
        if !newCategory.isEmpty { tx.category = newCategory }
        tx.isManuallyEdited = true

        let key = ruleKey
        if createRule && !key.isEmpty {
            let rule = CategoryRule(matchText: key, category: tx.category)
            context.insert(rule)

            if applyToExisting {
                let needle = key.lowercased()
                let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
                for other in all where other.persistentModelID != tx.persistentModelID {
                    // Match on merchant OR raw message so VPA-based keys catch
                    // past transactions too (the VPA lives in the raw text).
                    let hay = (other.merchant + " " + other.rawMessage).lowercased()
                    if hay.contains(needle) && !other.isManuallyEdited {
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

// MARK: - Review ambiguous messages

struct ReviewView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PendingMessage.createdAt, order: .reverse)
    private var pending: [PendingMessage]

    var body: some View {
        List {
            ForEach(pending) { item in
                NavigationLink {
                    ReviewConfirmView(pending: item)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.rawMessage)
                            .font(.callout)
                            .lineLimit(2)
                        Label(item.reason, systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .onDelete(perform: dismissItems)
        }
        .navigationTitle("Needs Review")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if pending.isEmpty {
                ContentUnavailableView(
                    "All caught up",
                    systemImage: "checkmark.circle",
                    description: Text("Messages we're unsure about show up here so nothing is missed.")
                )
            }
        }
    }

    private func dismissItems(at offsets: IndexSet) {
        // Swiping a message away is a "not a transaction" verdict — remember the
        // shape so it's auto-skipped next time instead of returning for review.
        for i in offsets {
            MessageDecision.record(rawMessage: pending[i].rawMessage,
                                   isTransaction: false, in: context)
            context.delete(pending[i])
        }
        try? context.save()
    }
}

// MARK: - Confirm one pending message

struct ReviewConfirmView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let pending: PendingMessage

    @Query private var rules: [CategoryRule]
    @Query(sort: \ExpenseCategory.name) private var customCategories: [ExpenseCategory]

    @State private var amountText = ""
    @State private var merchant = ""
    @State private var type = "debit"
    @State private var category = "Uncategorized"
    @State private var date = Date()
    @State private var loaded = false

    private var allCategories: [String] {
        DefaultData.allCategories(custom: customCategories, rules: rules)
    }

    var body: some View {
        Form {
            Section("Why we're asking") {
                Text(pending.reason)
                    .font(.callout)
            }

            Section("Original message") {
                Text(pending.rawMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Details") {
                TextField("Amount (₹)", text: $amountText)
                    .keyboardType(.decimalPad)
                TextField("Merchant / description", text: $merchant)
                Picker("Type", selection: $type) {
                    Text("Debit").tag("debit")
                    Text("Credit").tag("credit")
                }
                Picker("Category", selection: $category) {
                    ForEach(allCategories, id: \.self) { Text($0).tag($0) }
                }
                DatePicker("Date", selection: $date)
            }

            Section {
                Button("Add transaction") { save() }
                    .fontWeight(.semibold)
                    .disabled(Decimal(string: amountText) == nil || merchant.isEmpty)
                Button("Not a transaction", role: .destructive) { discard() }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        amountText = pending.guessedAmount > 0 ? "\(pending.guessedAmount)" : ""
        merchant = pending.guessedMerchant == "Unknown" ? "" : pending.guessedMerchant
        type = pending.guessedType
        date = pending.createdAt
        category = Categorizer.category(merchant: merchant,
                                        rawMessage: pending.rawMessage,
                                        type: type,
                                        userRules: rules)
    }

    private func save() {
        guard let amount = Decimal(string: amountText), amount > 0 else { return }
        let tx = Transaction(
            amount: amount,
            merchant: merchant.isEmpty ? "Unknown" : merchant,
            category: category,
            account: "unknown",
            type: type,
            date: date,
            rawMessage: pending.rawMessage,
            messageHash: pending.messageHash,   // preserve dedupe key
            isManuallyEdited: true
        )
        context.insert(tx)
        // Remember this shape so identical/similar messages auto-add next time.
        MessageDecision.record(rawMessage: pending.rawMessage,
                               isTransaction: true, in: context)
        context.delete(pending)
        try? context.save()
        dismiss()
    }

    private func discard() {
        // Remember this shape as "not a transaction" so it's auto-skipped next time.
        MessageDecision.record(rawMessage: pending.rawMessage,
                               isTransaction: false, in: context)
        context.delete(pending)
        try? context.save()
        dismiss()
    }
}
