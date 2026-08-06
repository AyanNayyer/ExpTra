//
//  Backup.swift
//  ExpenseTracker
//
//  Full local backup & restore as a single JSON file, plus a rolling automatic
//  backup written to the app's Documents folder. Everything stays on device
//  (or in the user's own Files/iCloud Drive when they export).
//

import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Codable snapshot

struct BackupFile: Codable {
    var version = 1
    var exportedAt: Date

    struct TxDTO: Codable {
        var amount: Decimal, merchant, category, account, type: String
        var date: Date, rawMessage, messageHash: String, isManuallyEdited: Bool
    }
    struct TemplateDTO: Codable {
        var name, bank, template, type: String
        var isEnabled: Bool, sortOrder: Int
    }
    struct RuleDTO: Codable { var matchText, category: String; var createdAt: Date }
    struct CategoryDTO: Codable { var name: String; var createdAt: Date }
    struct BudgetDTO: Codable { var category: String; var limit: Decimal; var createdAt: Date }
    struct PendingDTO: Codable {
        var rawMessage, messageHash, reason: String
        var guessedAmount: Decimal, guessedMerchant, guessedType: String, createdAt: Date
    }
    struct DecisionDTO: Codable {
        var signature: String, isTransaction: Bool, sample: String, createdAt: Date
    }

    var transactions: [TxDTO] = []
    var templates: [TemplateDTO] = []
    var rules: [RuleDTO] = []
    var categories: [CategoryDTO] = []
    var budgets: [BudgetDTO] = []
    var pending: [PendingDTO] = []
    var decisions: [DecisionDTO] = []
}

// MARK: - Manager

enum BackupManager {

    static let lastAutoBackupKey = "lastAutoBackup"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: build snapshot

    @MainActor
    static func snapshot(context: ModelContext) -> BackupFile {
        var file = BackupFile(exportedAt: .now)
        file.transactions = (try? context.fetch(FetchDescriptor<Transaction>()))?.map {
            .init(amount: $0.amount, merchant: $0.merchant, category: $0.category,
                  account: $0.account, type: $0.type, date: $0.date,
                  rawMessage: $0.rawMessage, messageHash: $0.messageHash,
                  isManuallyEdited: $0.isManuallyEdited)
        } ?? []
        file.templates = (try? context.fetch(FetchDescriptor<MessageTemplate>()))?.map {
            .init(name: $0.name, bank: $0.bank, template: $0.template, type: $0.type,
                  isEnabled: $0.isEnabled, sortOrder: $0.sortOrder)
        } ?? []
        file.rules = (try? context.fetch(FetchDescriptor<CategoryRule>()))?.map {
            .init(matchText: $0.matchText, category: $0.category, createdAt: $0.createdAt)
        } ?? []
        file.categories = (try? context.fetch(FetchDescriptor<ExpenseCategory>()))?.map {
            .init(name: $0.name, createdAt: $0.createdAt)
        } ?? []
        file.budgets = (try? context.fetch(FetchDescriptor<Budget>()))?.map {
            .init(category: $0.category, limit: $0.limit, createdAt: $0.createdAt)
        } ?? []
        file.pending = (try? context.fetch(FetchDescriptor<PendingMessage>()))?.map {
            .init(rawMessage: $0.rawMessage, messageHash: $0.messageHash, reason: $0.reason,
                  guessedAmount: $0.guessedAmount, guessedMerchant: $0.guessedMerchant,
                  guessedType: $0.guessedType, createdAt: $0.createdAt)
        } ?? []
        file.decisions = (try? context.fetch(FetchDescriptor<MessageDecision>()))?.map {
            .init(signature: $0.signature, isTransaction: $0.isTransaction,
                  sample: $0.sample, createdAt: $0.createdAt)
        } ?? []
        return file
    }

    @MainActor
    static func exportData(context: ModelContext) -> Data {
        (try? encoder.encode(snapshot(context: context))) ?? Data()
    }

    // MARK: restore (replaces everything)

    @MainActor
    @discardableResult
    static func restore(from data: Data, context: ModelContext) -> Bool {
        guard let file = try? decoder.decode(BackupFile.self, from: data) else { return false }

        // Wipe existing rows.
        deleteAll(Transaction.self, context)
        deleteAll(MessageTemplate.self, context)
        deleteAll(CategoryRule.self, context)
        deleteAll(ExpenseCategory.self, context)
        deleteAll(Budget.self, context)
        deleteAll(PendingMessage.self, context)
        deleteAll(MessageDecision.self, context)

        for t in file.transactions {
            context.insert(Transaction(amount: t.amount, merchant: t.merchant, category: t.category,
                                       account: t.account, type: t.type, date: t.date,
                                       rawMessage: t.rawMessage, messageHash: t.messageHash,
                                       isManuallyEdited: t.isManuallyEdited))
        }
        for t in file.templates {
            context.insert(MessageTemplate(name: t.name, bank: t.bank, template: t.template,
                                           type: t.type, isEnabled: t.isEnabled, sortOrder: t.sortOrder))
        }
        for r in file.rules {
            context.insert(CategoryRule(matchText: r.matchText, category: r.category, createdAt: r.createdAt))
        }
        for c in file.categories {
            context.insert(ExpenseCategory(name: c.name, createdAt: c.createdAt))
        }
        for b in file.budgets {
            context.insert(Budget(category: b.category, limit: b.limit, createdAt: b.createdAt))
        }
        for p in file.pending {
            context.insert(PendingMessage(rawMessage: p.rawMessage, messageHash: p.messageHash,
                                          reason: p.reason, guessedAmount: p.guessedAmount,
                                          guessedMerchant: p.guessedMerchant, guessedType: p.guessedType,
                                          createdAt: p.createdAt))
        }
        for d in file.decisions {
            context.insert(MessageDecision(signature: d.signature,
                                           isTransaction: d.isTransaction,
                                           sample: d.sample, createdAt: d.createdAt))
        }
        try? context.save()
        return true
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<T>())) ?? []
        for item in items { context.delete(item) }
    }

    // MARK: automatic rolling backup

    static var autoBackupURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("autobackup.json")
    }

    static var lastAutoBackupDate: Date? {
        (UserDefaults.standard.object(forKey: lastAutoBackupKey) as? Date)
    }

    /// Write a fresh automatic backup at most once per day.
    @MainActor
    static func autoBackupIfNeeded(context: ModelContext, now: Date = .now) {
        if let last = lastAutoBackupDate, now.timeIntervalSince(last) < 24 * 3600 { return }
        let data = exportData(context: context)
        guard !data.isEmpty else { return }
        try? data.write(to: autoBackupURL, options: .atomic)
        UserDefaults.standard.set(now, forKey: lastAutoBackupKey)
    }
}

// MARK: - FileDocument for the export sheet

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
