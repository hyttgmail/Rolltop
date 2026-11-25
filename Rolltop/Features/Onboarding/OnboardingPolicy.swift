import Foundation
import RolltopCore

/// Where the user is with onboarding. Stored as its raw value in `rolltop.onboarding.state`.
nonisolated enum OnboardingState: String, CaseIterable, Sendable {
    /// Never shown on this Mac (or settings were reset).
    case notShown = "not-shown"
    /// Dismissed with Accessibility allowed.
    case completed
    /// Dismissed without Accessibility: never shown again by itself; Settings › Permissions
    /// and a status menu item take over.
    case dismissedWithoutAccess = "dismissed-without-access"
}

/// When the onboarding window opens by itself. Never nags: a dismissal without access is final.
nonisolated enum OnboardingPolicy {
    static func shouldShowAtLaunch(state: OnboardingState, accessibilityTrusted: Bool) -> Bool {
        switch state {
        case .notShown: true
        // Access was there once and is gone now (for example after moving the app).
        case .completed: !accessibilityTrusted
        case .dismissedWithoutAccess: false
        }
    }

    static func stateAfterDismissal(accessibilityTrusted: Bool) -> OnboardingState {
        accessibilityTrusted ? .completed : .dismissedWithoutAccess
    }

    /// Access granted later (through Settings): a later loss may show onboarding again.
    static func stateAfterAccessGranted(_ state: OnboardingState) -> OnboardingState {
        state == .dismissedWithoutAccess ? .completed : state
    }
}

enum OnboardingSettings {
    static let state = SettingsKey<String>("rolltop.onboarding.state", default: OnboardingState.notShown.rawValue)
}
