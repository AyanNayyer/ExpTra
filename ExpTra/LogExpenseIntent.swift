//
//  LogExpenseIntent.swift
//  ExpenseTracker
//
//  The App Intent that Shortcuts automations call when a bank SMS arrives.
//  Runs in the BACKGROUND (openAppWhenRun = false) — parses, categorizes,
//  dedupes, and saves. Fully on-device.
//

import AppIntents
import SwiftData
import CryptoKit
import Foundation

struct LogExpenseIntent: AppIntent {

    static var title: LocalizedStringResource = "Log Expense From Message"
    static var description = IntentDescription(
        "Parses a bank SMS/email text and logs the transaction on-device. No data leaves your phone."
    )

    /// false (default) = never bring the app to the foreground.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message Text")
    var messageText: String

    @Parameter(title: "Sender", default: "")
    var sender: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log expense from \(\.$messageText)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = Store.container.mainContext

        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Empty message — skipped.")
        }

        // 1. Dedupe (same SMS delivered twice / automation double-fire).
        let hash = Self.sha256(trimmed)
        var dupCheck = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.messageHash == hash }
        )
        dupCheck.fetchLimit = 1
        if let _ = try? context.fetch(dupCheck).first {
            return .result(dialog: "Already logged.")
        }

        // 2. Load user templates + category rules.
        let templateDescriptor = FetchDescriptor<MessageTemplate>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let templates = (try? context.fetch(templateDescriptor)) ?? []
        let rules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []

        // 3. Parse: user templates first, generic fallback second.
        let parsed = TemplateEngine.parse(trimmed, templates: templates)
            ?? GenericParser.parse(trimmed)

        guard let parsed else {
            return .result(dialog: "Not recognized as a transaction — skipped.")
        }

        // 4. Categorize (user rules win over defaults).
        let category = Categorizer.category(
            merchant: parsed.merchant,
            rawMessage: trimmed,
            type: parsed.type,
            userRules: rules
        )

        // 5. Persist.
        let tx = Transaction(
            amount: parsed.amount,
            merchant: parsed.merchant,
            category: category,
            account: parsed.account,
            type: parsed.type,
            date: .now,
            rawMessage: trimmed,
            messageHash: hash
        )
        context.insert(tx)
        try context.save()

        return .result(dialog: "Logged ₹\(parsed.amount) at \(parsed.merchant) — \(category)")
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Make the intent discoverable in Shortcuts / Siri

struct ExpenseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: ["Log expense in \(.applicationName)"],
            shortTitle: "Log Expense",
            systemImageName: "indianrupeesign.circle"
        )
    }
}
