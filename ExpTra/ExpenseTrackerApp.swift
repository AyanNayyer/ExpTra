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

// MARK: - Shared store (used by BOTH the app UI and the App Intent)

enum Store {
    static let container: ModelContainer = {
        let schema = Schema([
            Transaction.self,
            MessageTemplate.self,
            CategoryRule.self
        ])
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}

// MARK: - App

@main
struct ExpenseTrackerApp: App {
    @AppStorage("faceIDEnabled") private var faceIDEnabled = false
    @State private var isUnlocked = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .task { seedDefaultsIfNeeded() }

                if faceIDEnabled && !isUnlocked {
                    LockScreenView(isUnlocked: $isUnlocked)
                }
            }
        }
        .modelContainer(Store.container)
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
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
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
