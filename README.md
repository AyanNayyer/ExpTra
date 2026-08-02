# ExpTra — Private, Offline Expense Tracker for iPhone

**Your bank already texts you every time you spend. ExpTra quietly turns those
messages into a clean, private expense tracker — automatically, and entirely on
your device.**

No sign-up. No servers. No ads. No data ever leaves your phone.

---

## Overview

ExpTra reads the transaction SMS your bank sends (via a one-time Shortcuts
automation) and logs each spend or credit for you — categorized, searchable, and
charted. It's built for Indian bank/UPI messages but adapts to any format: you
just paste one real message and the app figures out the pattern itself.

Everything runs locally with Apple's on-device frameworks (SwiftData for
storage, App Intents for capture, and Apple Intelligence for insights). It works
with no internet connection, and there's no account to create.

---

## Key features

**Automatic capture**
- Logs transactions from bank SMS in the background — the app never has to open.
- Learns *your* bank's message formats from a single pasted example; no manual
  pattern-writing.
- Smart, resilient parser: confident messages are logged, promotional/OTP texts
  are ignored, and anything ambiguous is held for a quick one-tap review instead
  of being silently dropped.

**Understand your money**
- Dashboard with a **Spending / Income** toggle that nets refunds and income
  against spend per category, so you see the real figure.
- Interactive category **donut chart** — tap a slice to see the amount and share.
- **6-month spending trend** bar chart.
- **On-device insights** in plain language ("You've spent ₹9,000 this month, 125%
  more than last — most went to Shopping"), generated privately with Apple
  Intelligence when available.

**Stay on budget**
- Set **monthly budgets** per category or an overall cap.
- Progress bars and overspend flags — budgets inform, they never block.
- Optional **trend alerts**: a notification when your monthly spending swings
  sharply.

**Full control**
- Fast search and filters (by category, type, or account).
- **Quick-categorize** from the list with a long-press; **undo** deletes.
- Auto-categorization with your own rules — "always use this category for this
  shop" keys on the stable UPI ID so it sticks.
- Custom categories, editable amounts, manual entries, and CSV export.

**Private & safe**
- 100% on-device. No network access, no analytics, no tracking.
- Optional **Face ID / passcode lock** that re-locks every time you leave the app.
- **Backup & restore** to a JSON file, an automatic daily on-device backup, and
  optional private **iCloud sync** through your own account.

---

## How it works

```
Bank SMS  →  Shortcuts automation  →  "Log Expense" App Intent  →  Parser
          →  Categorizer  →  SwiftData (on device)  →  Dashboard / Budgets
```

Automations fire on new incoming messages; for history, paste old messages into
the bulk importer. The parser tries your templates first (top-down, first match
wins), then falls back to a built-in generic parser, so you're never worse off.

---

## Architecture

| File | Purpose |
|---|---|
| `ExpenseTrackerApp.swift` | App entry, SwiftData/CloudKit container, Face ID lock, seeding, notifications |
| `Models.swift` | `Transaction`, `MessageTemplate`, `CategoryRule`, `ExpenseCategory`, `Budget`, `PendingMessage` + seed data |
| `Parser.swift` | Template engine, template inference, resilient classifier, categorizer |
| `Insights.swift` | Trend analytics, on-device NL insight generation, trend notifications |
| `Backup.swift` | JSON backup/restore + automatic daily backup |
| `LogExpenseIntent.swift` | The App Intent Shortcuts calls in the background |
| `Views/DashboardView.swift` | Net spend/income, donut chart, trends, insights |
| `Views/TransactionsView.swift` | List, search/filter, edit, quick category, undo, review queue, manual add |
| `Views/BudgetsView.swift` | Per-category / overall monthly budgets |
| `Views/TemplatesView.swift` | Example-driven bank message templates (incl. ignore rules) |
| `Views/SettingsView.swift` | Category rules, categories, import, backup, sync, alerts, Face ID |
| `Views/ImportView.swift` | Paste-in bulk importer for old messages |

---

## Xcode setup (~10 minutes)

1. **Xcode → File → New → Project → iOS → App.**
   - Interface: **SwiftUI**, Language: **Swift**, Storage: **None**.
2. Project settings → General → **Minimum Deployments: iOS 17.0**.
   (On-device insights additionally need iOS 26 + Apple Intelligence; everything
   else works from iOS 17.)
3. **Delete** the generated `ContentView.swift` and `<YourApp>App.swift`.
4. Drag all `.swift` files from this folder (including the `Views` folder) into
   the project navigator — check **"Copy items if needed"** and your app target.
5. Target → **Info** → add `Privacy - Face ID Usage Description`
   (`NSFaceIDUsageDescription`) = `Used to lock your expense data.`
6. Signing & Capabilities → select your **Team** (a free Apple ID works).
7. Plug in your iPhone, select it as the destination, press **Run**.
   - On a free account, trust the certificate on the phone via
     Settings → General → VPN & Device Management.

---

## One-time Shortcuts automation (on the iPhone)

> Also available in-app: Settings → Shortcuts automation guide.

1. Shortcuts app → **Automation** → **+** → **Message**.
2. Sender: empty. **Message Contains:** `debited`.
3. **Run Immediately**, **Notify When Run** off → Next.
4. **New Blank Automation** → add action → search your app name →
   **Log Expense From Message**.
5. Tap the **Message Text** parameter → choose the magic variable
   **Shortcut Input**.
6. Repeat for keywords: `spent`, `credited`, `withdrawn`, `paid`, `sent`
   (one automation each).

Test it by texting yourself:

```
Rs.499.00 debited from A/c XX1234 to SWIGGY on 22-07-26. UPI Ref 123456.
```

It appears in the app within a couple of seconds — without the app opening.

---

## Customizing for YOUR banks

**Templates tab — example-driven, no token typing:**
1. Copy a real message from your bank.
2. Tap **+**, paste it into **Example message**.
3. The app auto-fills **what it will capture** (amount, account, merchant, type).
   Tweak any field to point it at the right text — the pattern updates itself.
4. Choose a type: **Debit**, **Credit**, or **Ignore** (to skip messages like
   pre-notifications, failed txns, or promos). Duplicate templates are flagged.

**Category rules (two ways):**
- Settings → Category Rules → **Add Rule** (e.g. contains `shop@okaxis` →
  `Groceries`), optionally re-applied to existing transactions.
- Or open a transaction → set its category → **"Always use this category…"**.
  This keys on the UPI ID when present, so the same shop matches reliably.

Your rules always beat the built-in keyword defaults; the newest rule wins.

**Budgets tab:** set a monthly limit per category or an overall cap. Purely
informational — nothing is ever blocked.

---

## iCloud sync (optional)

Sync privately across your devices through your own iCloud account. It's
**off by default**; when off, the app uses local storage and never touches the
network. To enable:

1. In Xcode: select the target → **Signing & Capabilities → + Capability**.
2. Add **iCloud** → check **CloudKit** → create/select a container
   (e.g. `iCloud.<your-bundle-id>`).
3. Add **Background Modes** capability → check **Remote notifications**
   (lets changes sync in the background).
4. Make sure the device is signed into iCloud.
5. Run the app → **Settings → Sync → iCloud sync** → on → **relaunch** the app.

If the capability isn't set up, the toggle does nothing harmful — the app safely
falls back to local storage.

---

## Backup & restore

- **Settings → Backup & Restore → Export backup (JSON)** — a complete snapshot
  (transactions, templates, rules, categories, budgets).
- **Restore from a backup file** — replaces all current data (with confirmation).
- The app also writes an **automatic daily backup** on-device you can restore
  from the same screen.

---

## Things to know

- **No history from automations** — they fire only on new messages. Use
  Settings → *Import old messages* to backfill (with duplicate detection).
- **Free Apple ID signing expires every 7 days** — re-run from Xcode weekly, or
  use a paid developer account (1 year).
- If auto-capture stops (e.g. after an iOS update), Settings shows the **last
  capture time** so you'll notice.
- Bank messages filtered into **Junk** may not trigger automations — avoid
  aggressive SMS-filtering apps for bank senders.
- **Insights** need Apple Intelligence supported and enabled; otherwise a
  built-in summary is shown.
