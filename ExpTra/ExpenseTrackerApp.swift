//
//  ExpenseTrackerApp.swift
//  ExpenseTracker
//
//  App entry point. Sets up the shared SwiftData container,
//  seeds default templates/categories on first launch,
//  and applies an optional Face ID lock.
//

import SwiftUI
import SwiftData
import LocalAuthentication
import UserNotifications

// MARK: - Notification delegate (show trend alerts even while app is foreground)

final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - Shared store (used by BOTH the app UI and the App Intent)

enum Store {
    /// Toggled from Settings. Read here (not via @AppStorage) because the
    /// container is built once at launch.
    static let iCloudKey = "iCloudSyncEnabled"

    static let schema = Schema([
        Transaction.self,
        MessageTemplate.self,
        CategoryRule.self,
        ExpenseCategory.self,
        PendingMessage.self,
        Budget.self,
        MessageDecision.self
    ])

    static let container: ModelContainer = {
        // If the user opted into iCloud sync, try a CloudKit-backed store first.
        // If CloudKit isn't set up (e.g. the iCloud capability hasn't been added
        // in Xcode), fall back to a local store so the app always launches.
        if UserDefaults.standard.bool(forKey: iCloudKey) {
            let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
                return container
            }
        }
        let local = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}

// MARK: - App

@main
struct ExpenseTrackerApp: App {
    static let notificationDelegate = AppNotificationDelegate()

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("faceIDEnabled") private var faceIDEnabled = false
    @State private var isUnlocked = false

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .task {
                        seedDefaultsIfNeeded()
                        BackupManager.autoBackupIfNeeded(context: Store.container.mainContext)
                    }

                if faceIDEnabled && !isUnlocked {
                    LockScreenView(isUnlocked: $isUnlocked)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Re-lock whenever the app leaves the foreground so returning
                // requires Face ID / passcode again.
                if phase == .background { isUnlocked = false }
                if phase == .active { runTrendCheck() }
            }
        }
        .modelContainer(Store.container)
    }

    /// Check for a significant month-over-month change and, if the user enabled
    /// alerts, post a local notification (deduped per month inside TrendMonitor).
    @MainActor
    private func runTrendCheck() {
        let context = Store.container.mainContext
        let txns = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        TrendMonitor.checkAndNotify(transactions: txns)
    }

    /// Seeds default bank message templates on first launch only.
    @MainActor
    private func seedDefaultsIfNeeded() {
        let key = "didSeedDefaults_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let context = Store.container.mainContext
        for (index, seed) in DefaultData.seedTemplates.enumerated() {
            let t = MessageTemplate(
                name: seed.name,
                bank: seed.bank,
                template: seed.template,
                type: seed.type,
                isEnabled: true,
                sortOrder: index
            )
            context.insert(t)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }
}

// MARK: - Root tabs

struct RootTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.pie.fill") }
            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }
            BudgetsView()
                .tabItem { Label("Budgets", systemImage: "chart.bar.fill") }
            TemplatesView()
                .tabItem { Label("Templates", systemImage: "text.badge.checkmark") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Face ID lock screen

struct LockScreenView: View {
    @Binding var isUnlocked: Bool
    @State private var failed = false

    var body: some View {
        ZStack {
            // Opaque so no financial data shows through the lock screen.
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                Text("Expenses Locked")
                    .font(.title2.bold())
                Button("Unlock with Face ID") { authenticate() }
                    .buttonStyle(.borderedProminent)
                if failed {
                    Text("Authentication failed. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { authenticate() }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics/passcode configured — fail open so you're not locked out.
            isUnlocked = true
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Unlock your expense data") { success, _ in
            DispatchQueue.main.async {
                if success { isUnlocked = true } else { failed = true }
            }
        }
    }
}
