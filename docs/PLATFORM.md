# macOS 27 menu bar platform facts

Reference for implementers. Every fact is tagged with its evidence:

- **[probe]** measured on this machine (macOS 27.2.1 build 26B131, Xcode 27.2, Swift 6.4.2) on 2026-11-24.
- **[sdk]** read from the macOS 27.2 SDK headers.
- **[hb]** Hidden Bar source/docs (MIT, github.com/dwarvesf/hidden), measured by its authors on 27.0.1 / 27.2.1.
- **[thaw]** Thaw 3 docs (github.com/thaw-app/Thaw). Thaw is GPL-3: read its docs for facts, never copy its code.
- **[unverified]** plausible but not confirmed; verify before relying on it.

When a probe and a document disagree, the probe wins.

## 1. Architecture change

- The whole menu bar is drawn by `/System/Library/CoreServices/MenuBarAgent.app` (`com.apple.MenuBarAgent`). Status items have no windows of their own. [probe]
- `CGWindowListCopyWindowInfo` shows one `Window Server` window named `Menubar` at layer 24 per display, nothing per item. [probe]
- Consequences: the oversized-divider trick, per-item window capture and per-item window moves are all dead. An `NSStatusItem` whose length would cross the left edge of the status area is dropped from layout instead of pushing others. [hb]
- Items that do not fit go into a native overflow chevron (`AXButton`, `AXIdentifier` `menu-bar-overflow-indicator`, `-expanded` when open). They never go behind the notch. No public API controls it. [hb]

## 2. Enumeration (public Accessibility API, needs Accessibility permission, impossible in the App Sandbox)

Two sources, both needed:

**A. Per-app list** — for every running app, `AXUIElementCreateApplication(pid)` → attribute `"AXExtrasMenuBar"` → children. [probe]
- Each child: role `AXMenuBarItem`, subrole `AXMenuExtra`, action `AXPress`, with `AXPosition`/`AXSize` in global top-left coordinates of the active display.
- Third-party items usually have empty title/identifier/description. Identity is the owning bundle id plus index.
- System modules are owned by `com.apple.MenuBarAgent`: each child is an `AXGroup`/`AXHostingView` whose single child carries `AXIdentifier` such as `com.apple.menuextra.wifi`, plus a localized `AXDescription` and sometimes `AXValue` (battery percent, clock text).
- Other system owners seen: `com.apple.systemuiserver` (Time Machine), `com.apple.TextInputMenuAgent` (input menu), `com.apple.campo` (Spotlight). They are addressed by bundle id.
- **A hidden app keeps reporting its stale frame here.** This list cannot tell drawn from hidden. [probe]
- Exception: MenuBarAgent's own list only holds what it draws. While a restriction is held, hidden system modules and the macOS-managed extras (AirDrop…) are missing from it, so keep earlier entries while restricted instead of dropping them. [probe 2026-11-24]
- **An app whose item has never been drawn** (started while concealed) has no `AXExtrasMenuBar` at all (`kAXErrorNoValue`, -25212) until it is drawn once; afterwards it reports the stale frame like any hidden app. It is invisible to list A, so a planner that only counts present owners sees nothing to conceal for it. [probe 2026-11-24]

**B. Drawn slots** — `AXWindows` of MenuBarAgent: one window per display; each child `AXGroup` is one slot that is actually drawn. [probe]
- Slot frame is in that display's global coordinates.
- Owner: the slot's first child is either an `AXHostingView` (system module, identifier on its child) or an element of the owning app (`AXApplication` on one display, `AXButton`/`AXUnknown` on another); `AXUIElementGetPid` on it gives the owner pid without messaging the other app. [probe]
- **Overflowed items keep a slot here**: they are stacked at the chevron's position (slot x-range overlaps the `menu-bar-overflow-indicator` button, which is a direct child of the same window). A slot overlapping the chevron is not visible in the bar; do not count it as drawn and do not press it. [probe 2026-11-24, built-in display with notch]
- A hidden item disappears from this tree 0.3–0.6 s after the restriction activates, and returns within ~0.1–0.6 s after release. [probe]
- Reading the tree costs 12–100 ms. [probe] A full refresh of both lists for ~57 running apps took 22–133 ms. [probe 2026-11-24]

Rules:
- Read apps concurrently off the main thread with `AXUIElementSetMessagingTimeout` (0.1–0.3 s, one retry at 0.5 s). The default timeout is 6 s per app. [hb]
- Skip `.xpc` and `.appex` processes. [hb]
- An app that times out or exposes no AX tree is treated as visible (fail open).
- `NSWorkspace` posts no launch notification for agent (LSUIElement) apps: observe `runningApplications` with KVO. [hb]
- **Never `AXPress` an item that is not confirmed drawn in list B.** Pressing an undrawn item leaves MenuBarAgent stuck in a selected state until it restarts. [thaw]

## 3. Hiding: allow-list assertion (private framework)

```
dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore")
MBAssessmentModeConfiguration
  - initWithAllowedSystemItems:(NSArray<NSNumber*>*) allowedBundleIdentifiers:(NSArray<NSString*>*)
  - initWithUnrestrictedMenuBarItems
MBAssessmentModeAssertion
  - init
  - activateWithConfiguration:completionHandler:   // ^(NSError * _Nullable)
  - invalidate
```
[probe: classes and selectors resolve; activation completes in ~4 ms with nil error]

- Semantics: only the listed system items and bundle ids stay visible; macOS hides everything else and reflows the bar. [probe]
- Released automatically when the process exits, including a crash. [probe: `invalidate`; hb: exit]
- Both arguments must be `NSArray` (an `NSSet` crashes). [hb]
- Wrap every call in an Objective-C `@try`: a changed private API must degrade to "unavailable", never crash. [hb]
- A list of 67 bundle ids is accepted. [probe] Build the list as **default-allow**: every known/running bundle that is not explicitly concealed.
- Granularity is per app. All items of one bundle hide together. [probe, hb, thaw]
- Order of operations when the list changes: activate the new assertion, and only on success invalidate the old one. Use a generation counter so a late completion invalidates itself. On failure, fail open. [hb]

**System item ids** (`allowedSystemItems`), decoded by probe on 27.2.1:

| id | module | AXIdentifier |
|---|---|---|
| 0 | Battery | `com.apple.menuextra.battery` |
| 1 | Bluetooth | `com.apple.menuextra.bluetooth` |
| 2 | Clock | `com.apple.menuextra.clock` |
| 5 | Sound | `com.apple.menuextra.sound` |
| 6 | Wi-Fi | `com.apple.menuextra.wifi` |
| 8 | Control Center | `com.apple.menuextra.controlcenter` |
| 3, 4, 7 | probably Displays, Keyboard, Screen Mirroring | **[unverified]** not present on this machine |

- Each of these can be hidden individually by leaving its id out. [probe]
- With an empty id list and all bundles allowed, every system module disappears. [probe]
- **AirDrop is hidden by any active restriction, whatever ids are passed.** [probe] Per [hb] the same applies to Focus, Now Playing, Live Activities, camera/microphone capsule, User, Siri and Stage Manager. These are "macOS-managed" and cannot be kept. So: hold no assertion at all whenever nothing present needs concealing.
- **`/Applications` rule**: a third-party app running from outside `/Applications` (resolved path; `~/Applications`, build folders and Downloads do not count) is hidden even when allowed. This includes this app's own status items. Always install to `/Applications` before running. [hb, thaw]
- Processes without a bundle id cannot be allowed.

**Clicks under a restriction** [probe on 27.2.1]: Wi-Fi, Sound and Control Center respond normally to both `AXPress` and a synthetic click. **The clock does not** [hb, 27.2.1]: clicks on it and the Notification Center shortcut are ignored while a restriction is active. Bridge:
1. Watch left mouse down/up (global monitor or session event tap). Identify the clock slot via `AXIdentifier == com.apple.menuextra.clock`; treat +6 pt toward the neighbour and +24 pt toward the screen edge as the clock.
2. On click: release the restriction, wait ≥80 ms (MenuBarAgent applies the release in 40–90 ms; earlier presses are dropped), replay the click with `CGEventSource(stateID: .privateState)`, flags cleared, click state 1, posted to `.cghidEventTap`.
3. Do not use `AXPress` on the clock: on 27.2 the panel opens and closes again.
4. Restore the restriction ~40 ms after the replayed press. Measured on 27.2.1 (2026-11-24): Notification Center opened ~180 ms after the click and **stayed open with the restriction back** (fixture and AirDrop hidden again while the panel was up); the restriction was lifted for ~230 ms in total. If no panel shows within ~0.4 s, lift again and hold the lift until the panel shows (≤1.5 s). Hard cap so the restriction always comes back. [probe; same approach as hb] *(Earlier text said "restore about 1 s after the panel closes"; that is not needed.)*
5. Panel open = process `com.apple.notificationcenterui` has a window with layer ≥ 0 and height ≥ half the screen that contains the AX identifier `widget-editor-button` (a notification banner alone does not count).
6. A click on the clock while the panel is open closes it, also under a restriction; check the panel at mouse-down and never replay then. [probe]

## 4. Activating a hidden item (secondary bar, search, hotkey)

1. Add the owner to the allow-list (temporary allow), keep the previous assertion if the swap fails.
2. Poll list B every 100 ms (up to ~1.5 s) until the owner has a drawn slot.
3. Left click: `AXPress` on the app's `AXExtrasMenuBar` child (AX timeout 0.5 s). Right click: `AXShowMenu`, else a synthetic right click. Electron apps ignore synthetic clicks. [hb, thaw]
4. `AXPress` may return `.cannotComplete` although it worked. Success = the owner pid (or Control Center for modules) gets a new window at layer ≥ 101 (pop-up menu level), or the app becomes active (panel style). [hb; probe: Control Center panels appear at layer 101]
   Measured with an `NSMenu` status item (2026-11-24): `AXPress` blocks ~0.7 s and returns `kAXErrorCannotComplete` (-25204) because the menu is tracking; the menu is a window of the app's pid at layer 101 whose bounds start 41 pt above the screen top (transparent margin, the visible menu starts below the bar). [probe]
5. Restore the planned allow-list when that window closes (cap ~15 s for panels, longer for menus). If the user changed the bar meanwhile, recompute instead of restoring.

## 5. Item order

- Stored in `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`, key `TrailingItemPreferredPositions`: a dictionary of `status:<bundle id or process name>::<autosave name or Item-N>` and `module:<Name>` (e.g. `module:WiFi`, `module:Clock` = 0, `module:BentoBox-0` = Control Center) to numeric weights. [probe: read]
- Another app's group container is protected: a normally launched app is silently denied until the user picks the file in an `NSOpenPanel` (keep a bookmark) or grants Full Disk Access. [thaw]
- Writing: re-read first (MenuBarAgent rewrites the file), write through cfprefsd, wait ~50 ms, then nudge layout by changing one of our own status items' `length` by 0.5 pt for one frame; verify through list B within ~0.7 s. [thaw] **[unverified on this machine — spike pending]**
- Synthetic ⌘-drag is unreliable on 27 and Thaw removed it. The user's own ⌘-drag still works natively. [thaw]
- Spike result (2026-11-24): `CFPreferencesCopyValue` on the path-based domain blocks inside cfprefsd until the user answers a consent prompt ("… would like to access data from other apps"), attributed to the responsible process. No value is returned before that. A direct file read from the shell worked. The write path is therefore **still unverified** and needs the user's consent to test. [probe]
- MenuBarAgent adds a `status:<process>::<autosaveName>` row as soon as any process publishes a status item, and never removes rows. [probe]
- Decision (round 1): order editing is not built until the user has allowed that access. **Round 2 built it and the write was verified on 2026-11-25: see §13.** Sections never depend on position.
- Do not read this container from tests (directly or through CFPreferences / `defaults`): it raises a consent prompt on the user's screen.

## 6. Capturing item images (optional Screen Recording permission)

- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)`: find the window owned by `com.apple.MenuBarAgent` that spans the display width and is ≤ 60 pt tall (it reports as off-screen). [thaw]
- `SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage` (`showsCursor = false`, `ignoreShadowsSingleWindow = true`) gives all icons on a transparent background. Crop per item with list-B frames; scale = `image.width / windowFrame.width`. Some builds report the window frame in pixels: normalise. [thaw]
- Fallback: capture the display's top strip. `screencapture -R` works from the shell on 27.2.1. [probe]
- Hidden items have no pixels: use the last cached image, else the app icon. Without Screen Recording, always use app icons. [hb, thaw]
- One strip capture costs ~260–290 ms; put a watchdog on every ScreenCaptureKit call. [thaw]

## 7. Own status items on macOS 27

- New public API: `NSStatusItem.expandedInterfaceDelegate` (`statusItem(_:didBegin:)`, `statusItemDidEndExpandedInterfaceSession(_:animated:)`), `expandedInterfaceSession.cancel()`. Use it for any of our items that open a panel instead of an `NSMenu`. [sdk]
- `NSMenuItem.preferredImageVisibility = .visible` is required for any menu item image to show when linked against the 27 SDK. [sdk]
- Use `LSUIElement` in Info.plist. Setting `.accessory` before the run loop starts, or running from a build folder, gives zero-height items. [thaw]
- Give every item a fixed `autosaveName` before it is first shown; never remove and recreate items, toggle `isVisible`. [thaw]
- `NSApp.activate` from a status item click is not always honoured (cooperative activation). [hb]
- Measured on 27.2.1 [probe, wave 1]: `NSApp.activate()` is refused both when a window is opened from the status menu and from a URL sent with `open -g`; calling `activate(ignoringOtherApps: true)` after the refusal brings the window to the front and makes it key.
- `NavigationSplitView` hosted in an `NSHostingController` ignores `navigationSplitViewColumnWidth` (sidebar stays 144 pt); fix the width on the underlying split view controller. [probe, wave 1]
- Our item's `button.window` still exists and `convertToScreen` gives the drawn position (matched list B within 1 pt). [probe 2026-11-24]
- MenuBarAgent forwards clicks on our items **without modifier flags**: on an Option-click `NSApp.currentEvent.modifierFlags` is empty; read `NSEvent.modifierFlags` (live state) instead. Right clicks arrive as `rightMouseUp` when the button uses `sendAction(on: [.leftMouseUp, .rightMouseUp])`, and `statusItem.menu = menu; button.performClick(nil); statusItem.menu = nil` still opens the menu (layer 101 window of our pid). [probe 2026-11-24]
- macOS 27 gives standard menu items a symbol of their own ("Settings…" got a gear although Rolltop set no image); `preferredImageVisibility = .hidden` removes it. [probe, integration 2026-11-24]
- SF Symbols has no Bluetooth glyph; Rolltop's default image for the module is `dot.radiowaves.left.and.right`. [sdk]
- Quit and `kill -9` with the menu bar styled (tint, split), the Rolltop Bar open over a concealed fixture and a clock widget ticking: after `app.quit` the process is gone within 2 s, the fixture and AirDrop are drawn again by the first probe (97 ms) and no Rolltop window remains; after `kill -9` the same within 137 ms. The overlay, the panel and the widgets die with the process; nothing is left to clean up but the settings themselves. [probe, integration 2026-11-24; shell launch]
- `app.quit` with an `NSAlert` sheet open on the settings window: ending the sheet, then `NSApp.terminate` asynchronously, exits in ~0.4 s. After `kill -9` with a restriction held, MenuBarAgent draws the concealed items again within 0.13 s and no Rolltop window remains: the assertion dies with the process. [probe, integration 2026-11-24; shell launch]

## 8. Appearance overlay and spacing

- Overlay: one borderless non-activating panel per display, ignores mouse events, `collectionBehavior` `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`. [thaw]
- Window level, measured on 27.2.1 [probe, wave 1]: level 25 covers the menu titles; level 24 stays under the Menubar window only because the window server happens to order it behind within that layer; **level 23 is reliably below and is what Rolltop uses**. AppKit moves windows below menu-bar level down so they start under the bar: the panel must override `constrainFrameRect`.
- The menu bar's text colour ignores the overlay and the system appearance (white text over a dark wallpaper while the system is Light). The `effectiveAppearance` of our own status item's window (`NSStatusBarWindow`) reports the bar's real appearance (VibrantDark here) and is the signal for choosing contrasting colours. A light bar over a bright wallpaper is **[unverified]**.
- The overlay only shows through when System Settings › Menu Bar › "Show menu bar background" is off (global key `SLSMenuBarUseBlurredAppearance`; unset on this machine with a transparent bar, so absent = off). [thaw, probe] Deep link host: `com.apple.ControlCenter-Settings.extension`.
- Every app's `AXMenuBar` reports its menu title frames on the active display, frontmost or not; MenuBarAgent's AX windows contain only status slots. [probe, wave 1]
- Full-screen Spaces and Mission Control behaviour of the overlay is **[unverified]**.
- Window layers measured together (integration 2026-11-24): overlay 23, Rolltop Bar panel 25, status-item menus 101, so the panel and every menu sit above the overlay. `screencapture -x` of the screen strip shows the overlay; the item captures (MenuBarAgent's window, §6) report `transparent: true` on both displays and carry no tint. The split pill's trailing segment follows `statusItemsMinX` (1563 → 1497.5 on the main display when one item appeared; on the notched display it moved right, 987 → 999.5, not investigated) by the next dump 1.2 s later. [probe; shell launch]
- Spacing: `NSStatusItemSpacing` and `NSStatusItemSelectionPadding` in the global domain, current host (`defaults -currentHost write -globalDomain <key> -int <n>`), default 16 each. Apps read them when they create their first status item, so a change applies after the app relaunches or the user logs in again. Both keys are unset on this machine. [thaw, probe]

## 9. Permissions and launch paths

- A binary started from a shell inherits the terminal's Accessibility, Screen Recording and file access. [probe: CLI probes were AX-trusted]
- A normal launch (`open`, Finder, login item) needs its own Accessibility grant, optional Screen Recording grant, and its own access to the layout file. These need the user. Results obtained only under a shell launch must be reported as such.
- Sign with the local "Apple Development" identity so grants survive rebuilds (ad-hoc signatures change the requirement on every build).
- **Pane names on 27.2.1**: the Accessibility grant (`kTCCServiceAccessibility`) lives in System Settings › Privacy & Security › **Device Control and Data Access** (zh_CN 系统设置 › 隐私与安全 › 设备控制和数据访问; SecurityPrivacyExtension `Localizable.loctable` key `ACCESSIBILITY`, `InfoPlist.loctable` for 隐私与安全), Screen Recording in **Screen & System Audio Recording** (录屏与系统录音, key `SCREENANDAUDIOCAPTURE`). zh_CN 无障碍 is the unrelated top-level Accessibility pane (AccessibilitySettingsExtension). Observed by the owner: searching System Settings for 辅助功能 finds nothing, and `…security?Privacy_Accessibility` opens the renamed pane (window title 设备控制和数据访问). Rolltop's wording: `scripts/l10n/glossary.md`. [probe 2026-11-25; `Privacy_ScreenCapture` unverified]
- Telling the launch path apart (measured with fixture a, 2026-11-24): `open -g -a X.app` from a shell passes the caller's environment on (`SHLVL`, `TERM`, `TERM_PROGRAM`, `PWD`), and the parent pid is 1 both for that and for a `nohup … &` shell launch whose shell exited. What differs: LaunchServices runs the app as its own launchd job, `XPC_SERVICE_NAME=application.<bundle id>.<n>.<n>` and `__CFBundleIdentifier=<bundle id>`; a shell launch inherits the terminal's (`0`, `com.stablyai.orca`). `LaunchInfo.launchedByLaunchServices` uses that. [probe]
- `/Applications/Rolltop.app` started through LaunchServices (a cold-start link) is **not** Accessibility-trusted on this Mac, while the shell launch is (inherited): it logs `Accessibility trusted: false`, shows onboarding and activates. Every live result in integration rounds 1–2 except that cold start ran under a shell launch. [probe, integration 2026-11-24] **2026-11-25 00:38:** one Release launch with `dev-install.sh --release --open` logged `Accessibility trusted: true` and showed onboarding with Device Control and Data Access allowed (`rolltop.onboarding.state` was absent). [probe] Presumably Rolltop was allowed in that pane meanwhile, so a LaunchServices launch may now apply the layout and hide items; check the launch log line before relying on either. [inferred]
- A link that starts Rolltop (`open -g -a /Applications/Rolltop.app 'rolltop://…'` while it is not running) arrives as `kAEGetURL` before `applicationDidFinishLaunching`: `LinkIntake` queued it and delivered it 75 ms later, after every feature had started, through the same gate as any link (a destructive command was refused). [probe, integration 2026-11-24]
- The sender of a link sent with `open` is the `open` process, which often exits before Rolltop resolves it: 49 of 63 links in one session resolved to `tool(/usr/bin/open)`, 14 to `unknown(-, pid …)` (no path any more). Policy treats both as senders that cannot be asked. [probe, integration 2026-11-24]

## 10. Synthetic events

- A mouse event posted to `.cghidEventTap` **with modifier flags** (e.g. `.maskAlternate`) leaves that modifier set in the HID system state: `NSEvent.modifierFlags` and `CGEventSource.flagsState(.hidSystemState)` keep reporting it, and events created from a `.hidSystemState` source inherit it, until another event clears it. Post flag-less events from a `.privateState` source (Rolltop's `EventSynthesizer` does). A test that needs a modifier must post a flag-less `mouseMoved` afterwards. [probe 2026-11-24]
- A click posted from a `.privateState` source does not reset `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)`, so code that asks "was there a click just now?" sees none after a synthetic click. Callers that know the gesture pass it (`visibility.toggle-hidden gesture=click`) instead of inferring it. [inferred, integration 2026-11-24: a synthetic click on the bar opened the Rolltop Bar as `pointer-hover`, which needs ≥ 0.7 s since the last click by that call; not measured directly]
- A right click posted the same way (`rightMouseDown`/`rightMouseUp`, `.right` button, flags cleared) on Rolltop's item opens its menu; a left click elsewhere on the bar closes it. [probe, integration 2026-11-24]

## 11. Screens on this machine

- LG UltraFine 2304×1296 pt (main, no notch, menu bar 30 pt) and built-in 1728×1117 pt (notch, `safeAreaInsets.top` 32, auxiliary areas 771.5 pt wide each side). [probe]
- Menu bar strip height = `screen.frame.maxY - screen.visibleFrame.maxY`; it is 0 in full screen.
- The built-in display's global top-left origin is (2304, −37) and its Menubar window is 33 pt tall; its capture rectangle is `2304,-37,1728,40`. [probe, wave 1]
- After an app quits its item leaves the bar within ~0.24 s, but its slot stays in MenuBarAgent's AX tree for ~0.9 s: discount slots whose process is gone. [probe, wave 1]

## 12. Toolchain

- `xcodebuild` compiles string catalogs but never writes new keys back into the `.xcstrings` files; sync them with `xcrun xcstringstool sync <catalogs> --stringsdata <Objects-normal/arm64/*.stringsdata>` after a build. [probe, integration 2026-11-24]
- `formatted(.list(type: .and))` joins with the system locale's conjunction ("Clock和Control Center" on a Chinese system running the English app); pass `.locale(Locale(identifier: Bundle.main.preferredLocalizations[0]))`. [probe]
- A Release build registers 31 commands, none of them Debug-only (launch log line `registered N commands`, 2026-11-24); 43 after integration round 2, still none Debug-only, and a `rolltop://command/debug.dump-state` link is refused as an unknown command. [probe, shell launch] The RolltopCore constant `debug.dump-state` still appears as a string in the Release binary. [probe]
- `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (pgroup 0) puts `/bin/sh -c` in its own process group; `kill(-pgid, SIGTERM)` then reaches the grandchildren a script starts (`sleep 30 | cat`), which `Process.terminate()` (the child only) did not. `posix_spawn_file_actions_addchdir_np` is deprecated in the 27 SDK; use `posix_spawn_file_actions_addchdir`. [probe, ScriptRunnerTests 2026-11-24]
- Clearing the settings sidebar search (SwiftUI `List` with `Section`s and `.searchable`) logs "WARNING: Application performed a reentrant operation in its NSTableView delegate" once, whether sections are identified by their first row or by their sort-order range; nothing visible goes wrong. Not fixed. [probe, integration 2026-11-24]
- `swiftc` (6.4) crashes in SILGen on a key path through an existential metatype (`FeatureRegistry.all.map(\.id.rawValue)`); use a closure. [probe]

## 13. Round 2 facts (2026-11-25)

- **GPU usage**: `IOServiceMatching("IOAccelerator")` → `PerformanceStatistics` → `Device Utilization %` (class AGXAcceleratorG16X here). Every read resets the measuring window: a second read right after another returns 0, so sample on your own cadence (2 s) and do not compare with a simultaneous `ioreg`. [probe]
- **Spaces**: `CGSCopyManagedDisplaySpaces` returns per display `Display Identifier` (the display's UUID), `Current Space` and `Spaces`; each Space has `ManagedSpaceID`, `id64`, `type` (0 = desktop) and `uuid`. The main display's only desktop has an empty `uuid`. `CGSGetActiveSpace` returns a single value, not one per display: use `Current Space`. [probe] The `type` of a full-screen Space and the `"Main"` identifier are [unverified]. Rolltop only reads; real Space switching was not exercised (no keystrokes in tests).
- **Brightness**: `DisplayServicesGetBrightness` and `DisplayServicesRegisterForBrightnessChangeNotifications` resolve. Only the built-in display reads (0.0 while it is asleep/closed); the LG UltraFine reads nothing. [probe] Whether the notification fires on a key press is [unverified].
- **Own status items**: turning `isVisible` off on an autosaved item makes AppKit write `NSStatusItem VisibleCC <autosave name>` into the app's defaults. A hidden item keeps its `NSStatusBarWindow` with `isVisible` true; hidden mid-session it keeps a stale frame and appearance, hidden from launch it has a zero-height frame and reports `VibrantLight` under a dark bar. A fixed length L draws a slot of about L + 16 pt; a variable item's slot is 33 pt for 17 pt of content. [probe]
- **Launch**: a shell launch and an `open` launch both arrive as `aevt/oapp` without `keyAEPropData`; `open -g -a` on a running Rolltop calls `applicationShouldHandleReopen`. Whether a login item's `oapp` carries `keyAELaunchedAsLogInItem` on 27 is [unverified]; Rolltop also treats a LaunchServices start within 120 s of the console login as a login launch. [probe]
- **Apple events consent**: `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: false)` returns noErr, -1743 (refused), -1744 (would need the prompt) or -600 (target not running). [sdk] AppKit suspends distributed notifications while an app is inactive: observe the players' notifications (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`) with `.deliverImmediately`. [sdk] The notifications' key names on 27 are [unverified]; Spotify is not installed on this Mac, so its scripting codes are [unverified].
- **Focus**: `INFocusStatus` is a single Bool; per one developer report on macOS 27 it stays false without the Communication Notifications entitlement, which needs a provisioning profile. [web, unverified here] Rolltop's Focus state comes from its Focus Filter, and a filter saved without a profile cannot be told from "Focus ended".
- **iCloud key-value store**: Apple's page says the app must be distributed through the App Store and request the (restricted) entitlement; signing with a restricted entitlement and no matching provisioning profile gets the app killed at launch. [web] Not built.
- **Allow list** ("Allow in the Menu Bar"): `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`, key `trackedApplications` = `Data` holding a binary plist, a flat array alternating a key `{bundle:{_0:<id>}}` (or `{adhocBinary:…}`) and a value `{location, menuItemLocations, isAllowed}`. [web; confirmed on this Mac 2026-11-25 03:41 with `layout-editor.debug-verify-turned-off` in a normally launched Debug build: root array of 100 (50 pairs), key `{bundle:{_0:string}}`, value `{isAllowed: Bool, location:{bundle:…}, menuItemLocations:[…]}`, 42 allowed and 8 not allowed, nothing skipped]
- **Layout table weights** look like distances from the right edge (`module:Clock` 0, `module:BentoBox-0` 133). **Writing works** [probe 2026-11-25 03:41, normally launched Debug build, access through the file the user picked]: `layout-editor.debug-verify-order phase=swap` raised one fixture's weight (633 → 670.5, above the other's 650.5) through CFPreferences on the path-based domain, nudged one of Rolltop's own items, and list B showed the two fixtures swapped 0.14 s later; writing the old weight back restored the order. A status item with an autosave name gets the key `status:<bundle id>::<autosave name>` (`…RolltopFixture::fixture`). The table had 88 keys.
- **Access to the two files** [probe 2026-11-25, normal launch]: the user ended up using "Choose File…" for both rows (state `chosen-file`); after the pick a bookmark read returned the file in 2–17 ms, and the grant given to the Release build carried over to the Debug build (same designated requirement). Whether "Allow…" ever raises the "access data from other apps" dialog for a normally launched Rolltop is still unknown: the trace of the first attempt was overwritten.
- **Location**: under a shell launch `CLLocationManager.locationServicesEnabled()` returned false and the Location row showed "Can't ask now"; cause not established. Creating the manager and reading its status raised no prompt. [probe, shell launch]
- **Open-Meteo** (checked 2026-11-25): no key for non-commercial use, fewer than 10 000 calls a day, CC BY 4.0 with a link next to the data, server logs may hold coordinates for 90 days.
- **Overflow on the notched display** [probe 2026-11-25, shell launch, the user's layout]: with five hidden apps revealed inline, the built-in display shows three of them and the « chevron holds the other two; the chevron is in list B about 0.2 s after the reveal and is gone again after a collapse, so it cannot be seen in advance. Clicking the chevron draws the overflowed items to the left of the notch and turns it into » (the user's screenshots). A reveal started on the external display raises the chevron on the built-in display too, because every display draws the same items.
- **Overflowed, then concealed: the extras bar is gone** [probe 2026-11-25, shell launch, a click on Rolltop's item on the built-in display]: an app whose item sat behind the overflow chevron when the restriction came back reports no `AXExtrasMenuBar` at all (`kAXErrorNoValue`, -25212), like an app that was never drawn (§2), while apps that had been drawn normally keep one child. It stays that way (checked 7 s later after a full refresh) until the item is drawn again: a temporary allow (`item.activate`) drew it, the extras bar came back with one child and `AXPress` opened its menu. Seen for both fixtures and one of the user's apps; in the user's own session the Rolltop Bar went from five items to three within 4 s for this reason. It did not reproduce when the reveal was driven by a Debug route command while the external display was the active one [inferred: list A follows the active display, §2]. The catalog now carries such entries over while they are concealed (`CatalogBuilder`, RolltopCore).
- **Tooling**: `defaults import` merges instead of replacing: delete the domain first for an exact restore. A localizable string with "20 %" trips the placeholder check ("% a" reads as a format specifier): avoid a bare percent sign in keys.

