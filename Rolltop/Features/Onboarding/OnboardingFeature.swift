import Foundation
import RolltopCore

/// First-run window (what Rolltop does, Accessibility first, optional Screen Recording), also
/// shown at launch when Accessibility is missing unless the user already dismissed it
/// without granting. After such a dismissal only Settings › Permissions and a status menu
/// item mention it.
final class OnboardingFeature: FeatureModule {
    static let id: FeatureID = "onboarding"

    private unowned let context: AppContext
    private var window: OnboardingWindowController?
    private var accessObserver: ChangeObserver?
    private let log = Log.logger("onboarding")

    init(context: AppContext) {
        self.context = context
        context.settings.markTransient(OnboardingSettings.state)
    }

    private var state: OnboardingState {
        get { OnboardingState(rawValue: context.settings[OnboardingSettings.state]) ?? .notShown }
        set { context.settings[OnboardingSettings.state] = newValue.rawValue }
    }

    func start() {
        let trusted = context.launchInfo.accessibilityTrustedAtLaunch
        if OnboardingPolicy.shouldShowAtLaunch(state: state, accessibilityTrusted: trusted) {
            log.info("showing onboarding at launch (state \(state.rawValue), Accessibility \(trusted))")
            Task { @MainActor [weak self] in
                // Let launch finish so the window can take focus.
                try? await Task.sleep(for: .milliseconds(400))
                self?.show(simulation: nil)
            }
        }
        accessObserver = ChangeObserver(track: { [weak self] in _ = self?.context.permissions.accessibility }) { [weak self] in
            guard let self, self.context.permissions.accessibility else { return }
            let next = OnboardingPolicy.stateAfterAccessGranted(self.state)
            if next != self.state { self.state = next }
        }
    }

    func stop() {
        accessObserver?.cancel()
    }

    private func show(simulation: OnboardingSimulation?) {
        let window = window ?? OnboardingWindowController(permissions: context.permissions) { [weak self] simulated in
            self?.dismissed(simulated: simulated)
        }
        self.window = window
        window.show(simulation: simulation)
    }

    private func dismissed(simulated: Bool) {
        guard !simulated else { return }
        state = OnboardingPolicy.stateAfterDismissal(accessibilityTrusted: context.permissions.accessibility)
        log.info("onboarding dismissed; state \(state.rawValue)")
    }

    var commands: [Command] {
        let context = context
        var commands = [
            // Quiet reminder once onboarding was dismissed: only while access is missing.
            Command(id: "onboarding.allow-accessibility",
                    title: LocalizedStringResource("Allow Device Control and Data Access…", table: "Onboarding"),
                    symbol: "hand.raised", showInStatusMenu: true,
                    effect: .display,
                    isAvailable: { !context.permissions.accessibility }) { _ in
                context.services[.settingsWindow].showSettings(paneID: "permissions")
            },
        ]
        #if DEBUG
        commands.append(
            // Shell launches inherit the terminal's Accessibility grant, so the window would
            // never show by itself; `simulate` forces the state it displays.
            Command(id: "onboarding.debug-show", title: LocalizedStringResource("Show Onboarding", table: "Onboarding"),
                    symbol: "hand.wave",
                    arguments: [CommandArgument(name: "simulate", title: LocalizedStringResource("State", table: "Onboarding"),
                                                isRequired: false, allowedValues: ["granted", "not-granted"])],
                    allowedFromURL: true) { [weak self] invocation in
                switch invocation.string("simulate") {
                case "granted":
                    self?.show(simulation: OnboardingSimulation(accessibility: true, screenRecording: context.permissions.screenRecording))
                case "not-granted":
                    self?.show(simulation: OnboardingSimulation(accessibility: false, screenRecording: false))
                case nil, "":
                    self?.show(simulation: nil)
                case let other?:
                    throw CommandError.invalidArgument("simulate", other)
                }
            })
        commands.append(
            Command(id: "onboarding.debug-close", title: LocalizedStringResource("Close Onboarding", table: "Onboarding"),
                    symbol: "xmark", allowedFromURL: true) { [weak self] _ in
                self?.window?.close()
            })
        #endif
        return commands
    }
}
