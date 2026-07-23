//
//  DashboardView.swift
//  ExpenseTracker
//
//  Monthly spend total, category donut chart, and recent transactions.
//

import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var monthOffset = 0   // 0 = current month, -1 = last month…
    @State private var selectedAngle: Double?   // raw angular value from a tap on the donut

    private var calendar: Calendar { .current }

    private var displayedMonth: Date {
        calendar.date(byAdding: .month, value: monthOffset, to: .now) ?? .now
    }

    private var monthTransactions: [Transaction] {
        transactions.filter {
            calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month)
        }
    }

    private var debits: [Transaction] {
        monthTransactions.filter { $0.type == "debit" }
    }

    private var totalSpent: Double {
        debits.reduce(0) { $0 + $1.amountDouble }
    }

    private var totalIncome: Double {
        monthTransactions.filter { $0.type == "credit" }
            .reduce(0) { $0 + $1.amountDouble }
    }

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

    private var categoryTotals: [CategoryTotal] {
        var dict: [String: Double] = [:]
        for t in debits { dict[t.category, default: 0] += t.amountDouble }
        return dict.map { CategoryTotal(category: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    monthPicker
                    summaryCards
                    if categoryTotals.isEmpty {
                        emptyState
                    } else {
                        donutChart
                        categoryList
                    }
                }
                .padding()
            }
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
        }
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

    /// Center readout: tapped category + its amount and share, or the month total.
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
                if totalSpent > 0 {
                    Text("\(Int((sel.total / totalSpent * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(totalSpent,
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
            "No transactions this month",
            systemImage: "tray",
            description: Text("Auto-captured expenses will appear here, or add them via Import in Settings.")
        )
        .padding(.top, 40)
    }
}
