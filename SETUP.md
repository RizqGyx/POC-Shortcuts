# Voyage Focus — POC Setup & Test Plan

Open **`POC-Shortcuts.xcodeproj`**. It is generated from `project.yml` by `xcodegen generate`
— edit the yml and regenerate rather than adding targets by hand.

```
POC-Shortcuts/
├── App/          VoyageFocusApp, AppState, RootView
├── Features/     Onboarding · WorkMode · Break · Settings
├── Intents/      StartBreakIntent, WorkModeIntents, AppShortcutsProvider
├── Services/     ScreenTimeService, AppLaunchService
├── Shared/       compiled into all 4 targets — App Group storage, models, tokens
├── Extensions/   ShieldConfiguration · ShieldAction · DeviceActivityMonitor
└── Resources/    Info.plist, entitlements, Assets
```

---

## ⚠️ Correction to the Phase 1 feasibility analysis

My original analysis said the core concept was impossible, based on Apple Developer Forum
threads from 2023–2025. **Apple shipped the missing pieces in iOS 26.4 and 26.5**, and the
SDK on this machine (26.5) confirms it. Three conclusions were wrong:

| I said | Reality |
|---|---|
| The shield extension can never open your app → notification workaround required | **`ShieldActionResponse.openParentalControlsApp`** (iOS 26.5) does exactly this |
| The shield is limited to two buttons, so duration must be chosen in-app | **`ShieldConfiguration.secondaryButtonSubmenuItems`** (iOS 26.4) adds a 3-item submenu |
| Your app can never learn an app's name or bundle ID | **`FamilyActivityData.installedApplications`** (iOS 26.4) returns both |

**The original product concept now works end to end, with no Shortcuts automation at all:**

```
Instagram tapped → blocked by shield ("You're trying to open Instagram")
   → "Take a break" → Voyage Focus opens directly       [openParentalControlsApp]
   → duration + context → Save                          [in-app]
   → shield lifted, Instagram opens                     [URL scheme]
```

Both older paths are still implemented as fallbacks, because the deployment target is
iOS 17: the notification detour below 26.5, and the Shortcuts automation below 26.4.

### Consequence for onboarding

**Setup is two steps: grant Screen Time, pick apps.** Nothing about Shortcuts is shown on
a current device — matching how [Jomo](https://apps.apple.com/us/app/jomo-screen-time-block-apps/id1609960918),
Opal and ClearSpace behave. Jomo states outright that it "doesn't require workarounds or
shortcuts to function"; all of them are pure Screen Time API apps.

The Shortcuts sections appear automatically only when `PlatformCapabilities.needsShortcutsFallback`
is true, i.e. below iOS 26.5. On a modern device the automation guide is still reachable
under **More**, marked as not needed, so the fallback path stays testable.

One caveat: these APIs are new. The code guards them with `#available`, but the runtime
behaviour is worth verifying on device rather than trusting — particularly whether
`.openParentalControlsApp` requires anything beyond the Family Controls entitlement, since
the SDK exposes no additional entitlement or plist key.

---

## 1. Apple Developer Portal (~10 min, required)

**App Group** — Identifiers → App Groups → `+`

```
group.com.ILC6.Miracle.POC-Shortcuts
```

**Four App IDs**, each with **App Groups** *and* **Family Controls** enabled:

| Target | Bundle ID |
|---|---|
| App | `com.ILC6.Miracle.POC-Shortcuts` |
| Shield config | `com.ILC6.Miracle.POC-Shortcuts.ShieldConfiguration` |
| Shield action | `com.ILC6.Miracle.POC-Shortcuts.ShieldAction` |
| Monitor | `com.ILC6.Miracle.POC-Shortcuts.Monitor` |
| Widgets (Live Activity) | `com.ILC6.Miracle.POC-Shortcuts.Widgets` |

The Widgets target needs **App Groups only** — no Family Controls, it never touches Screen
Time. The other four need both.

Family Controls is the one people miss on the *extensions*. All four need it. The
**development** entitlement needs no approval. The **distribution** entitlement is a
separate request per bundle ID — irrelevant for a POC, but it gates TestFlight.

Team ID `H37C5FSRQW` is already in `project.yml`.

## 2. Xcode

Each target → Signing & Capabilities → let automatic signing regenerate profiles.
Entitlements files are already wired up.

**Run on a physical device.** FamilyControls is inert in the Simulator.

---

## 3. Test plan

### A — Screen Time permission `[REAL]`
Launch → **Set Up** → **Request Screen Time Access**.

*Expect:* Apple's consent sheet, then Face ID / Screen Time passcode. Status shows
**Approved** or **Approved + data access**. Note which — it gates test B2.

### B — App selection `[REAL]`
**Choose Distracting Apps** → Instagram, TikTok, YouTube.

### B2 — Installed app list `[REAL, iOS 26.4+]`
Diagnostics → **Read installed apps**.

*Expect:* real display names and bundle identifiers. Disabled unless status is
**Approved + data access**; expect `FamilyControlsError.unauthorized` otherwise. This is
the capability that removes the need for the hardcoded scheme table in `AppLaunchService`.

### C — Real blocking `[REAL]`
**Start Work Mode** → home → tap Instagram.

*Expect:* a shield reading **"Voyage Focus / Work Mode is on. You're trying to open
Instagram."**, with **Take a break** and **Quick break**.

That the shield knows the name proves the configuration extension read
`localizedDisplayName`. Diagnostics → *Token → name map* now has an entry.

### D — Shield → app `[REAL on iOS 26.5+ — the corrected result]`
Tap **Take a break**.

*Expect on 26.5+:* Voyage Focus opens directly on the break screen, already knowing it was
Instagram. **This is the step I originally reported as impossible.**

*Expect below 26.5:* the shield closes and a notification appears; tapping it opens the app.
Same destination, one extra tap.

Diagnostics tells you which path ran.

### D2 — Live Activity `[REAL]`
After Save & Continue, check the Dynamic Island.

*Expect:* a countdown that ticks down to zero on its own, plus a progress bar on the Lock
Screen. Nothing polls and no pushes are sent — `Text(timerInterval:)` drives itself from the
end date, which is the only accurate option given a third-party app cannot run a background
timer.

**ActivityKit can only start a Live Activity from a foregrounded app.** An extension cannot,
which is one reason the break flow routes through the app rather than being granted on the
shield itself.

*Note:* the shield's secondary-button submenu (iOS 26.4+, `secondaryButtonSubmenuItems`) was
removed — two entry points doing nearly the same thing made the flow confusing, and the
submenu path can neither capture a context note nor start a Live Activity. The handlers
remain in `ShieldActionExtension`, so re-enabling it is a one-line change.

### E — Shortcuts automation `[REAL, fallback only — skip on iOS 26.5+]`

Not part of the product flow on a current device. Test it only to verify the fallback, or
if you are targeting users below iOS 26.5.

Build the automation (in-app guide, or Shortcuts → Automation → `+` → App → Instagram →
Is Opened → Run Immediately → **Start a Break** → App Name: `Instagram`). Turn Work Mode
**off** so the shield doesn't pre-empt it, then open Instagram.

*Expect:* Instagram flashes ~1s, then Voyage Focus takes over, source line reading
*Shortcuts automation*.

Still worth keeping: it is the only path that works below iOS 26.4. Its cost is that iOS
exposes no API for creating personal automations, so the user builds it by hand per app.

### F0 — App identity `[REAL, and the subtlest part of the whole design]`
Diagnostics → *Cross-process log*, after a shield has appeared.

*Expect:* `Shield shown for "Instagram" (bundleID: com.burbn.instagram, token: nil)`.

**`Application.token` is Optional and comes back nil inside the shield configuration
extension.** So the token→name map can never be populated there, and any code depending on
it resolves to the fallback string `"an app"` — which then matches no URL scheme, and the
return-to-app step fails while looking like a launch problem.

What works instead: that extension records `localizedDisplayName` + `bundleIdentifier`
unconditionally as the *last shielded app*, and the action extension reads that. Bundle IDs
are also what `AppLaunchService` prefers for scheme lookup — stable and unambiguous, unlike
localised display names.

### F — Context + persistence `[REAL]`
**10 min**, context "Quick social check", **Save & Continue**.

*Expect:* Instagram opens. Diagnostics shows the payload written to the App Group:

```json
{ "appName": "Instagram", "durationMinutes": 10, "contextNote": "Quick social check", … }
```

plus a colour-coded timeline of which of the four processes did what.

### G — Return to app `[REAL]`
Covered by F, via `instagram://`. An app with no registered scheme shows the honest failure
path and the `shortcuts://run-shortcut` fallback.

### G2 — A break unlocks everything `[REAL]`
Start a break from Instagram, then open WhatsApp.

*Expect:* WhatsApp opens too. A break lifts the shield on **all** selected apps, not just
the one that was tapped — a break is a break from work, not from one app. Work Mode stays
on throughout; the status line reads **On a break** and shielded apps shows *all unlocked*.
The re-block restores every app at once, driven by combined usage across them.

### H — Grace period `[REAL]`
During a live break, background Instagram and reopen it. Voyage Focus flashes and hands you
straight back rather than asking for a second break. The ~0.5s bounce exists because
`openAppWhenRun` is a static property.

### I — Re-blocking `[PARTIAL — measure this]`
Use Instagram past the granted duration.

*Expect:* the shield returns. Diagnostics names the mechanism: `DeviceActivityMonitor`
(threshold callback) or `App … foreground expiry check` (backstop).

Worth measuring rather than trusting — threshold callbacks are the flakiest part of the
stack, and no third-party app can run a background timer.

---

## 4. Success criteria

| Criterion | Result |
|---|---|
| Request Screen Time permissions | ✅ REAL |
| User selects distracting apps | ✅ REAL |
| Work Mode activates restrictions | ✅ REAL |
| Accessing a selected app produces a custom intervention | ✅ REAL |
| Intervention identifies the requested app | ✅ REAL |
| **Shield routes directly into Voyage Focus** | ✅ **REAL on iOS 26.5+** · 🟡 notification below |
| Collect break context | ✅ REAL |
| Persist context | ✅ REAL |
| Expose App Intents / Shortcuts | ✅ REAL — auto-registered |
| Save triggers the next step | ✅ REAL |
| Requested app opens afterward | ✅ REAL |
| Setup without any Shortcuts step | ✅ REAL on iOS 26.5+ — 2 steps total |
| User configures a Shortcut automation | 🟡 PARTIAL — manual; only below iOS 26.5 |
| **App creates the automation for the user** | ❌ IMPOSSIBLE — no API |

## 5. Constraints that remain real

1. **No API creates personal automations.** App Shortcuts (actions) self-register;
   automations (triggers) cannot be created programmatically. Only matters below iOS 26.4.
2. **The shield cannot host arbitrary UI.** Text, icon, colours, two buttons and three
   submenu strings. A typed context note still requires opening the app.
3. **Tokens are not guaranteed stable** across OS or app updates — a stored token can
   silently stop matching.
4. **`DeviceActivitySchedule` has a 15-minute floor**, which is why sub-15-minute breaks use
   a usage-*threshold* event.
5. **`FamilyActivityData` needs `.approvedWithDataAccess`**, which the user may not grant;
   the token-map path remains the fallback.
6. **Simulator does not support FamilyControls.**
7. **The automation path is a redirect, not a block** — the target app is briefly visible.
   The shield is the real enforcement.
