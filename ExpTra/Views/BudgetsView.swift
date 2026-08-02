//
//  BudgetsView.swift
//  ExpenseTracker
//
//  Monthly spending limits per category (or overall). Budgets never block
//  anything — they just show progress and flag overspend for the current month.
//

import SwiftUI
import SwiftData

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Budget.category) private var budgets: [Budget]
    @Query private var transactions: [Transaction]

    @State private var showAdd = false

    private var calendar: Calendar { .current }

    /// Net spend (debits − credits, floored at 0) this month for a category,
    /// or the whole month for the overall budget.
    private func spent(in category: String) -> Double {
        let month = transactions.filter {
            calendar.isDate($0.date, equalTo: .now, toGranularity: .month)
        }
        let relevant = category == Budget.overallKey
            ? month
            : month.filter { $0.category == category }
        let debit = relevant.filter { $0.type == "debit" }.reduce(0) { $0 + $1.amountDouble }
        let credit = relevant.filter { $0.type == "credit" }.reduce(0) { $0 + $1.amountDouble }
        return max(0, debit - credit)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(budgets) { budget in
                    budgetRow(budget)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddBudgetView() }
            .overlay {
                if budgets.isEmpty {
                    ContentUnavailableView(
                        "No budgets yet",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("Set a monthly limit per category with +. Budgets never block spending — they just show when you go over.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func budgetRow(_ budget: Budget) -> some View {
        let spentValue = spent(in: budget.category)
        let limit = budget.limitDouble
        let ratio = limit > 0 ? spentValue / limit : 0
        let over = spentValue > limit && limit > 0
        let fmt: FloatingPointFormatStyle<Double>.Currency = .currency(code: "INR").precision(.fractionLength(0))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(budget.displayName).fontWeight(.medium)
                Spacer()
                Text("\(spentValue, format: fmt) / \(limit, format: fmt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: min(max(ratio, 0), 1))
                .tint(over ? .red : (ratio > 0.8 ? .orange : .green))
            if over {
                Label("Over by \((spentValue - limit), format: fmt)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if limit > 0 {
                Text("\(Int((ratio * 100).rounded()))% used · \((limit - spentValue), format: fmt) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(budgets[i]) }
        try? context.save()
    }
}

// MARK: - Add / edit a budget

struct AddBudgetView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var budgets: [Budget]
    @Query private var rules: [CategoryRule]
    @Query(sort: \ExpenseCategory.name) private var customCategories: [ExpenseCategory]

    @State private var category = Budget.overallKey
    @State private var limitText = ""

    private var categories: [String] {
        DefaultData.allCategories(custom: customCategories, rules: rules)
    }

    private var alreadyBudgeted: Bool {
        budgets.contains { $0.category == category }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $category) {
                        Text("Overall (all categories)").tag(Budget.overallKey)
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Monthly limit (₹)", text: $limitText)
                        .keyboardType(.decimalPad)
                } footer: {
                    if alreadyBudgeted {
                        Text("A budget for this already exists — saving will update its limit.")
                    }
                }
            }
            .navigationTitle("New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(Decimal(string: limitText) == nil
                                  || (Decimal(string: limitText) ?? 0) <= 0)
                }
            }
        }
    }

    private func save() {
        guard let limit = Decimal(string: limitText), limit > 0 else { return }
        if let existing = budgets.first(where: { $0.category == category }) {
            existing.limit = limit
        } else {
            context.insert(Budget(category: category, limit: limit))
        }
        try? context.save()
        dismiss()
    }
}
