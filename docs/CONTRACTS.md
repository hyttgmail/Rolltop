# Contracts for feature authors

Read this instead of the shared code. It describes `main` after round 2 (2026-11-25). Platform facts are in [PLATFORM.md](PLATFORM.md), design rules in [DESIGN.md](DESIGN.md), safety rules in `CLAUDE.md`.

## Ground rules

- Your feature lives in `Rolltop/Features/<Name>/` (the stub `<Name>Feature.swift` is already listed in `App/FeatureRegistry.swift`). Tests go in `RolltopTests/<Name>/`. Edit nothing else; if a shared contract is missing, report it instead of editing `App/`, `Engine/`, `Platform/`, `UI/`, `Packages/RolltopCore`, `project.yml` or `Info.plist`.
- Features never name each other's types. They meet only through `App/Contracts` (services, commands, panes, pane sections) and engine state. Helpers two features need go to `Platform/` or `UI/` through the integrator.
- Every source and resource under `Rolltop/` is globbed: add files freely, never edit the project. Run `xcodegen generate` after adding files.
- The app target uses Swift 6 with **default MainActor isolation**. Blocking work (Accessibility, window lists, file I/O) runs off the main thread in `nonisolated` code (`await AXInventory.onQueue { … }` or your own queue). Closures handed to C/ObjC callbacks that fire off-main must be created in `nonisolated` code.
- Logging: `private let log = Log.logger("<feature-id>")`; `log.info/debug/notice/error(String)`. Never log user content.
- Private API only in `Platform/`. Pure decisions in testable functions; thin AppKit side effects.

## Naming (checked by `scripts/check-names.py` and `RolltopTests/Core/RegistryNamingTests.swift`)

Run `python3 -I scripts/check-names.py` before every commit; it fails on any clash below. Wave 1 broke `main` because two features declared `BarGeometry`.

- **Top-level types** start with the feature's name (`RevealBarGeometry`, `AppearanceBarGeometry`, `RolltopBar…` in SecondaryBar). `private`/`fileprivate` types are exempt. No type may share a name with another type in `Rolltop/`, `RolltopTests/` (suites too) or RolltopCore's public API.
- **Strings**: only your own table, named like your directory: `String(localized: "Hidden items", table: "Reveal")`, `LocalizedStringResource(…, table: "Reveal")`, `Text(…, tableName: "Reveal")`, catalog `Rolltop/Features/Reveal/Reveal.xcstrings`. Sentence case, no exclamation marks. US English source, Simplified Chinese translation. After adding or changing strings run `python3 scripts/l10n/l10n.py --build`: it collects the strings from a Release build, regenerates every catalog and fills `zh-Hans` from the translation memory in `scripts/l10n/tm/` (add your translations there, following `scripts/l10n/glossary.md`); `--check` must report zero untranslated strings, and `RolltopTests/Localization` fails otherwise. Never edit `.xcstrings` files by hand.
- **Settings keys**: `rolltop.<feature-id>.<name>`. **Commands**: `<feature-id>.<verb>`. **Panes**: your feature id or a name only you use. **Contributed pane sections**: `<feature-id>.<name>`. **Service key names**: `<feature-id>.<name>`. **Debug commands**: `<feature-id>.debug-<verb>` (core: `debug.<verb>`).
- Command titles are Title Case (they appear in menus and Shortcuts); everything inside a pane is sentence case.

## Lifecycle

```swift
final class RevealFeature: FeatureModule {
    static let id: FeatureID = "reveal"
    private unowned let context: AppContext
    init(context: AppContext) { … }         // register services and transient keys here
    func start() { … }                      // all features exist; resolve services here
    func stop() { … }                       // reverse order at quit
    var settingsPanes: [SettingsPane] { … }           // read once after init
    var settingsSections: [SettingsPaneSection] { … } // read once after init
    var commands: [Command] { … }                     // read once after init
}
```

Order: every feature is `init`ed, then all `commands`, panes and sections are registered, then `start()` runs in `FeatureRegistry` order (SettingsShell, Onboarding, Capture, Profiles, Reveal, Hotkeys, SecondaryBar, Automations, Appearance, Spacing, LayoutEditor, CommandPalette, Media, Weather, CustomItems, Automation, Shelf; Media `media` and Weather `weather` were added in round 2); then Rolltop's status item starts observing the reveal router and the launch log lists every registered command id. Under unit tests the app starts nothing (`AppDelegate.isRunningTests`); `TestContext.make()` (RolltopTests/Core) builds a full context on a throwaway defaults suite for tests that need one.

## AppContext (`context.`)

| Member | Use |
|---|---|
| `settings: SettingsStore` | `settings[key]` get/set, `reset`, `hasValue`; `markTransient(key)`; `exportAll()`, `replaceAll(with:)`; observable via `revision` |
| `layout: LayoutStore` | `layout.layout` (observable), `setSection(_:for:)` (nil = follow default), `setDefaultSection(_:freezing:)`, `replace(with:)` (atomic), `update { }` |
| `catalog: ItemCatalog` | items and what is drawn, see below |
| `visibility: VisibilityEngine` | presentation, allows, forcing, see below |
| `activator: ItemActivator` | open an item's menu/panel |
| `clockBridge: ClockBridge` | `isSessionActive`, `openNotificationCenter(at:)` |
| `permissions: Permissions` | `accessibility`, `screenRecording` (observable), `refresh()`, `request…()` only from a user click (system dialogs), `openSettings(for:)` |
| `commands: CommandRegistry` | `register`, `run(id, arguments:, source:)`, `runDetached`, `commands` (observable) |
| `settingsPanes: SettingsPaneRegistry` | `panes` (sorted), `sections(for:)`, `keywords(for:)` |
| `services: ServiceLocator` | typed services, see below |
| `urlRoutes: URLRouteRegistry` | `register(host:handler:)` for `rolltop://<host>/…` (`command` is reserved) |
| `launchInfo`, `ownBundleIDs`, `statusItemFrame()` | launch facts; Rolltop's bundle ids (never hidden); Rolltop's item frame (AppKit coordinates) |
| `AppContext.current` | static; only for AppleScript classes, App Intents, Focus filters |

Observe anything with Observation: SwiftUI reads it directly; elsewhere `ChangeObserver(track: { _ = context.visibility.level }) { … }` (main actor, coalesced; keep it alive) or `for await x in Observations({ … })`.

## Model (RolltopCore)

- `OwnerID`: `.app(bundleID)` / `.system(SystemModule)`; string form `com.foo.bar` / `system:wifi`. Visibility is per owner.
- `SystemModule`: battery, bluetooth, clock, sound, wifi, controlCenter (verified ids 0/1/2/5/6/8); displays, keyboard, screenMirroring (3/4/7 unverified). `defaultName` is the fixed English name.
- `Section`: `shown`, `hidden`, `alwaysHidden`. `Layout`: `sections[OwnerID]` + `defaultSection`.
- `PresentationLevel`: `collapsed` < `hiddenRevealed` < `allRevealed`.
- `AllowListPlanner`: precedence own bundle > temporary allow > forced visible > section and level; `concealShown` also hides the shown section except pinned owners, at every level. No restriction is held unless a present owner must hide (any restriction also hides AirDrop, Focus, Now Playing…).
- `CatalogEntry`: `id`, `kind` (`app`, `system`, `macOSManaged`, `unidentified`), `owner`, `displayName` (fixed name, never live state), `detail` (macOS's spoken description with live state, e.g. "Wi‑Fi, connected, 3 bars"; system and managed entries only), `section`, `itemCount`, `pids`, `slots`, `isDrawn`, `isOverflowed`, `lastKnownFrames`, `isOwn`, `isCarriedOver`, ….
- `CommandID` (`isWellFormed`, `isDebugOnly`), `SettingsKey`, `KeyCombo`.

## ItemCatalog

`entries` (left to right), `drawn` (per display: `barFrame`, `chevronFrame`, `slots`), `runningApps`, `presentOwners`, `knownBundleIDs`; `entry(for:)`, `entries(in:)`, `isDrawn(_:)`, `displayName(for:)`; `setNeedsRefresh(after:)`, `await refresh()`, `await refreshDrawn()`. Show owners by `displayName(for:)` or `entry.displayName`: system modules and the Apple agents (`com.apple.systemuiserver` "Time Machine and other system items", `com.apple.TextInputMenuAgent` "Input menu", `com.apple.campo` "Spotlight") get fixed localizable names (`ItemNames`, table `UI`); owners that are not running fall back to the running or installed app's name, then the bundle id. macOS-managed entries cannot be assigned. An app started while hidden has no entry until drawn once (PLATFORM §2). An app that was listed before, still runs and sits in a section other than Shown keeps its entry while a restriction is held even when macOS reports no items for it (`isCarriedOver`): macOS drops the extras bar of an item that was overflowed and then concealed (PLATFORM §13).

## VisibilityEngine and who writes what

State (observable): `level`, `concealShown`, `isRestrictionHeld`, `isApplying`, `plannedAllowList`, `appliedAllowList`, `lastError`, `temporaryAllows`, `forcedVisible`, `suspensions`, `interactions`, `isInteractionActive`, `isAvailable`. The engine never collapses by itself; changes apply on the next turn; failures fail open.

| State | Only written by |
|---|---|
| `level` | the reveal commands through the router (below); Reveal's rehide and scroll run `visibility.collapse`; `reveal.keep-revealed` shows inline |
| `concealShown` (`setConcealShown`) | Reveal (make room, hide everything) |
| `forcedVisible` | Automations, source `automations.<rule-id>` |
| `temporaryAllows`, `interactions` | ItemActivator (and the clock bridge's interactions) |
| `suspensions` | ClockBridge |
| `layout` | core layout commands, Menu Bar Items and General panes, Profiles (`replace`), Automations through `.profileLayoutRestorer` |
| `CoreSettings.pinned` | General pane; Reveal's Debug pin helper (restores it) |

Rehide policies wait while `isInteractionActive`. `ItemActivator.activate(owner, button:, index:)` allows temporarily, waits for the item to be drawn, presses it, and ends the allow when its menu or panel closes.

## Commands

```swift
Command(id: "reveal.toggle-hide-everything", title: LocalizedStringResource("Hide Everything", table: "Reveal"),
        symbol: "rectangle.dashed", arguments: [], defaultShortcut: nil,
        showInStatusMenu: true, showsSymbolInMenu: false, allowedFromURL: true, effect: .display,
        isOn: { … }, isAvailable: nil) { invocation in … }   // async throws, main actor
```

- Arguments are strings; declare them with `CommandArgument(name:title:isRequired:allowedValues:)`. `source`: `statusMenu`, `url`, `hotkey`, `palette`, `shortcuts`, `appleScript`, `automation`, `customItem` (a widget's click), `internal`. `defaultShortcut` is data; Hotkeys binds it. `isAvailable` false hides a command from menus and refuses it.
- **Effects** (`effect: CommandEffect?`): `.display` shows, hides, opens or closes something and leaves nothing behind but presentation; `.changesSettings` writes a preference, the layout, a profile or a rule's state; `.destructive` deletes data or cannot be undone (clear a history, delete a profile, import a backup, resume rules whose scripts then run). **Undeclared means destructive** (`resolvedEffect`). `CommandRegistry.run` refuses a destructive command from `CommandEffectPolicy.externalSources` (`url`, `shortcuts`, `appleScript`, `automation`, `customItem`) with `CommandError.notAllowed`; Debug-only ids are exempt so live tests can drive them. Consumers: links (`InteropLinkPolicy`: destructive always refused, `changesSettings` only with "Allow links that change settings" unless the sender is Rolltop), the generic "Run Rolltop Command" of Shortcuts and AppleScript (`InteropActions.mayRunGenerically`), the rule editor's and the widget editor's command pickers (`CommandEffectPolicy.allows(_:from:)` filters them), and the palette (a destructive row runs on a second Return; the footer says "Press Return again to run …"). `allowedFromURL` still gates links before the effect.
- Status menu: Show Hidden Items / Show All Items, then the `showInStatusMenu` commands grouped by feature (a separator between groups, registration order; features that add a single icon-less command share one group, `StatusMenuGrouping`), then Settings… and Quit Rolltop. `showsSymbolInMenu` only for commands that identify an object (profiles); every other item hides its image (macOS 27 adds symbols to standard items otherwise).
- Core ids: `visibility.toggle-hidden`, `visibility.show-hidden` (both: `anchor` = `pointer` | `status-item`, `gesture` = `click` | `hover` | `scroll`), `visibility.toggle-all`, `visibility.show-all`, `visibility.collapse`, `layout.set-section` (owner, section = shown | hidden | always-hidden | default), `layout.set-default-section` (section; freezes present owners first), `item.activate` (owner, button, index), `app.settings` (pane), `app.quit` (always quits: ends Rolltop's sheets and alerts, terminates, exits after 2 s if AppKit has not). URL form: `rolltop://command/<id>?key=value`.
- Feature ids today (status menu: hide everything, make room, profile slots, allow Accessibility): `reveal.toggle-hide-everything`, `reveal.toggle-make-room`, `reveal.keep-revealed`; `profiles.apply` (id), `profiles.apply-1…5` (status menu slots), `profiles.next`, `profiles.previous`, `profiles.save-current` (name), `profiles.delete` (not from URLs); `automations.pause-all`, `automations.resume-all`, `automations.toggle-rule` (id); `appearance.toggle`, `appearance.apply-preset` (id); `spacing.apply-preset` (id); `capture.clear-cache`; `onboarding.allow-accessibility` (status menu, only while Accessibility is missing); `palette.toggle`, `palette.show`, `palette.clear-history`; `shelf.toggle`, `shelf.show`, `shelf.clear-clipboard`, `shelf.pause-clipboard`; `custom-items.toggle` (id), `custom-items.open-group` (id), `custom-items.refresh-widget` (id); `interop.export-backup`, `interop.import-backup`. Effects are declared next to each command; `RolltopTests/Core/CommandEffectTests.swift` lists the known ones. Round 2 added `app.toggle-menu-bar-icon` (changes settings) and the Debug commands `debug.set-status-item`, `debug.dump-status-item`, `debug.nudge-layout`, `settings-shell.debug-consents`, `secondary-bar.debug-route`, `appearance.debug-space`, `media.debug-inject`, `weather.debug-inject`, `shelf.debug-inject`, `custom-items.debug-inject`, `automations.debug-inject-location`, `interop.debug-focus`, `palette.debug-sample-rows`, `palette.debug-key`, `layout-editor.debug-inject`, `layout-editor.debug-move`, and, for a normally launched Debug build after the user allowed access, `layout-editor.debug-verify-order` (`phase=read`, then `phase=swap` with both fixtures running: swaps only the fixtures, checks list B, restores) and `layout-editor.debug-verify-turned-off`.

## Settings panes

```swift
SettingsPane(id: "reveal", title: LocalizedStringResource("Reveal", table: "Reveal"), symbol: "eye", sortOrder: 210,
             keywords: [LocalizedStringResource("show hidden items, click, hover, …", table: "Reveal",
                                                comment: "Settings search keywords, comma separated")]) {
    RevealSettingsView(context: context)
}
```

| Order | Pane id | Title | Feature |
|---|---|---|---|
| 10 | `general` | General | SettingsShell |
| 110 | `menu-bar-items` | Menu Bar Items | LayoutEditor |
| 120 | `custom-items` | Custom Items | CustomItems |
| 150 | `profiles` | Profiles | Profiles |
| 210 | `reveal` | Reveal | Reveal |
| 220 | `secondary-bar` | Rolltop Bar (+ Capture's `capture.item-images` section) | SecondaryBar |
| 230 | `palette` | Search | CommandPalette |
| 240 | `shelf` | Shelf | Shelf |
| 245 | `weather` | Weather | Weather |
| 250 | `hotkeys` | Shortcuts | Hotkeys |
| 310 | `appearance` | Menu Bar Appearance | Appearance |
| 320 | `spacing` | Item Spacing | Spacing |
| 410 | `automations` | Automations | Automations |
| 420 | `integrations` | Integrations | Automation (interop) |
| 910 | `permissions` | Permissions | SettingsShell |
| 915 | `backup` | Backup | Automation (interop) |
| 920 | `advanced` | Advanced | SettingsShell |
| 990 | `about` | About | SettingsShell |

- Ranges (also the sidebar groups): 0–99 general, 100–199 menu bar items, 200–299 behaviour, 300–399 appearance, 400–499 automation, 500–899 other, 900+ about/advanced.
- **Keywords**: every pane has one localized, comma-separated list in its own table; the sidebar search matches each query word in the title or the keywords (sections add theirs to the host pane).
- **Sections in another feature's pane**: `SettingsPaneSection(id: "capture.item-images", paneID: "secondary-bar", sortOrder: 100, keywords: […]) { … }`; the host pane places `ContributedSettingsSections(paneID:registry:)` in its `Form`.
- **Scaffolding**: one `Form { Section … }.formStyle(.grouped)` filling the detail column (510 pt wide at the 720 pt window, height ≥ 420 pt); the window shows the pane title, so no section repeats it; sentence-case section headers; row captions as the second `Text` of a `Toggle`/`LabeledContent`/`Picker` label; section footers as plain `Text` (the Form styles them, no fonts); limitations with `LimitationNote`; owners with `OwnerLabel`/`OwnerIcon` (shared `UI/`). Nothing may need horizontal scrolling. Changes apply at once.
- **Hosting a pane for screenshots**: `scripts/rolltop-cmd.sh app.settings pane=<id>`, `settings-shell.debug-place-windows x=120 y=90 [height=…]`, find the window id with `tmp/evidence/integration-1/harness/winlist <pid>` (layer 0, width ≥ 700) and `screencapture -x -o -l <id> file.png`; `settings-shell.debug-appearance appearance=light|dark`, `settings-shell.debug-search query=…`, `settings-shell.debug-close deactivate=1`. The per-feature Debug pane windows (`*.debug-window`, `*.debug-host-pane`, `*.debug-preview*`) predate the settings window.

## Consent rows

**The consent rule.** A Release build runs while the user is away, so a protected API (another app's data or files, Apple Events, Location, Calendars, …) is touched only after the user clicked that feature's button. The click sets a persisted marker owned by the feature (a transient settings key `rolltop.<feature-id>.…`, marked with `context.settings.markTransient` in `init`), set inside the row's `request` before the protected call; every later path checks the marker or a non-prompting status call first. Launching Rolltop, opening a settings pane or the layout editor, expanding the Shelf, refreshing a widget, running an automation: none of these may raise a prompt. Status shown in the UI comes from calls that never prompt. In live tests never click these buttons and never run the real path (under a shell launch the prompt would be attributed to the terminal and may hang); feed the feature injected data through a Debug command instead.

Every feature that can raise a prompt registers one row per permission in `init(context:)` (`App/Contracts/Consents.swift`), so the user can walk Settings › Permissions › "Features that need your permission" once from top to bottom:

```swift
context.services[.consents].register(ConsentItem(
    id: "media.music",                                        // <feature-id>.<name>
    title: LocalizedStringResource("Music", table: "Media"),  // the pane or app the user will look for
    purpose: LocalizedStringResource("Shows what is playing in Music and lets you control it.", table: "Media"),
    sortOrder: 300,
    status: { [unowned self] in self.musicConsentStatus() },  // main actor, cheap, never prompts
    request: { [unowned self] in await self.askMusic() },     // only from the row's button; sets the marker first
    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
    secondaryAction: nil))                                    // ConsentSecondaryAction(title:action:), e.g. "Choose File…"
```

- `ConsentItem(id:title:purpose:sortOrder:status:request:settingsURL:secondaryAction:)`: `title`/`purpose` are `LocalizedStringResource` in your table; `status: @MainActor () -> ConsentStatus`; `request: @MainActor () async -> Void`; `settingsURL: URL?`; `secondaryAction: ConsentSecondaryAction?` (`title: LocalizedStringResource`, `action: @MainActor () async -> Void`).
- `ConsentStatus` (`nonisolated`, `Equatable`, `Sendable`): `.allowed`, `.notAllowed` (refused; changed in System Settings), `.notAsked`, `.cannotAskNow(String)` (localized reason that says what to do: "Open Music first."), `.unavailable(String)` (localized reason).
- **`status`** contract: main actor, cheap, never raises a prompt and never touches the protected resource (no file read, no Apple event, no location fix). Only `ConsentRegistry.refresh()` calls it: when the pane appears, every ~2 s while it is visible, after each request. Registering is inert (no status read), so unit tests that create every feature stay silent.
- **`request`** contract: async, runs only from the row's button through `ConsentRegistry.request(id:)` (one at a time per row, then a refresh), and is the only code allowed to raise that permission's prompt. It may return before the user answers; polling picks the answer up.
- Button by status (`ConsentAction.primary(for:hasSettingsURL:)`, pure): `.notAsked` → "Allow…" (`request`); `.notAllowed` → "Open System Settings" (`settingsURL`), or "Allow…" again when the row has no URL; `.allowed`, `.cannotAskNow`, `.unavailable` → none. The secondary action shows in every status except `.unavailable` (`ConsentAction.showsSecondary(for:)`). Every button is disabled when `context.launchInfo.launchedByLaunchServices` is false (`ConsentAction.buttonsEnabled(launchedByLaunchServices:)`): macOS would record the permission for the terminal; the pane then shows a warning, and above the rows a caption tells the user to open Rolltop normally first.
- Status visuals: `ConsentStatusLabel(status:)` (`UI/`): Allowed, Not allowed, Not asked yet, Can’t ask now, Unavailable, and Checking… before the first read. Use it where your own pane shows the same status.
- Sort orders (rows sort by `sortOrder`, then `id`): 100 `location.access` (SettingsShell; the one id without a feature prefix, since Location is shared Platform state; no marker, because reading its status never prompts) · 200 layout file, 210 Control Center allow list (`layout-editor.…`) · 300 Music, 310 Spotify (`media.…`) · 400 Calendars (`shelf.…`) · 500–899 anything else · 900+ Debug samples.
- Titles name the System Settings pane the user will look for (Location Services, Calendars) or, for Apple Events consents (listed per target app under Privacy & Security › Automation), the app (Music, Spotify). Purpose: one sentence saying what starts working once allowed.
- **Verification command.** Each such feature ships one Debug command `<feature-id>.debug-verify…` (e.g. `media.debug-verify-music`) that runs the real path once, with timeouts, and writes a JSON result to `DebugFiles.directory` (`DebugFiles.writeJSON(_:name:)`, file `<feature-id>-verify….json`): what was called, the status before and after, the outcome and the elapsed time. The main session runs it after the user allowed access, under a normally launched Debug build. It must be bounded, safe unattended, and change nothing it does not restore. Agents never run it themselves.
- `settings-shell.debug-consents` registers sample rows in every status (ids `settings-shell.sample-…`, sort order 900+) for screenshots; `reset=1` removes them.
- Usage strings (`Info.plist`, translated in `scripts/l10n/tm/InfoPlist.tm`): `NSLocationUsageDescription`/`NSLocationWhenInUseUsageDescription` cover the Wi-Fi network name, place conditions in automations and local weather; `NSAppleEventsUsageDescription` covers scripts, automations and showing and controlling what plays in Music or Spotify; `NSCalendarsFullAccessUsageDescription` covers the Shelf and automations. A feature that needs another usage string reports it to the integrator.

## Settings keys and transient state

`SettingsKey<Value>("rolltop.<feature-id>.<name>", default: …)` in your directory. Runtime state that is not a preference is marked in `init(context:)` with `context.settings.markTransient(key)`: `exportAll()` leaves it out and `replaceAll(with:)` neither removes nor writes it, so exports, imports, profile snapshots and "Reset all settings" never touch it. Transient today: `rolltop.automations.active-rules`, `rolltop.automations.profile-ledger`, `rolltop.settings-shell.last-pane`, `rolltop.onboarding.state`, `rolltop.spacing.last-applied`, `rolltop.capture.requested-access`, `rolltop.reveal.hide-everything`. Window frames live outside `rolltop.*` (`NSWindow Frame RolltopSettings`). Profiles snapshot settings by prefix (`rolltop.appearance.`, `rolltop.secondary-bar.`) from `exportAll()`.

## Services

Register replacements in `init(context:)`, resolve at use time (`context.services[.key]`), never keep a resolved service (registries and `.location` excepted: they are never replaced). The protocol, its default and its key live in `App/Contracts/Services.swift`, `FeatureServices.swift`, `AmbientServices.swift` (round 2 services), `Consents.swift`, or `Platform/LocationAccess.swift`.

| Key (name) | Protocol | Default | Provided by |
|---|---|---|---|
| `.itemImages` (`itemImages`) | `ItemImageProviding`: `image(for:itemIndex:height:)`, observable `revision`, `usesScreenCapture` | `AppIconImageProvider` | Capture |
| `.itemPanel` (`itemPanel`) | `ItemPanelPresenting`: `presentPanel(owners:anchor:request:)`, `dismissPanel()`, `dismissPanel(opener:)`, `isPanelVisible`, `currentOpener` | no-op | SecondaryBar |
| `.surfaces` (`surfaces`) | `TransientSurfaceCoordinator` (class): `willPresent(_:dismiss:)`, `didDismiss(_:restoreFocus:)`, `current` | itself | App/Contracts/Surfaces.swift |
| `.linkGate` (`linkGate`) | `LinkGating`: `handle(_:sender:)` | `CoreLinkGate` | Automation (`InteropLinkGate`) |
| `.ownStatusItems` (`ownStatusItems`) | `OwnStatusItemRegistry` (class): `register(_:id:)`, `mainItem`, `otherItems`, `image(at:height:)`, `mainFrame(…)` | itself | StatusItemController, CustomItems |
| `.paletteResultProviders` (`palette.result-providers`) | `PaletteResultProviderRegistry`: `register(_:)` | itself | Shelf (`shelf.clipboard`), CustomItems (`custom-items.groups`) |
| `.backupParticipants` (`interop.backup-participants`) | `BackupParticipantRegistry`: `register(_:)` | itself | Profiles, Automations, CustomItems |
| `.clipboard` (`shelf.clipboard`) | the Shelf's clipboard history for other features | none | Shelf |
| `.revealRouting` (`revealRouting`) | `RevealRouting`: observable `isHiddenPresented`, `presentsHiddenInPanel`, `toggleHidden/showHidden(anchor:gesture:source:)`, `collapse()` | `InlineRevealRouter` | SecondaryBar (`RolltopBarRevealRouter`) |
| `.profiles` (`profiles`) | `ProfileApplying`: `profiles`, `activeProfileID`, `applyProfile(id:)` | none | Profiles |
| `.profileLayoutRestorer` (`profiles.layout-restorer`) | `ProfileLayoutRestoring`: `restoreLayout(_:activeProfileID:)` | layout only | Profiles |
| `.hotkeyBindings` (`hotkeys.bindings`) | `HotkeyBindingProviding`: `shortcut(for:arguments:)`, `setShortcut`, `problem`, `conflictingTitle`, `displayString`, `title(for: HotkeyAction)`, observable `revision` | no shortcuts | Hotkeys |
| `.automationItemChanges` (`automations.item-changes`) | `AutomationItemChangeReporting`: `lastChanges` | nothing changes | **nobody yet** (Automations reads it) |
| `.settingsWindow` (`settingsWindow`) | `SettingsWindowPresenting`: `showSettings(paneID:)` | no-op | SettingsShell |
| `.consents` (`settings-shell.consents`) | `ConsentRegistry` (class): `register(_:)`, `unregister(id:)`, `items`, `statuses`, `status(for:)`, `item(id:)`, `refresh()`, `request(id:) async`, `requesting`, `revision` | itself | every feature that can raise a prompt (see "Consent rows") |
| `.location` (`location`) | `LocationProviding`: `authorization`, `servicesEnabled`, `isActive`, `isAuthorized`, `activate()`, `requestAuthorization()`, `currentLocation() async throws -> CLLocation`, `updates(minimumDistance:) -> AsyncStream<CLLocation>` | `LocationAccess` (Platform, the one `CLLocationManager`) | nobody replaces it; Automations and Weather use it |
| `.nowPlaying` (`media.now-playing`) | `NowPlayingProviding`: `state: NowPlayingState?`, `artwork: NSImage?`, `canControl`, `perform(_: NowPlayingCommand) async -> Bool` | `NowPlayingNone` (nothing playing) | Media; used by Shelf, CustomItems |
| `.weather` (`weather.report`) | `WeatherProviding`: `isEnabled`, `report: WeatherReport?`, `lastError: String?`, `attribution: WeatherAttribution`, `refresh() async` | `WeatherUnavailable` (disabled) | Weather; used by Shelf, CustomItems |
| `.upNext` (`shelf.up-next`) | `UpNextProviding`: `isAuthorized`, `nextEvent: UpNextEvent?` | `UpNextNone` (not authorized) | Shelf; used by CustomItems |
| `.focusState` (`interop.focus-state`) | `FocusStateProviding`: `isFocused: Bool?`, `label: String?`, `sourceNote: String` | `FocusStateUnknown` (unknown) | interop (`Features/Automation`); used by CustomItems |

New cross-feature services: add the protocol, default and `extension ServiceKey where Service == any MyProtocol { static var mine: Self { .init("<feature-id>.mine") { _ in Default() } } }` to `App/Contracts/FeatureServices.swift` through the integrator. Exception agreed for wave 2: W2-D (Automation) may add its backup-participation protocol there, with minimal conformances in Profiles and Automations.

**Item images.** Every image is exactly `height` points tall; its width follows the content (app icons square, symbols and captures at their aspect ratio): lay it out at its `size`, never force a square (`OwnerIcon` fits it into a tile and shows the owner's default image when a capture is more than 2.5× wider than tall). Monochrome images (symbols, monochrome captures) are templates (`isTemplate`): draw them with the surface's label colour (`.renderingMode(.template)`); coloured ones as they are. Defaults: an existing symbol for every `SystemModule` and the Apple agents above, the app icon otherwise. Screen reads for the same look (the Rolltop Bar's backdrop) run only while `usesScreenCapture`.

**Reveal routing.** `visibility.toggle-hidden`, `show-hidden` and `collapse` go through the router; `toggle-all`/`show-all` always reveal inline. With "Show hidden items in the Rolltop Bar" on (`presentsHiddenInPanel`), hidden items open in the panel and `level` stays `.collapsed`, so level-based behaviour (rehide timers, make room) does not apply to it; ask `isHiddenPresented` whether hidden items are up (Rolltop's icon and the Show Hidden Items checkmark do). The panel lists the hidden section (always-hidden behind a disclosure), recomputed while visible, without owners an automation forces visible. How it closes depends on how it opened: from Rolltop's item, a click (`gesture=click`), a shortcut or anything else: on a click outside (also on the bar or Rolltop's item; the toggle that same click runs within 0.5 s is swallowed), Escape, `visibility.collapse`, after activating an item, or after `rolltop.secondary-bar.idle-timeout` seconds without pointer activity (0 = never); from hover or scroll (`gesture=hover|scroll`): 0.5 s after the pointer leaves the menu bar strip, the panel and the gap between them. Shortcuts and the palette give it the keyboard. With "Use the Rolltop Bar when the menu bar is full" on (`rolltop.secondary-bar.when-full`), a reveal on a display that already shows macOS's overflow chevron opens the panel; and when an inline reveal makes the chevron appear on its own display (watched for about 1.2 s), the router collapses the inline reveal, presents the hidden items in the panel with the same anchor and gesture, and remembers that display in memory so the next reveal there opens the panel directly, until the layout, the present owners or the screens change or the switch is turned off.

**Panel ownership.** Whoever presents in the item panel says who it is: `presentPanel(owners:anchor:request: ItemPanelRequest(opener:gesture:onDismiss:))`. `opener` is `ItemPanelRequest.revealOpener` (`reveal`) for hidden items and `custom-items.group.<id>` for a group's members; `gesture` (`click`, `hover`, `keyboard`) decides how the panel closes, as for reveal above. `onDismiss` runs exactly once per presentation: `.closed`, or `.takenOver(by:)` when another opener's content replaces it (presenting again with the same opener updates the content without a callback). `dismissPanel(opener:)` closes only while that opener still owns the panel, so a group never closes the hidden items and reveal never closes a group. Nobody polls `isPanelVisible`: openers learn from `onDismiss`. `isHiddenPresented` is true only while `currentOpener == reveal`.

**One transient surface at a time** (`App/Contracts/Surfaces.swift`). The floating surfaces are `secondary-bar` (the Rolltop Bar, which also shows groups' members), `palette`, `shelf` and `custom-items.group` (a group's empty state). Before showing, call `context.services[.surfaces].willPresent(id) { _ in close without animation }`: the coordinator first closes the current surface (it logs `<a> yields to <b>`; the closed one reports reason `yielded`). After closing, call `didDismiss(id, restoreFocus:)`; it is ignored unless `id` is current. The coordinator remembers the app that was frontmost when a run of surfaces began (never Rolltop) and, when the last one closes by the user's choice (Escape, the toggle, a row that ran) while Rolltop is active, activates that app again; after a click elsewhere the app the user clicked keeps the keyboard. Settings and alerts are windows, not surfaces.

**Links** (`App/LinkIntake.swift`, `App/Contracts/Links.swift`). `LinkIntake` installs the `kAEGetURL` handler in `applicationWillFinishLaunching`, resolves the sender when the event arrives (`Platform/LinkSenderResolver.swift`: audit-token pid → app, tool or unknown) and queues links until every feature has started, then hands each to `.linkGate`. Automation registers `InteropLinkGate` (sender policy, aliases, prompts); the core default `CoreLinkGate` runs only URL-allowed display or Debug commands. A cold-start link therefore meets the same policy as any other. `application(_:open:)` links (no Apple event) arrive with sender `unknown`.

**Script runner** (`Platform/ScriptRunner.swift`). `ScriptRunner.run(command, timeout:, options:) async -> Result` runs `/bin/sh -c command` with `posix_spawn` in a new process group (`POSIX_SPAWN_SETPGROUP`, default signal actions, empty mask, close-on-exec by default), stdin `/dev/null`, output capped (`outputLimit`, 4096 bytes). On timeout it sends SIGTERM to the whole group and SIGKILL `killGrace` (1 s) later, so grandchildren (`sleep` in a pipeline) die too. Automation script conditions (home directory, stderr merged) and script widgets (`/`, stderr dropped) use it; nothing else spawns shells.

**Backup participation** (`BackupParticipating`, `.backupParticipants`). Participants export their own data as a section and own their settings keys (`backupOwnedSettingsKeys`), which the settings section leaves out: `profiles`, `automations`, `custom-items`. Rules with scripts and script widgets come back turned off after an import and after restoring an automatic backup (approvals never travel and are never restored; the restore confirmation says so). The Shelf contributes settings only (`rolltop.shelf.*` in the settings section); clips, stored files and up-next data never travel. Automatic backups are written before every import, restore and reset (`~/Library/Application Support/Rolltop/Backups`, newest ten kept).

**Palette providers** (`PaletteResultProviding`, `.paletteResultProviders`). The palette's own rows are items, commands, profiles and settings panes; providers add `Clipboard` (`shelf.clipboard`, only while clipboard history is on) and `Groups` (`custom-items.groups`). Return nothing for an empty query and **only rows that match**: the palette ranks provider rows with its own but keeps rows it cannot match after the matched ones. Answer from memory; each provider can be turned off in the Search pane. A row may carry a second action: `PaletteProvidedResult(id:title:subtitle:icon:keywords:alternateAction:action:)` with `alternateAction: PaletteAlternateAction?` (default nil), `PaletteAlternateAction(title: String, action: @MainActor () async throws -> Void)`; the palette runs it on ⌘Return instead of `action`, under the same rules (after the panel has closed, thrown errors shown), and names it in its footer while the row is selected ("⌘↩ Paste"). The second action always runs after the panel has closed, also when "close after running" is off, and first waits up to 0.5 s for the previous app to become active again (a paste needs that). The Shelf's clipboard rows use it ("Paste", or "Copy" when the user's default is paste).

**Now playing** (`.nowPlaying`, provided by Media). `NowPlayingState` (`nonisolated`, `Equatable`, `Sendable`): `player: NowPlayingPlayer` (`.music` = `com.apple.Music`, `.spotify` = `com.spotify.client`; `bundleID`, `displayName`), `title`, `artist?`, `album?`, `isPlaying` (false = paused). The artwork is a separate observable member, `artwork: NSImage?`, so the state stays a value. `state` is nil when nothing is known; `canControl` is true only while `state`'s player runs and its Apple Events consent is there; `perform(.playPause | .next | .previous) async -> Bool` (`NowPlayingCommand`) returns false when it could not act. The provider never launches a player and none of these members prompts: reading a player starts only after the user allowed it on that player's consent row.

**Weather** (`.weather`, provided by Weather; off by default). `WeatherReport` (`nonisolated`, `Equatable`, `Sendable`): `placeName`, `temperature`, `apparentTemperature`, `todayHigh`, `todayLow` (`Measurement<UnitTemperature>`; format with `.formatted()`/`MeasurementFormatter`, which follow the user's unit), `condition: WeatherCondition`, `isDaylight`, `windSpeed: Measurement<UnitSpeed>`, `windDirectionDegrees: Double?` (where the wind comes from, clockwise from north), `fetchedAt`, `symbolName`. `WeatherCondition(wmoCode:)` folds Open-Meteo's WMO codes into `clear` 0, `mainlyClear` 1, `partlyCloudy` 2, `overcast` 3, `fog` 45/48, `drizzle` 51/53/55, `freezingDrizzle` 56/57, `rain` 61/63/65, `freezingRain` 66/67, `snow` 71/73/75/77, `rainShowers` 80–82, `snowShowers` 85/86, `thunderstorm` 95, `thunderstormWithHail` 96/99, anything else `unknown`; `symbolName(isDaylight:)` (SF Symbols, each checked by a test) and `localizedName` (table `UI`) keep the Shelf card and the widget alike. `lastError` is a short localized sentence, nil after a success. `refresh() async` fetches now and never prompts. **Every display of weather data shows `attribution` next to it** (`WeatherAttribution.openMeteo`: localized text "Weather data by Open-Meteo.com" linking `https://open-meteo.com/`; `Link(a.text, destination: a.url)`), as the CC BY 4.0 license requires. The names `NowPlaying…` (`NowPlayingPlayer`, `NowPlayingState`, `NowPlayingCommand`, `NowPlayingProviding`, `NowPlayingNone`) and `Weather…` (`WeatherCondition`, `WeatherReport`, `WeatherAttribution`, `WeatherProviding`, `WeatherUnavailable`) are taken: the Media and Weather features prefix their own types differently (`MediaMusic…`, `WeatherOpenMeteo…`, `WeatherFeature…`).

**Up next** (`.upNext`, provided by Shelf from its calendar code). `isAuthorized` (Calendars full access; reading never prompts) and `nextEvent: UpNextEvent?`: the first timed event that has not ended (in progress, or the next to start) within today and tomorrow, never an all-day event; nil when there is none or not authorized; kept current by the provider. `UpNextEvent`: `id`, `title`, `start`, `end`, `isAllDay`, `location?`, `calendarColor: [Double]?` (sRGB components 0…1, like `ShelfEvent.color`), `color: Color?`.

**Focus** (`.focusState`, provided by interop in `Features/Automation`). `isFocused: Bool?` (nil = Rolltop cannot tell), `label: String?` (the Focus's name when known), `sourceNote: String` (one localized sentence the consumer shows to say what the value is based on, e.g. only Focuses that include Rolltop's Focus filter). Default: unknown, note "Rolltop can’t tell whether a Focus is on."

Value types have a `#if DEBUG` `sample` (`NowPlayingState.sample`, `WeatherReport.sample` at Greenwich, `UpNextEvent.sample`) for injected-data tests and Debug commands.

**Location** (`.location`, `Platform/LocationAccess.swift`). The one `CLLocationManager`, created lazily by `activate()` (resolving the service, and the test host, create nothing). Observable `authorization: LocationAuthorization` (`.notDetermined` until `activate()`, then the real `.notDetermined`/`.denied`/`.restricted`/`.authorized`), `servicesEnabled` (Location Services on for the Mac; read off the main thread and cached, true until read), `isActive`, `isAuthorized`. Reading them never prompts. `requestAuthorization()` shows the system prompt (only while `.notDetermined`) and runs **only from a click** (the `location.access` row, or a feature's own button). `currentLocation() async throws -> CLLocation`: one fix at ~100 m (the last one while updates run); throws `LocationAccessError` (`.notAuthorized`, `.servicesOff`, `.timedOut` after 20 s, `.failed`; localized `errorDescription`) instead of prompting. `updates(minimumDistance:) -> AsyncStream<CLLocation>`: low accuracy (~100 m); each stream yields when the Mac moved at least its `minimumDistance` metres since that stream's last value; one manager serves every stream with the smallest distance filter; calling it creates the manager (no prompt); updates run only while a stream exists (from the call until its iterating task is cancelled or the stream is released) **and** Rolltop is authorized and Location Services are on; while not authorized a stream stays open and silent and starts by itself once the user allows access; cancel the iterating task to end it; updates stop with the last stream. Never log a coordinate; store one only when the user saved that place. Tests register a fake before creating features (`context.services.register(fake as any LocationProviding, for: .location)`, see `RolltopTests/Automations/AutomationsLocationServiceTests.swift`) and use fixed public coordinates (Greenwich 51.4779, -0.0015). Automations' Wi-Fi name condition reads it (`AutomationsFeature.location`).

**Paste** (`EventSynthesizer.postPaste() -> Bool`, Platform). Posts one ⌘V (virtual key 9 down then up, both flagged `.maskCommand` and tagged with `EventSynthesizer.tag`) from a `.combinedSessionState` source that suppresses local keyboard events for the suppression interval, to `.cgSessionEventTap`; no Command key event is posted, so no modifier stays pressed. Returns false without posting when Rolltop is not trusted for Device Control and Data Access (`AXIsProcessTrusted`). Caller's precondition: the clipboard holds what to paste, Rolltop's surface has closed and the user's app is frontmost again; otherwise the paste lands in Rolltop. **No test, probe or Debug command may call it** (tests never post keys on this Mac): test the pure part (`EventSynthesizer.pasteKeyStrokes`, `keyEvents(for:source:)`, which posts nothing). Unverified on this Mac until the user tries it.

**Rolltop's own items** (`.ownStatusItems`). The main icon registers as `rolltop.main`, custom items under their autosave names. `statusItemFrame()` is always the main icon's frame. Images for Rolltop's owner come from these items (index 0 the main icon, then the others left to right), never from a capture and never the app icon; the layout editor shows one per slot MenuBarAgent lays out for Rolltop. Since round 2 the user can hide the main icon (`rolltop.general.show-status-item`, command `app.toggle-menu-bar-icon`; ⌘-dragging it out of the bar sets the same switch): `statusItemFrame()` is nil while it is hidden, `isMainVisible` says so, `itemCount` and `image(at:)` count visible items only (index 0 falls back to the hidden icon when nothing is visible), `mainFrame(…mainVisible:)`, `visibleItems`, `hiddenItemWindows` (a hidden item keeps a window with a stale frame and appearance: skip it), and `nudgeLayout() -> Bool` changes one visible item's content width by 0.5 pt for a frame (false when Rolltop has no visible item). Panels anchored to the icon fall back to the trailing end of the menu bar on the pointer's display.

## Debug and Release

- Debug-only code sits in `#if DEBUG`; Debug command ids are `debug.<verb>` or `<feature-id>.debug-<verb>` (`CommandID.isDebugOnly`), URL-allowed so live tests can drive them; pickers and menus skip them. Release builds register none: the launch log line `registered N commands: …` lists them (43 in Release after integration round 2, 2026-11-24) and logs an error if a Debug id slips in.
- `scripts/dev-install.sh --release [--no-launch]` builds and installs a Release build; reinstall Debug (`scripts/dev-install.sh --no-launch`) before live tests that need Debug commands. Install only while holding the lock (the installed app is shared). `--no-build` installs nothing: it only (re)launches what `/Applications/Rolltop.app` holds.
- **Live-testing a Release build** (no Debug commands, no dumps): build it outside the lock with the line dev-install uses (`xcodebuild -project Rolltop.xcodeproj -scheme Rolltop -configuration Release -destination "platform=macOS,arch=arm64" -derivedDataPath .build/dd build`), so the build inside the lock is a no-op. Seed what the test needs in Rolltop's own defaults **before** launch, while no Rolltop runs (e.g. `defaults write com.alphapengwang.rolltop rolltop.layout -data <hex of {"defaultSection":"shown","sections":{"com.alphapengwang.rolltop-fixture":"hidden"}}>`), then `live-lock.sh acquire`, `fixture.sh start a`, `dev-install.sh --release --shell` (its build step is then a no-op; `--no-build` would launch whatever is installed). Drive it only through links (`open -g -a /Applications/Rolltop.app 'rolltop://show'`, `rolltop://hide`, `rolltop://command/<id>` for URL-allowed display commands; Debug ids are refused as test hooks) and observe with `mbprobe`, `winlist` and the shell log (`tmp/rolltop-shell.log`). Quit with `rolltop://command/app.quit` (rolltop-cmd.sh works too), put the seeded keys back while no Rolltop runs, and compare `defaults export com.alphapengwang.rolltop` with the copy taken before. A LaunchServices launch (`open` without a running Rolltop) was not Accessibility-trusted on this Mac on 2026-11-24 but was on 2026-11-25 (launch log `Accessibility trusted: true`), so it may apply the layout like a shell launch; it shows onboarding while `rolltop.onboarding.state` is absent (PLATFORM §9): prefer `--shell`.
- A new feature's strings: use the table named like its directory and add `scripts/l10n/tm/<Name>.tm`; `l10n.py --build` creates `Rolltop/Features/<Name>/<Name>.xcstrings` next to the code on first use (it prints `new catalog`), so no shared file changes. Never commit an empty catalog (`l10n.py` reports `empty catalog`).
- Useful Debug commands: `debug.dump-state`, `settings-shell.debug-consents [reset=1]` (`~/Library/Application Support/Rolltop/debug/state.json`), `reveal.debug-set` (click, hover, hover-delay, scroll, scroll-all, rehide = seconds | clear, click-outside, app-switch, make-room, make-room-scope, reset=1), `reveal.debug-dump`, `reveal.debug-classify x= y=`, `secondary-bar.debug-configure` (enabled, idle-timeout, always-hidden, item-size), `secondary-bar.debug-dump`/`debug-present`, `capture.debug-set enabled=`, `capture.debug-refresh`, `capture.debug-contact-sheet`, `appearance.debug-style` (preset, kind, shape, …), `appearance.debug-reset`, `appearance.debug-dump`, `automations.debug-load path=/abs.json [approve-scripts=yes]`, `automations.debug-remove id=`, `automations.debug-dump`, `profiles.debug-export/import/delete/dump`, `hotkeys.debug-bind/reset`, `onboarding.debug-show simulate=`. Dumps go to `DebugFiles.directory` (`DebugFiles.writeJSON`); file inputs use `DebugFiles.inputURL`.

## Live testing (shared menu bar: read CLAUDE.md first)

```bash
xcodebuild -project Rolltop.xcodeproj -scheme Rolltop -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath .build/dd build   # outside the lock
scripts/live-lock.sh acquire <your-name> 900        # waits for other agents; hold ≤ 3 min
scripts/fixture.sh start a                          # com.alphapengwang.rolltop-fixture; `b` = RolltopFixtureB
scripts/dev-install.sh --shell                      # install (build is a no-op) and launch; records tmp/rolltop.pid
scripts/rolltop-cmd.sh layout.set-section owner=com.alphapengwang.rolltop-fixture section=hidden
scripts/rolltop-cmd.sh visibility.collapse
scripts/mbprobe --compact --wait-absent com.alphapengwang.rolltop-fixture --timeout 5 > out.json   # large JSON: use exit code / jq
# … test …
scripts/rolltop-cmd.sh layout.set-section owner=com.alphapengwang.rolltop-fixture section=default    # leave no test layout
scripts/rolltop-cmd.sh app.quit; scripts/fixture.sh stop all
scripts/mbprobe --compact --wait-present com.apple.menuextra.airdrop > /dev/null          # bar unrestricted again
scripts/live-lock.sh release
```

- Conceal only the fixtures. Before exercising anything that hides the user's own items (make room, hide everything, a default section other than shown), pin every present owner except the fixtures: `reveal.debug-pin-present except=com.alphapengwang.rolltop-fixture,com.alphapengwang.rolltop-fixture-b`, and `reveal.debug-restore-pins` afterwards (the original is held in memory only: never `kill -9` in such a session). `layout.set-default-section` freezes present owners itself. Reset what you set (`reveal.debug-set reset=1`, `appearance.debug-reset`, `secondary-bar.debug-configure enabled=false` then delete the keys you added) and compare `defaults export com.alphapengwang.rolltop` with a copy taken before.
- Helpers in `tmp/evidence/integration-1/harness/` (main checkout): `synth` (flag-less private-state `click X Y`, `rclick X Y`, `move X Y`, `scroll X Y DY [N]`, `where`; restores the pointer after clicks), `winlist <pid>` (on-screen windows, layer and bounds), `common.sh` (lock, launch, probe, cleanup) and the sessions `s0`–`s8` as examples. Never post keystrokes; clicks never carry modifier flags (PLATFORM §10).
- `rolltop-cmd.sh` refuses when the recorded instance is not running and addresses `/Applications/Rolltop.app` explicitly. Shell launches inherit the terminal's permissions; say so when reporting. Rolltop's item moves when hidden items appear: re-read its slot before clicking it again.
- Unit tests: `swift test --package-path Packages/RolltopCore`; `xcodebuild -project Rolltop.xcodeproj -scheme Rolltop -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/dd test` (the test host starts nothing and ignores URLs).
