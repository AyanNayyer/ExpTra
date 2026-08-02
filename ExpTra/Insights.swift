//
//  Insights.swift
//  ExpenseTracker
//
//  Spending analytics: monthly trend data, a human-readable summary, an
//  optional on-device natural-language insight (Apple's FoundationModels when
//  available, with a heuristic fallback), and trend-change notifications.
//  Everything is computed on device — no network.
//

import Foundation
import UserNotifications

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Trend data point

struct MonthStat: Identifiable {
    let id: Date        // first day of the month
    let label: String   // "Jul"
    let spent: Double    // gross debits
    let income: Double   // gross credits
}

// MARK: - Computed insight bundle

struct InsightData {
    let monthly: [MonthStat]
    let summary: String                        // heuristic sentences, always available
    let factsPrompt: String                    // compact facts for the language model
    let alert: (title: String, body: String)?  // significant change worth notifying about
}

// MARK: - Engine (pure functions)

enum InsightEngine {

    static let alertsEnabledKey = "insightAlertsEnabled"

    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "INR").precision(.fractionLength(0)))
    }

    static func monthTag(_ date: Date, _ cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    /// Gross debit/credit totals for each of the last `monthsBack` months, oldest first.
    static func monthlyTotals(transactions: [Transaction],
                              monthsBack: Int = 6,
                              calendar cal: Calendar = .current,
                              now: Date = .now) -> [MonthStat] {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMM")
        var result: [MonthStat] = []
        for offset in stride(from: monthsBack - 1, through: 0, by: -1) {
            guard let monthDate = cal.date(byAdding: .month, value: -offset, to: now) else { continue }
            let txns = transactions.filter {
                cal.isDate($0.date, equalTo: monthDate, toGranularity: .month)
            }
            let spent = txns.filter { $0.type == "debit" }.reduce(0) { $0 + $1.amountDouble }
            let income = txns.filter { $0.type == "credit" }.reduce(0) { $0 + $1.amountDouble }
            let start = cal.date(from: cal.dateComponents([.year, .month], from: monthDate)) ?? monthDate
            result.append(MonthStat(id: start, label: fmt.string(from: monthDate),
                                    spent: spent, income: income))
        }
        return result
    }

    static func compute(transactions: [Transaction],
                        calendar cal: Calendar = .current,
                        now: Date = .now) -> InsightData {
        let monthly = monthlyTotals(transactions: transactions, calendar: cal, now: now)
        let current = monthly.last
        let previous = monthly.count >= 2 ? monthly[monthly.count - 2] : nil

        // This month's net spend by category.
        let curTxns = transactions.filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
        var catNet: [String: Double] = [:]
        for t in curTxns {
            catNet[t.category, default: 0] += (t.type == "debit" ? t.amountDouble : -t.amountDouble)
        }
        let topCategories = catNet.filter { $0.value > 0 }.sorted { $0.value > $1.value }

        let curSpent = current?.spent ?? 0
        let prevSpent = previous?.spent ?? 0

        // Percent change vs last month.
        var changePct: Double?
        if prevSpent > 0 { changePct = (curSpent - prevSpent) / prevSpent * 100 }

        // Heuristic summary.
        var summary: String
        if curSpent == 0 {
            summary = "No spending recorded this month yet."
        } else {
            summary = "This month you've spent \(money(curSpent))."
            if let pct = changePct {
                let dir = pct >= 0 ? "more" : "less"
                summary += " That's \(abs(Int(pct.rounded())))% \(dir) than last month (\(money(prevSpent)))."
            }
            if let top = topCategories.first {
                summary += " Most went to \(top.key) (\(money(top.value)))."
            }
        }

        // Facts prompt for the language model.
        var facts = "Personal spending facts (currency ₹, India). "
        facts += "This month total spent: \(money(curSpent)). "
        facts += "Last month total spent: \(money(prevSpent)). "
        if let pct = changePct {
            facts += "Change vs last month: \(pct >= 0 ? "+" : "")\(Int(pct.rounded()))%. "
        }
        if !topCategories.isEmpty {
            let tops = topCategories.prefix(3)
                .map { "\($0.key) \(money($0.value))" }
                .joined(separator: ", ")
            facts += "Top categories this month: \(tops). "
        }

        // Alert on a large month-over-month swing.
        var alert: (title: String, body: String)?
        if let pct = changePct {
            let diff = curSpent - prevSpent
            if pct >= 25 && diff >= 1000 {
                alert = ("Spending is up this month",
                         "You've spent \(money(curSpent)) so far — \(Int(pct.rounded()))% more than last month.")
            } else if pct <= -25 && diff <= -1000 {
                alert = ("Spending is down — nice!",
                         "You've spent \(money(curSpent)) this month, \(abs(Int(pct.rounded())))% less than last month.")
            }
        }

        return InsightData(monthly: monthly, summary: summary, factsPrompt: facts, alert: alert)
    }
}

// MARK: - Natural-language generator (on-device model, heuristic fallback)

enum InsightGenerator {

    /// Returns a friendly insight. Uses Apple's on-device model when available,
    /// otherwise returns the heuristic fallback so there's always something useful.
    static func generate(prompt: String, fallback: String) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { return fallback }
            do {
                let session = LanguageModelSession(instructions: """
                    You are a concise, friendly personal-finance assistant. Given spending \
                    facts, write 2 short sentences of insight plus one practical tip. \
                    Keep amounts in ₹. No preamble, no lists, under 45 words.
                    """)
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? fallback : text
            } catch {
                return fallback
            }
        }
        #endif
        return fallback
    }

    /// Whether the on-device model is usable right now (for UI hints).
    static var onDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }
}

// MARK: - Trend notifications

enum TrendMonitor {

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// If enabled, notify at most once per calendar month when there's a
    /// significant month-over-month change.
    static func checkAndNotify(transactions: [Transaction], now: Date = .now) {
        guard UserDefaults.standard.bool(forKey: InsightEngine.alertsEnabledKey) else { return }
        let data = InsightEngine.compute(transactions: transactions, now: now)
        guard let alert = data.alert else { return }

        let key = "lastInsightNotifyMonth"
        let tag = InsightEngine.monthTag(now)
        guard UserDefaults.standard.string(forKey: key) != tag else { return }
        UserDefaults.standard.set(tag, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "insight-\(tag)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
