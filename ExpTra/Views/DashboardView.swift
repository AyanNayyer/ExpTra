//
//  DashboardView.swift
//  ExpenseTracker
//
//  Monthly spend total, category donut chart, and recent transactions.
//

import SwiftUI
import SwiftData
import Charts

enum DashboardMode: String, CaseIterable, Identifiable {
    case spending = "Spending"
    case income = "Income"
    var id: String { rawValue }
}

struct DashboardView: View {
    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var monthOffset = 0   // 0 = current month, -1 = last month…
    @State private var selectedAngle: Double?   // raw angular value from a tap on the donut
    @State private var mode: DashboardMode = .spending

    private var calendar: Calendar { .current }

    private var displayedMonth: Date {
        calendar.date(byAdding: .month, value: monthOffset, to: .now) ?? .now
    }

    private var monthTransactions: [Transaction] {
        transactions.filter {
            calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month)
        }
    }

    private var totalSpent: Double {
        monthTransactions.filter { $0.type == "debit" }
            .reduce(0) { $0 + $1.amountDouble }
    }

    private var totalIncome: Double {
        monthTransactions.filter { $0.type == "credit" }
            .reduce(0) { $0 + $1.amountDouble }
    }

    /// Debits minus credits for the whole month — the final net figure.
    private var netAmount: Double { totalSpent - totalIncome }

    private struct CategoryTotal: Identifiable {
        var id: String { category }   // stable across recomputes so selection/animation work
        let category: String
        let total: Double
    }

    /// Maps the tapped angular value onto the category whose sector was hit.
    private var selectedCategory: CategoryTotal? {
        guard let selectedAngle else { return nil }
        var cumulative = 0.0
        for item in categoryTotals {
            cumulative += item.total
            if selectedAngle < cumulative { return item }
        }
        return nil
    }

    /// Per-category debit and credit sums for the month.
    private var categorySums: [String: (debit: Double, credit: Double)] {
        var dict: [String: (debit: Double, credit: Double)] = [:]
        for t in monthTransactions {
            var entry = dict[t.category] ?? (0, 0)
            if t.type == "debit" { entry.debit += t.amountDouble }
            else { entry.credit += t.amountDouble }
            dict[t.category] = entry
        }
        return dict
    }

    /// Net totals per category for the active mode. In Spending, credits (refunds,
    /// income tagged to the same category) are deducted from debits and only
    /// net-positive categories show; Income is the mirror image.
    private var categoryTotals: [CategoryTotal] {
        categorySums.compactMap { category, sums in
            let net = mode == .spending
                ? sums.debit - sums.credit
                : sums.credit - sums.debit
            return net > 0 ? CategoryTotal(category: category, total: net) : nil
        }
        .sorted { $0.total > $1.total }
    }

    /// Sum of the visible sectors — the net spent (or net received) this month.
    private var activeTotal: Double {
        categoryTotals.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    monthPicker
                    summaryCards
                    modePicker
                    if categoryTotals.isEmpty {
                        emptyState
                    } else {
                        donutChart
                        categoryList
                    }
                }
                .padding()
            }
            .onChange(of: monthOffset) { _, _ in selectedAngle = nil }
            .navigationTitle("Dashboard")
        }
    }

    // MARK: subviews

    private var monthPicker: some View {
        HStack {
            Button { monthOffset -= 1 } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button { monthOffset += 1 } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(monthOffset >= 0)
        }
        .padding(.horizontal, 4)
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(title: "Spent", value: totalSpent, color: .red,
                        icon: "arrow.up.circle.fill")
            summaryCard(title: "Received", value: totalIncome, color: .green,
                        icon: "arrow.down.circle.fill")
            summaryCard(title: "Net", value: netAmount,
                        color: netAmount >= 0 ? .primary : .green,
                        icon: "equal.circle.fill")
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(DashboardMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { _, _ in selectedAngle = nil }
    }

    private func summaryCard(title: String, value: Double,
                             color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value, format: .currency(code: "INR").precision(.fractionLength(0)))
                .font(.title3.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var donutChart: some View {
        Chart(categoryTotals) { item in
            SectorMark(
                angle: .value("Amount", item.total),
                innerRadius: .ratio(0.62),
                outerRadius: .ratio(selectedCategory?.id == item.id ? 1.0 : 0.9),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(by: .value("Category", item.category))
            .opacity(selectedCategory == nil || selectedCategory?.id == item.id ? 1 : 0.35)
        }
        .chartAngleSelection(value: $selectedAngle)
        .chartBackground { _ in donutCenter }
        .frame(height: 240)
        .chartLegend(position: .bottom, alignment: .center, spacing: 8)
        .animation(.easeInOut(duration: 0.25), value: selectedCategory?.id)
    }

    /// Center readout: tapped category + its amount and share, or the net total.
    private var donutCenter: some View {
        VStack(spacing: 3) {
            if let sel = selectedCategory {
                Text(sel.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(sel.total,
                     format: .currency(code: "INR").precision(.fractionLength(0)))
                    .font(.title3.bold())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if activeTotal > 0 {
                    Text("\(Int((sel.total / activeTotal * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(mode == .spending ? "Net spent" : "Net received")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(activeTotal,
                     format: .currency(code: "INR").precision(.fractionLength(0)))
                    .font(.title3.bold())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("Tap a slice")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 120)
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(categoryTotals) { item in
                HStack {
                    Text(item.category)
                    Spacer()
                    Text(item.total,
                         format: .currency(code: "INR").precision(.fractionLength(0)))
                        .fontWeight(.medium)
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            mode == .spending ? "No net spending this month" : "No income this month",
            systemImage: "tray",
            description: Text(mode == .spending
                ? "Auto-captured expenses will appear here, or add them via Import in Settings."
                : "Credits like salary or refunds will appear here.")
        )
        .padding(.top, 40)
    }
}
