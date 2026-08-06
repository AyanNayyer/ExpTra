//
//  Models.swift
//  ExpenseTracker
//
//  SwiftData models + default seed data (categories, bank templates).
//
//  Every stored property has a default value so the schema is compatible with
//  optional CloudKit syncing (see Store in ExpenseTrackerApp). Initializers
//  still set real values, so defaults only matter to the CloudKit schema.
//

import Foundation
import SwiftData

// MARK: - Transaction

@Model
final class Transaction {
    var amount: Decimal = 0
    var merchant: String = ""
    var category: String = "Uncategorized"
    var account: String = "unknown"    // e.g. "XX1234"
    var type: String = "debit"         // "debit" | "credit"
    var date: Date = Date.now
    var rawMessage: String = ""        // original SMS/email text, kept for re-parsing
    var messageHash: String = ""       // dedupe key
    var isManuallyEdited: Bool = false

    init(amount: Decimal,
         merchant: String,
         category: String,
         account: String,
         type: String,
         date: Date = .now,
         rawMessage: String,
         messageHash: String,
         isManuallyEdited: Bool = false) {
        self.amount = amount
        self.merchant = merchant
        self.category = category
        self.account = account
        self.type = type
        self.date = date
        self.rawMessage = rawMessage
        self.messageHash = messageHash
        self.isManuallyEdited = isManuallyEdited
    }

    var amountDouble: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}

// MARK: - MessageTemplate
//
// A user-editable pattern describing one bank's SMS format.
// Tokens: {amount} {account} {merchant} {skip}
// Example:  "Rs.{amount} debited from A/c {account} to {merchant} on"

@Model
final class MessageTemplate {
    var name: String = ""              // "HDFC UPI debit"
    var bank: String = ""              // "HDFC"
    var template: String = ""          // pattern with tokens
    var type: String = "debit"         // "debit" | "credit" | "ignore"
    var isEnabled: Bool = true
    var sortOrder: Int = 0

    init(name: String,
         bank: String,
         template: String,
         type: String,
         isEnabled: Bool = true,
         sortOrder: Int = 0) {
        self.name = name
        self.bank = bank
        self.template = template
        self.type = type
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
    }
}

// MARK: - CategoryRule
//
// "Any merchant/message containing X gets category Y."
// User rules always win over the built-in keyword defaults.

@Model
final class CategoryRule {
    var matchText: String = ""         // matched case-insensitively, "contains"
    var category: String = ""
    var createdAt: Date = Date.now

    init(matchText: String, category: String, createdAt: Date = .now) {
        self.matchText = matchText
        self.category = category
        self.createdAt = createdAt
    }
}

// MARK: - ExpenseCategory
//
// A user-created spending category. These are merged with the built-in
// DefaultData.categories everywhere a category can be picked.

@Model
final class ExpenseCategory {
    var name: String = ""
    var createdAt: Date = Date.now

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}

// MARK: - Budget
//
// A monthly spending limit for one category (or "__overall__" for the whole
// month). Budgets never block spending — they just surface overspend.

@Model
final class Budget {
    var category: String = ""          // a category name, or Budget.overallKey
    var limit: Decimal = 0
    var createdAt: Date = Date.now

    init(category: String, limit: Decimal, createdAt: Date = .now) {
        self.category = category
        self.limit = limit
        self.createdAt = createdAt
    }

    static let overallKey = "__overall__"

    var isOverall: Bool { category == Budget.overallKey }
    var displayName: String { isOverall ? "Overall (all categories)" : category }
    var limitDouble: Double { NSDecimalNumber(decimal: limit).doubleValue }
}

// MARK: - PendingMessage
//
// A message that looked money-related but couldn't be parsed with confidence
// (direction unclear, both debit & credit wording, etc.). Instead of silently
// dropping it, we keep it here and prompt the user to confirm or dismiss it
// in-app. Best-guess values pre-fill the confirmation screen.

@Model
final class PendingMessage {
    var rawMessage: String = ""
    var messageHash: String = ""       // same dedupe key as Transaction
    var reason: String = ""            // why it needs review
    var guessedAmount: Decimal = 0     // 0 if unknown
    var guessedMerchant: String = ""
    var guessedType: String = "debit"  // best guess: "debit" | "credit"
    var createdAt: Date = Date.now

    init(rawMessage: String,
         messageHash: String,
         reason: String,
         guessedAmount: Decimal = 0,
         guessedMerchant: String = "",
         guessedType: String = "debit",
         createdAt: Date = .now) {
        self.rawMessage = rawMessage
        self.messageHash = messageHash
        self.reason = reason
        self.guessedAmount = guessedAmount
        self.guessedMerchant = guessedMerchant
        self.guessedType = guessedType
        self.createdAt = createdAt
    }
}

// MARK: - MessageDecision
//
// A remembered verdict about a *shape* of message. When the user confirms a
// pending message as a transaction (or dismisses it as "not a transaction"),
// we store the message's normalized signature here. The next time a message
// with the same shape arrives and would otherwise be ambiguous, we apply the
// remembered verdict automatically instead of asking again — auto-adding it or
// silently skipping it. Only genuinely new/unseen shapes stay in review.

@Model
final class MessageDecision {
    var signature: String = ""       // normalized skeleton (see MessageSignature)
    var isTransaction: Bool = true   // true → auto-add, false → auto-skip
    var sample: String = ""          // an example message, shown when managing rules
    var createdAt: Date = Date.now

    init(signature: String,
         isTransaction: Bool,
         sample: String = "",
         createdAt: Date = .now) {
        self.signature = signature
        self.isTransaction = isTransaction
        self.sample = sample
        self.createdAt = createdAt
    }
}

extension MessageDecision {
    /// Remember the user's verdict about a message's shape so similar messages
    /// are handled automatically from now on. If a decision for the same shape
    /// already exists it is updated (latest verdict wins) rather than duplicated.
    @MainActor
    static func record(rawMessage: String,
                       isTransaction: Bool,
                       in context: ModelContext) {
        let signature = MessageSignature.skeleton(rawMessage)
        guard !signature.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<MessageDecision>())) ?? []
        if let match = existing.first(where: { $0.signature == signature }) {
            match.isTransaction = isTransaction
            match.sample = rawMessage
            match.createdAt = .now
        } else {
            context.insert(MessageDecision(signature: signature,
                                           isTransaction: isTransaction,
                                           sample: rawMessage))
        }
    }
}

// MARK: - Defaults

enum DefaultData {

    static let categories: [String] = [
        "Food & Dining", "Groceries", "Transport", "Shopping",
        "Subscriptions", "Utilities", "Health", "Cash",
        "Investments", "Rent & Home", "Entertainment", "Travel",
        "Education", "Income", "Transfers", "Uncategorized"
    ]

    /// The full, de-duplicated, sorted set of categories a user can choose from:
    /// the built-in defaults plus any custom categories and categories referenced
    /// by existing rules.
    static func allCategories(custom: [ExpenseCategory],
                              rules: [CategoryRule]) -> [String] {
        var set = Set(categories)
        custom.forEach { set.insert($0.name) }
        rules.forEach { set.insert($0.category) }
        return set.sorted()
    }

    /// Built-in keyword → category fallbacks (user CategoryRules override these).
    static let defaultKeywordRules: [(keywords: [String], category: String)] = [
        (["swiggy", "zomato", "dominos", "mcdonald", "kfc", "pizza"], "Food & Dining"),
        (["bigbasket", "blinkit", "zepto", "dmart", "instamart", "grofers"], "Groceries"),
        (["uber", "ola", "rapido", "irctc", "redbus", "metro", "fastag", "petrol", "fuel", "hpcl", "iocl", "bpcl"], "Transport"),
        (["amazon", "flipkart", "myntra", "ajio", "meesho", "nykaa"], "Shopping"),
        (["netflix", "spotify", "hotstar", "prime video", "youtube", "apple.com"], "Subscriptions"),
        (["jio", "airtel", "vodafone", "bsnl", "electricity", "bescom", "tneb", "broadband", "gas"], "Utilities"),
        (["pharmeasy", "apollo", "1mg", "hospital", "clinic", "medplus", "pharmacy"], "Health"),
        (["atm", "cash withdrawal", "cash wdl", "withdrawn"], "Cash"),
        (["sip", "zerodha", "groww", "mutual fund", "nps", "kuvera", "upstox"], "Investments"),
        (["rent", "maintenance"], "Rent & Home"),
        (["bookmyshow", "pvr", "inox", "cinepolis"], "Entertainment"),
        (["makemytrip", "goibibo", "oyo", "airbnb", "indigo", "vistara", "air india"], "Travel"),
        // Note: don't key Income on "credited" — it appears in debit SMS too
        // (e.g. "cashback credited"). Credits already fall back to Income.
        (["salary"], "Income")
    ]

    struct SeedTemplate {
        let name: String
        let bank: String
        let template: String
        let type: String
    }

    /// Starter templates covering common Indian bank SMS formats.
    /// Edit these inside the app (Templates tab) to exactly match YOUR banks —
    /// paste one of your real messages and replace the variable parts with tokens.
    static let seedTemplates: [SeedTemplate] = [
        .init(name: "Generic UPI debit (to VPA)",
              bank: "Generic",
              template: "Rs.{amount} debited from A/c {account} to {merchant}",
              type: "debit"),
        .init(name: "Generic debit (at merchant)",
              bank: "Generic",
              template: "Rs.{amount} debited from A/c {account} at {merchant}",
              type: "debit"),
        .init(name: "Card spend (INR)",
              bank: "Generic",
              template: "INR {amount} spent on Card {account} at {merchant}",
              type: "debit"),
        .init(name: "Card spend (Rs, using/on card)",
              bank: "Generic",
              template: "Rs.{amount} spent using Card {account} at {merchant}",
              type: "debit"),
        .init(name: "UPI paid to",
              bank: "Generic",
              template: "Rs {amount} paid to {merchant} from A/c {account}",
              type: "debit"),
        .init(name: "Simple debited for",
              bank: "Generic",
              template: "A/c {account} debited for Rs {amount}",
              type: "debit"),
        .init(name: "Generic credit",
              bank: "Generic",
              template: "Rs.{amount} credited to A/c {account}",
              type: "credit"),
        .init(name: "NEFT/IMPS credit",
              bank: "Generic",
              template: "INR {amount} credited to A/c {account}",
              type: "credit")
    ]
}
