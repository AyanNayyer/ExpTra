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

    /// The result of matching a message against the user's templates.
    enum Outcome {
        case transaction(ParsedTransaction)   // a debit/credit template matched
        case ignored                          // an "ignore" template matched — skip
        case noMatch                          // no template matched
    }

    /// Try every enabled template. Ignore templates take precedence (if any
    /// matches, the message is suppressed); otherwise the first debit/credit
    /// template that matches wins.
    static func match(_ text: String,
                      templates: [MessageTemplate]) -> Outcome {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        let range = NSRange(cleaned.startIndex..., in: cleaned)

        // 1. Ignore templates first — they only need to match.
        for t in templates where t.isEnabled && t.type == "ignore" {
            guard !t.template.isEmpty, let regex = regex(from: t.template) else { continue }
            if regex.firstMatch(in: cleaned, range: range) != nil { return .ignored }
        }

        // 2. Debit/credit templates, first match wins.
        for t in templates where t.isEnabled && t.type != "ignore" {
            guard !t.template.isEmpty, let regex = regex(from: t.template) else { continue }
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

            return .transaction(ParsedTransaction(
                amount: amount,
                merchant: cleanMerchant(group("merchant") ?? "Unknown"),
                account: group("account") ?? "unknown",
                type: t.type,
                matchedBy: t.name
            ))
        }
        return .noMatch
    }

    /// Convenience wrapper: the parsed transaction, or nil for ignore/no-match.
    /// Used by the template editor preview.
    static func parse(_ text: String,
                      templates: [MessageTemplate]) -> ParsedTransaction? {
        if case .transaction(let p) = match(text, templates: templates) { return p }
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

// MARK: - Template inference
//
// The reverse of TemplateEngine: given one real bank message, work out the
// pattern (with {amount}/{account}/{merchant} tokens) so the user never has to
// write a template by hand. It detects the amount, account/card number and
// merchant, swaps them for tokens, and truncates the volatile tail (reference
// numbers, dates, available balance) that changes from message to message.

enum TemplateInferer {

    private static let debitKeywords  = ["debited", "spent", "withdrawn",
                                         "paid", "purchase", "sent", "debit"]
    private static let creditKeywords = ["credited", "received", "deposited",
                                         "refund", "credit"]

    /// Amount, keeping the currency word literal and tokenizing only the number.
    private static let amountPattern =
        #"(?:INR|Rs\.?|₹)\s*([\d,]+(?:\.\d{1,2})?)"#

    /// Account/card number — requires an A/c or Card context so we never grab a
    /// date or reference number by mistake.
    private static let accountPattern =
        #"(?:\ba/c|\bac|\bacct|\baccount|\bcard)(?:\s*(?:no\.?|ending))?\s*[:#]?\s*([Xx\*]*\d[Xx\*\d]{1,17})"#

    /// Merchant name after to/at/@, stopping before volatile trailing text.
    private static let merchantPatterns = [
        #"(?:\bat|\bto|@)\s+([A-Za-z0-9 @&.\-_]{2,45}?)(?:\s+on\b|\s+via\b|\s+ref\b|\s+from\b|\s+a/c\b|\.|,|;|$)"#,
        #"UPI[/-]([A-Za-z0-9.@_\-]{2,45})"#,
        #"info:?\s*([A-Za-z0-9 @&.\-_]{2,45})"#
    ]

    /// The values a template will capture from a message. These are shown to the
    /// user as editable fields; each (except type) is a literal substring of the
    /// example message.
    struct Detection {
        var amount: String
        var account: String
        var merchant: String
        var type: String
    }

    /// Normalize a raw message the same way the parser does (newlines → spaces,
    /// collapsed whitespace, trimmed) so substring lookups line up.
    static func normalized(_ rawMessage: String) -> String {
        var text = rawMessage.replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Auto-detect the captured values from a message.
    /// Returns nil if no amount is present (i.e. it doesn't look like a transaction).
    static func detect(from rawMessage: String) -> Detection? {
        let text = normalized(rawMessage)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        let isDebit  = debitKeywords.contains  { lower.contains($0) }
        let isCredit = creditKeywords.contains { lower.contains($0) }
        let type = isDebit ? "debit" : (isCredit ? "credit" : "debit")

        guard let amountRange = captureRange(in: text, pattern: amountPattern, group: 1)
        else { return nil }
        let amount = String(text[amountRange])

        let account = captureRange(in: text, pattern: accountPattern, group: 1)
            .map { String(text[$0]) } ?? ""

        var merchant = ""
        for pattern in merchantPatterns {
            if let range = captureRange(in: text, pattern: pattern, group: 1) {
                merchant = String(text[range]).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        return Detection(amount: amount, account: account, merchant: merchant, type: type)
    }

    /// Build a template from a message and the (possibly user-corrected) values to
    /// capture. Each non-empty value is located in the message and swapped for its
    /// token; everything after the last token is dropped. Returns nil if the
    /// message is empty or no value could be located.
    static func buildTemplate(from rawMessage: String,
                              amount: String,
                              account: String,
                              merchant: String) -> String? {
        let text = normalized(rawMessage)
        guard !text.isEmpty else { return nil }

        var tokens: [(range: Range<String.Index>, token: String)] = []
        func place(_ value: String, as token: String) {
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty,
                  let range = text.range(of: v, options: .caseInsensitive) else { return }
            tokens.append((range, token))
        }
        place(amount, as: "{amount}")
        place(account, as: "{account}")
        place(merchant, as: "{merchant}")
        guard !tokens.isEmpty else { return nil }

        // Rebuild keeping literal text between tokens, and stop after the last
        // token so the changing tail (ref numbers, dates, balance) is dropped.
        let sorted = tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var cursor = text.startIndex
        for entry in sorted {
            guard entry.range.lowerBound >= cursor else { continue }   // skip overlaps
            result += text[cursor..<entry.range.lowerBound]
            result += entry.token
            cursor = entry.range.upperBound
        }

        let template = result.trimmingCharacters(in: .whitespaces)
        return template.isEmpty ? nil : template
    }

    /// Markers where the stable part of a message ends and volatile text begins
    /// (reference numbers, dates, balances, safety notices).
    private static let tailMarkers = [
        " ref ", " ref:", " refno", " ref no", " upi ref", " txn id", " txn:",
        " transaction id", " on ", " avl bal", " available bal", " avbl bal",
        " info:", " info ", " not you", " if not you", " call ", " dial "
    ]

    /// Build a pattern for an "ignore" template. It tokenizes the amount and
    /// account so the rule generalizes across values, but KEEPS the distinctive
    /// wording so it only matches this kind of message. The volatile tail is cut.
    static func buildIgnorePattern(from rawMessage: String) -> String? {
        var text = normalized(rawMessage)
        guard !text.isEmpty else { return nil }

        // Cut the volatile tail at the earliest marker.
        let lower = text.lowercased()
        var cut = text.endIndex
        for marker in tailMarkers {
            if let r = lower.range(of: marker), r.lowerBound < cut {
                cut = r.lowerBound
            }
        }
        text = String(text[text.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // Tokenize amount and account in place (no truncation — keep the wording).
        var tokens: [(range: Range<String.Index>, token: String)] = []
        if let r = captureRange(in: text, pattern: amountPattern, group: 1) {
            tokens.append((r, "{amount}"))
        }
        if let r = captureRange(in: text, pattern: accountPattern, group: 1) {
            tokens.append((r, "{account}"))
        }

        let sorted = tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var cursor = text.startIndex
        for entry in sorted {
            guard entry.range.lowerBound >= cursor else { continue }
            result += text[cursor..<entry.range.lowerBound]
            result += entry.token
            cursor = entry.range.upperBound
        }
        result += text[cursor...]   // keep the descriptive remainder

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a value can be found in the message (used for inline validation).
    static func contains(_ value: String, in rawMessage: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return false }
        return normalized(rawMessage).range(of: v, options: .caseInsensitive) != nil
    }

    private static func captureRange(in text: String,
                                     pattern: String,
                                     group: Int) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive])
        else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              group < match.numberOfRanges else { return nil }
        let r = match.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return Range(r, in: text)
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

    private static let debitKeywords  = ["debited", "spent", "withdrawn", "withdrawl",
                                         "paid", "purchase", "sent", "debit",
                                         "deducted", "charged", "transferred", "txn of"]
    private static let creditKeywords = ["credited", "received", "deposited",
                                         "refund", "credit", "added", "deposit"]

    /// Verbs that unambiguously describe real money movement (used to override
    /// promotional wording).
    private static let strongKeywords = ["debited", "spent", "withdrawn", "withdrawl",
                                         "deducted", "charged", "credited",
                                         "deposited", "refund"]

    /// Words that mark a promotional/informational message (not a transaction)
    /// when no debit/credit keyword is present.
    private static let promoKeywords = ["offer", "cashback", "discount", "sale",
                                        "reward", "voucher", "coupon", "win ",
                                        "pre-approved", "pre approved", "eligible",
                                        "loan", "emi offer", "apply now", "click"]

    /// How confident we are that a message is a transaction.
    enum Classification {
        case transaction(ParsedTransaction)                   // confident
        case ambiguous(reason: String, guess: ParsedTransaction)  // money-related but unsure
        case notTransaction                                    // OTP / promo / no amount
    }

    /// Classify a message. Resilient: anything with a currency amount that isn't
    /// clearly promotional is either parsed or flagged for review — never dropped.
    static func classify(_ text: String) -> Classification {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        let lower = cleaned.lowercased()

        // Definite non-transactions.
        if lower.contains("otp") || lower.contains("one time password")
            || lower.contains("verification code") {
            return .notTransaction
        }

        // Must mention a currency amount to be money-related at all.
        guard let amountRaw = firstCapture(in: cleaned, pattern: amountPattern),
              let amount = Decimal(string: amountRaw.replacingOccurrences(of: ",", with: "")),
              amount > 0
        else { return .notTransaction }

        // Strong verbs unambiguously describe a real movement of money; weak ones
        // (e.g. "purchase", "sent") also show up in ads ("cashback on purchases").
        let hasStrong = strongKeywords.contains { lower.contains($0) }
        let hasPromo  = promoKeywords.contains  { lower.contains($0) }

        // Promotional wording with no strong transaction verb → drop.
        if hasPromo && !hasStrong { return .notTransaction }

        let isDebit  = debitKeywords.contains  { lower.contains($0) }
        let isCredit = creditKeywords.contains { lower.contains($0) }

        let account = firstCapture(in: cleaned, pattern: accountPattern) ?? "unknown"
        var merchant = "Unknown"
        for p in merchantPatterns {
            if let m = firstCapture(in: cleaned, pattern: p) {
                let cleanedM = TemplateEngine.cleanMerchant(m)
                if !cleanedM.isEmpty { merchant = cleanedM; break }
            }
        }

        // Exactly one direction → confident.
        if isDebit != isCredit {
            return .transaction(ParsedTransaction(
                amount: amount, merchant: merchant, account: account,
                type: isDebit ? "debit" : "credit", matchedBy: "generic"))
        }

        // Neither direction word: money mentioned but we can't place it.
        if !isDebit && !isCredit {
            return .ambiguous(
                reason: "Couldn't tell if this is money in or out.",
                guess: ParsedTransaction(amount: amount, merchant: merchant,
                                         account: account, type: "debit",
                                         matchedBy: "generic"))
        }

        // Both directions mentioned (e.g. "debited ... refund") → ask.
        return .ambiguous(
            reason: "Message mentions both debit and credit.",
            guess: ParsedTransaction(amount: amount, merchant: merchant,
                                     account: account, type: "debit",
                                     matchedBy: "generic"))
    }

    /// Convenience wrapper: a confidently-parsed transaction, or nil otherwise.
    static func parse(_ text: String) -> ParsedTransaction? {
        if case .transaction(let p) = classify(text) { return p }
        return nil
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

// MARK: - Message parser (templates + generic fallback, one entry point)

enum MessageParser {

    enum Result {
        case transaction(ParsedTransaction)
        case ignored                                          // suppressed by an ignore template
        case ambiguous(reason: String, guess: ParsedTransaction)
        case notTransaction
    }

    /// The single classification used by the App Intent and the importer:
    /// user templates first (including ignore), then the resilient generic parser.
    static func classify(_ text: String,
                         templates: [MessageTemplate]) -> Result {
        switch TemplateEngine.match(text, templates: templates) {
        case .transaction(let p):
            return .transaction(p)
        case .ignored:
            return .ignored
        case .noMatch:
            switch GenericParser.classify(text) {
            case .transaction(let p):          return .transaction(p)
            case .ambiguous(let reason, let g): return .ambiguous(reason: reason, guess: g)
            case .notTransaction:              return .notTransaction
            }
        }
    }
}
