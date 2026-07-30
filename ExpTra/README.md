# ExpenseTracker — Offline iOS Expense Tracker

Fully on-device expense tracker for iPhone. Auto-captures bank SMS via a
Shortcuts automation → App Intent pipeline. **No server, no network access,
no data leaves the phone.**

## What's included

| File | Purpose |
|---|---|
| `ExpenseTrackerApp.swift` | App entry, SwiftData container, Face ID lock, default seeding |
| `Models.swift` | `Transaction`, `MessageTemplate`, `CategoryRule` + seed data |
| `Parser.swift` | Template engine, generic fallback parser, categorizer |
| `LogExpenseIntent.swift` | The App Intent Shortcuts calls in the background |
| `Views/DashboardView.swift` | Monthly totals + category donut chart |
| `Views/TransactionsView.swift` | List, search, edit, manual add, per-merchant rules |
| `Views/TemplatesView.swift` | Bank message templates editor with live tester |
| `Views/SettingsView.swift` | Category rules, CSV export, Face ID, setup guide |
| `Views/ImportView.swift` | Paste-in bulk importer for old messages |

## Xcode setup (10 minutes)

1. **Xcode → File → New → Project → iOS → App.**
   - Product Name: `ExpenseTracker` (any name works)
   - Interface: **SwiftUI**, Language: **Swift**
   - Storage: **None** (we set up SwiftData manually)
   - Uncheck "Include Tests" if you want minimal setup
2. In the project settings → General → **Minimum Deployments: iOS 17.0**.
3. **Delete** the generated `ContentView.swift` and the generated
   `<YourApp>App.swift`.
4. Drag all `.swift` files from this folder (including the `Views` folder)
   into the Xcode project navigator. Check **"Copy items if needed"** and
   make sure your app target is ticked.
5. Project → Target → **Info** tab → add key:
   - `Privacy - Face ID Usage Description` (`NSFaceIDUsageDescription`)
   - Value: `Used to lock your expense data.`
6. Signing & Capabilities → select your **Team** (free Apple ID works).
   - Optional hardening: click **+ Capability → Data Protection** and leave
     it on *Complete until first user authentication*.
7. Plug in your iPhone, select it as the run destination, press **Run**.
   - First run on a free account: on the phone go to
     Settings → General → VPN & Device Management → trust your developer
     certificate.

## One-time Shortcuts automation setup (on the iPhone)

> Also available inside the app: Settings tab → Shortcuts automation guide.

1. Shortcuts app → **Automation** → **+** → **Message**.
2. Sender: leave empty. **Message Contains:** `debited`.
3. Select **Run Immediately**, turn **Notify When Run** off → Next.
4. **New Blank Automation** → add action → search your app name →
   **Log Expense From Message**.
5. Tap the **Message Text** parameter → choose the magic variable
   **Shortcut Input**.
6. Done. Repeat steps 1–5 for keywords: `spent`, `credited`, `withdrawn`,
   `paid`, `sent`. (One automation per keyword.)

Now send yourself a test message from another phone, e.g.:

```
Rs.499.00 debited from A/c XX1234 to SWIGGY on 22-07-26. UPI Ref 123456.
```

It should appear in the app within a couple of seconds — without the app
ever opening.

## Customizing for YOUR banks

**Templates tab** — this is the "default template" system you asked for:

1. Copy a real debit SMS from your bank.
2. Open a template (or `+` for new), paste your message into the
   **pattern** field, and replace the changing parts with tokens:
   - `{amount}` — the number (keep `Rs.`/`INR` as literal text before it)
   - `{account}` — account/card digits (`XX1234`)
   - `{merchant}` — shop / UPI name
   - `{skip}` — ignore up to 60 characters of noise
3. Paste the same real message into the **Test** box below — you'll see
   exactly what gets extracted, live, as you edit.
4. Only keep the *stable* prefix of the message; you can stop the pattern
   before reference numbers and balances.

Templates are tried top-down, first match wins; anything unmatched falls
back to a built-in generic parser, so you're never worse off.

**Category rules** (two ways):
- Settings tab → Category Rules → **Add Rule**: "any merchant/message
  containing `shop@okaxis` → `Groceries`", with an option to re-apply to
  existing transactions.
- Or open any transaction → change its category → toggle
  **"Always use this category for this merchant"**. Same effect, zero typing.

Your rules always beat the built-in keyword defaults, and the newest rule
wins on conflicts.

## Things to know

- **No history backfill from automations** — they only fire on new
  messages. Use Settings → *Import old messages* to paste and bulk-import
  past SMS (with duplicate detection and a preview).
- **Free Apple ID signing expires every 7 days** — re-run from Xcode weekly,
  or use AltStore/SideStore to auto-refresh, or a paid dev account (1 year).
- If auto-capture silently stops (e.g. after an iOS update), the Settings
  tab shows the **last capture time** so you'll notice.
- Messages that iOS filters into Junk may not trigger automations — avoid
  aggressive SMS filtering apps for bank senders.
- Everything is stored in SwiftData on-device. Export CSV anytime from
  Settings.
  

