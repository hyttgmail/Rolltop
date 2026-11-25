# Design rules (macOS 27)

Sources: Apple Human Interface Guidelines (2026), WWDC26 sessions 101/269/272/289, macOS 27 release notes, and the macOS 27.2 SDK headers. Items marked **[sdk]** were checked against the local SDK.

## Principles

- The design language is still Liquid Glass; macOS 27 tuned it for legibility and added a system-wide clear-to-tinted slider that applies to adopters automatically. Use system materials and controls so user settings carry over. Never hard-code translucency.
- Glass belongs to the floating control layer only: the secondary bar, the command palette, the shelf. Never use glass inside content (settings forms, lists). Use standard materials and `.formStyle(.grouped)` there.
- Use glass sparingly; tint backgrounds, not symbols or text. Clear glass only over visually rich backgrounds.
- Every window on macOS 27 has the same tighter corner radius. Do not set custom window corner radii. Nested shapes must be concentric with their container.
- Sidebars extend to the window edge; sidebar selection is semibold; sidebar icons are coloured again.
- macOS has no Dynamic Type. Body text is 13 pt, minimum 10 pt. Use system text styles.
- Respect Reduce Motion, Reduce Transparency and Increase Contrast (system materials do this for you).

## Status items

- Template images (black + clear), SF Symbols preferred. Menu bar height is 24 pt of content; the system supplies padding.
- A click shows a menu unless the content is too complex for one. Our main icon toggles hidden items on left click, toggles all items (including always hidden) on Option-click, and shows a menu on right click or Control-click.
- Items that open a panel instead of a menu must use `NSStatusItem.expandedInterfaceDelegate` so they take part in menu tracking and keyboard navigation. **[sdk]**
- The user decides whether our item is in the menu bar; the app must stay reachable without it (reopening the app opens Settings).

## Menus

- When linked against the macOS 27 SDK, menu item images are hidden by default. Use icons only where they identify an object (another app's item, a profile, a device), and for those set `preferredImageVisibility = .visible` (SwiftUI: `.labelStyle(.titleAndIcon)`). **[sdk]**
- Within one group, either every item has an icon or none does.
- macOS 27 still adds its own symbols to some standard items ("Settings…" gets a gear); every item without an identifying icon sets `preferredImageVisibility = .hidden`. **[probe]**

## Settings window

- Sidebar + detail (`NavigationSplitView`), like System Settings: fixed sidebar (no toggle), a search field, grouped forms on the right.
- The window title follows the selected pane. Restore the last viewed pane. `⌘,` opens it. Minimize and zoom are disabled.
- Changes apply immediately; no Save button.
- Rows: leading label, trailing control (`LabeledContent`, `Toggle`, `Picker`). A short secondary caption under a row explains consequences. Limitations imposed by macOS are stated plainly where they apply, not hidden in a help page.

## Floating panels (secondary bar, palette, shelf)

- Borderless, non-activating `NSPanel`; the content sits on `NSGlassEffectView` (26.0+) with `effectIsInteractive = true` (27.0+) when it hosts controls, or SwiftUI `glassEffect` inside a `GlassEffectContainer`. **[sdk]**
- Capsule or concentric rounded shapes: `NSViewCornerConfiguration` / `ConcentricRectangle` (27.0+ / 26.0+). **[sdk]**
- One transient panel at a time. Dismiss on Escape, on click outside, and when the trigger ends.
- Inside sheets and popovers `controlSize` resets to default on the 27 SDK; set it again where needed.
- Buttons on glass: `.buttonStyle(.glass)` / `.glassProminent`; one prominent action at most.

## Onboarding and permissions

- Short. Ask for Accessibility first and explain what it is used for in one sentence; Screen Recording and layout-file access are optional and say what improves when granted.
- Each permission row shows its live state and a button that opens the exact System Settings pane.
- UI text names permissions after the macOS 27 panes (Device Control and Data Access, Screen & System Audio Recording), never "Accessibility" or "Screen Recording": see "Permission names" in `scripts/l10n/glossary.md`.
- The app works in a reduced mode without optional permissions and says what is reduced.

## Writing

- Sentence case for labels and titles inside windows and panels; no exclamation marks; name the thing, not the mechanism ("Hidden items", not "Concealed owners").
- Title Case where macOS uses it: menu items and command titles ("Show Hidden Items", "Hide Everything"; they also appear in Shortcuts and the palette), settings pane titles in the sidebar, buttons that open something ("Save Current Setup…").
- All user-facing strings go through `String(localized:)` or SwiftUI literal keys so they can be localized (English source, Simplified Chinese added later).

## App icon

- Icon Composer layered icon, 1024×1024, unmasked layers, default / dark / clear / tinted variants; let the system apply blur and specular effects.
