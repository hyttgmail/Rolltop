# Rolltop

Original macOS 27 menu bar manager. Read `docs/PLAN.md` (scope, architecture, milestones), `docs/PLATFORM.md` (verified macOS 27 mechanisms) and `docs/DESIGN.md` (design rules) before changing code.

## Build and run

- `xcodegen generate` then `xcodebuild -project Rolltop.xcodeproj -scheme Rolltop -configuration Debug -derivedDataPath .build/dd build`
- `swift test --package-path Packages/RolltopCore` for pure logic.
- `scripts/dev-install.sh` builds, installs to `/Applications/Rolltop.app` and launches. The app must run from `/Applications`: macOS 27 hides status items of apps that run from anywhere else.

## Live-machine safety (this is the user's working Mac; the menu bar is shared)

- Take the lock before any run that touches the live menu bar: `scripts/live-lock.sh acquire <name>`, release it when done, hold it for at most 3 minutes. Only one Rolltop instance may run at a time.
- Stop only the Rolltop instance you started, by its PID. Never `pkill`/`killall` by name.
- Never `killall MenuBarAgent`, `cfprefsd`, `ControlCenter` or `SystemUIServer`.
- Never quit, relaunch or send synthetic keystrokes to other apps. The terminal that runs this session has a menu bar item; a posted Escape or a relaunch kills the session.
- Never write another app's preference domain or Control Center's files. Before any write to `com.apple.MenuBar.plist`, copy it to the main checkout's `tmp/`.
- If a test writes `NSStatusItemSpacing` / `NSStatusItemSelectionPadding`, delete the keys again before finishing.
- Always leave the menu bar unrestricted when a test ends: quit the instance and confirm with `scripts/mbprobe`.
- Results obtained only under a shell launch (which inherits the terminal's permissions) are reported as such.

## Code rules

- Code and comments in English. User-facing strings through `String(localized:)` or SwiftUI literal keys.
- Private API lives only in `Rolltop/Platform/`, resolved at run time and wrapped so that a missing symbol degrades to "unavailable".
- A feature edits only its own `Rolltop/Features/<Name>/` directory and its tests. Shared contracts (`App/`, `Engine/`, `Platform/`, `Packages/RolltopCore`, `project.yml`, `Info.plist`) change only when the task says so; report any such change.
- Thaw is GPL-3: do not read or copy its source. Hidden Bar is MIT and may be consulted.
- Keep decisions in pure functions in `RolltopCore` with tests; keep AppKit/AX side effects thin.
