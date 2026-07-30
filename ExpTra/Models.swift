//
//  Models.swift
//  ExpenseTracker
//
//  SwiftData models + default seed data (categories, bank templates).
//

import Foundation
import SwiftData

// MARK: - Transaction

@Model
final class Transaction {
    var amount: Decimal
    var merchant: String
    var category: String
    var account: String        // e.g. "XX1234"
    var type: String           // "debit" | "credit"
    var date: Date
    var rawMessage: String     // original SMS/email text, kept for re-parsing
    var messageHash: String    // dedupe key
    var isManuallyEdited: Bool

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
    var name: String           // "HDFC UPI debit"
    var bank: String           // "HDFC"
    var template: String       // pattern with tokens
    var type: String           // "debit" | "credit" | "ignore"
    var isEnabled: Bool
    var sortOrder: Int

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
    var matchText: String      // matched case-insensitively, "contains"
    var category: String
    var createdAt: Date

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
    var name: String
    var createdAt: Date

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
    }
}

// MARK: - PendingMessage
//
// A message that looked money-related but couldn't be parsed with confidence
// (direction unclear, both debit & credit wording, etc.). Instead of silently
// dropping it, we keep it here and prompt the user to confirm or dismiss it
// in-app. Best-guess values pre-fill the confirmation screen.

@Model
final class PendingMessage {
    var rawMessage: String
    var messageHash: String     // same dedupe key as Transaction
    var reason: String          // why it needs review
    var guessedAmount: Decimal  // 0 if unknown
    var guessedMerchant: String
    var guessedType: String     // best guess: "debit" | "credit"
    var createdAt: Date

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
