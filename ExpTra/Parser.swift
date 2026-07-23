//
//  Parser.swift
//  ExpenseTracker
//
//  1. TemplateEngine — converts user templates ("Rs.{amount} debited from A/c
//     {account} to {merchant}") into regexes and parses messages with them.
//  2. GenericParser — regex fallback when no template matches.
//  3. Categorizer — user CategoryRules first, then built-in keyword map.
//

import Foundation

// MARK: - Parse result

struct ParsedTransaction {
    var amount: Decimal
    var merchant: String
    var account: String
    var type: String   // "debit" | "credit"
    var matchedBy: String  // template name or "generic"
}

// MARK: - Template engine

enum TemplateEngine {

    /// Token → capture pattern. Whitespace in templates is made flexible.
    private static let tokenPatterns: [String: String] = [
        "amount":   #"(?<amount>[\d,]+(?:\.\d{1,2})?)"#,
        "account":  #"(?<account>[Xx\*]{0,8}\d{2,8})"#,
        "merchant": #"(?<merchant>[A-Za-z0-9 @&.\-_]{2,45})"#,
        "skip":     #".{0,60}?"#
    ]

    /// Build an NSRegularExpression from a human-friendly template string.
    static func regex(from template: String) -> NSRegularExpression? {
        // 1. Escape everything literally.
        var pattern = NSRegularExpression.escapedPattern(for: template)

        // 2. Make whitespace flexible (one or more of any whitespace).
        while pattern.contains("  ") {
            pattern = pattern.replacingOccurrences(of: "  ", with: " ")
        }
        pattern = pattern.replacingOccurrences(of: " ", with: #"\s+"#)

        // 3. Swap escaped tokens for capture groups.
        //    escapedPattern may or may not escape braces depending on OS version,
        //    so handle both forms.
        for (token, capture) in tokenPatterns {
            pattern = pattern.replacingOccurrences(of: "\\{\(token)\\}", with: capture)
            pattern = pattern.replacingOccurrences(of: "{\(token)}", with: capture)
        }

        return try? NSRegularExpression(pattern: pattern,
                                        options: [.caseInsensitive])
    }

    /// Try every enabled template in order; first match wins.
    static func parse(_ text: String,
                      templates: [MessageTemplate]) -> ParsedTransaction? {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")

        for t in templates where t.isEnabled {
            guard let regex = regex(from: t.template) else { continue }
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, range: range) else { continue }

            func group(_ name: String) -> String? {
                let r = match.range(withName: name)
                guard r.location != NSNotFound,
                      let swiftRange = Range(r, in: cleaned) else { return nil }
                return String(cleaned[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let amountStr = group("amount"),
                  let amount = Decimal(string: amountStr.replacingOccurrences(of: ",", with: "")),
                  amount > 0
            else { continue }

            return ParsedTransaction(
                amount: amount,
                merchant: cleanMerchant(group("merchant") ?? "Unknown"),
                account: group("account") ?? "unknown",
                type: t.type,
                matchedBy: t.name
            )
        }
        return nil
    }

    /// Trim trailing junk words the merchant capture may have swallowed.
    static func cleanMerchant(_ raw: String) -> String {
        var m = raw
        let stopWords = [" on ", " via ", " ref ", " refno", " upi ref", " avl bal", " info"]
        let lower = m.lowercased()
        for stop in stopWords {
            if let r = lower.range(of: stop) {
                m = String(m[m.startIndex..<r.lowerBound])
                break
            }
        }
        return m.trimmingCharacters(in: CharacterSet(charactersIn: " .,-:"))
    }
}

// MARK: - Generic fallback parser

enum GenericParser {

    private static let amountPattern =
        #"(?:INR|Rs\.?|₹)\s*([\d,]+(?:\.\d{1,2})?)"#

    private static let accountPattern =
        #"(?:[Aa]/c(?:\s*[Nn]o\.?)?\s*[Xx\*]*(\d{2,8}))|(?:[Cc]ard\s+(?:ending\s+)?[Xx\*]*(\d{4}))"#

    private static let merchantPatterns = [
        #"(?:\bat|\bto|@)\s+([A-Za-z0-9 @&.\-_]{2,45}?)(?:\s+on\b|\s+via\b|\s+Ref\b|\.|,|$)"#,
        #"UPI[/-]([A-Za-z0-9.@_\-]{2,45})"#,
        #"Info:?\s*([A-Za-z0-9 @&.\-_]{2,45})"#
    ]

    private static let debitKeywords  = ["debited", "spent", "withdrawn",
                                         "paid", "purchase", "sent", "debit"]
    private static let creditKeywords = ["credited", "received", "deposited",
                                         "refund", "credit"]

    static func parse(_ text: String) -> ParsedTransaction? {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        let lower = cleaned.lowercased()

        // Reject obvious non-transactions.
        if lower.contains("otp") || lower.contains("one time password") { return nil }
        if lower.contains("offer") && !lower.contains("debited") { return nil }

        let isDebit  = debitKeywords.contains  { lower.contains($0) }
        let isCredit = creditKeywords.contains { lower.contains($0) }
        guard isDebit || isCredit else { return nil }

        guard let amountRaw = firstCapture(in: cleaned, pattern: amountPattern),
              let amount = Decimal(string: amountRaw.replacingOccurrences(of: ",", with: "")),
              amount > 0
        else { return nil }

        let account = firstCapture(in: cleaned, pattern: accountPattern) ?? "unknown"

        var merchant = "Unknown"
        for p in merchantPatterns {
            if let m = firstCapture(in: cleaned, pattern: p) {
                merchant = TemplateEngine.cleanMerchant(m)
                if !merchant.isEmpty { break }
            }
        }
        if merchant.isEmpty { merchant = "Unknown" }

        return ParsedTransaction(
            amount: amount,
            merchant: merchant,
            account: account,
            // If both appear ("debited... refund"), debit wins for safety.
            type: isDebit ? "debit" : "credit",
            matchedBy: "generic"
        )
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        for i in 1..<match.numberOfRanges {
            let r = match.range(at: i)
            if r.location != NSNotFound, let swiftRange = Range(r, in: text) {
                return String(text[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// MARK: - Categorizer

enum Categorizer {

    /// User rules first (most recent wins), then built-in keyword defaults.
    static func category(merchant: String,
                         rawMessage: String,
                         type: String,
                         userRules: [CategoryRule]) -> String {
        let haystackMerchant = merchant.lowercased()
        let haystackMessage = rawMessage.lowercased()

        let sortedRules = userRules.sorted { $0.createdAt > $1.createdAt }
        for rule in sortedRules {
            let needle = rule.matchText.lowercased()
                .trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { continue }
            if haystackMerchant.contains(needle) || haystackMessage.contains(needle) {
                return rule.category
            }
        }

        for entry in DefaultData.defaultKeywordRules {
            if entry.keywords.contains(where: { haystackMerchant.contains($0) || haystackMessage.contains($0) }) {
                return entry.category
            }
        }

        return type == "credit" ? "Income" : "Uncategorized"
    }
}
