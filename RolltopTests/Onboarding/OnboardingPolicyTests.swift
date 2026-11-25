import Testing
@testable import Rolltop

@Suite struct OnboardingPolicyTests {
    @Test func showsOnFirstRunWhateverTheAccess() {
        #expect(OnboardingPolicy.shouldShowAtLaunch(state: .notShown, accessibilityTrusted: true))
        #expect(OnboardingPolicy.shouldShowAtLaunch(state: .notShown, accessibilityTrusted: false))
    }

    @Test func showsAgainOnlyWhenAccessWasLost() {
        #expect(!OnboardingPolicy.shouldShowAtLaunch(state: .completed, accessibilityTrusted: true))
        #expect(OnboardingPolicy.shouldShowAtLaunch(state: .completed, accessibilityTrusted: false))
    }

    @Test func neverNagsAfterADismissalWithoutAccess() {
        #expect(!OnboardingPolicy.shouldShowAtLaunch(state: .dismissedWithoutAccess, accessibilityTrusted: false))
        #expect(OnboardingPolicy.stateAfterDismissal(accessibilityTrusted: false) == .dismissedWithoutAccess)
        #expect(OnboardingPolicy.stateAfterDismissal(accessibilityTrusted: true) == .completed)
        #expect(OnboardingPolicy.stateAfterAccessGranted(.dismissedWithoutAccess) == .completed)
        #expect(OnboardingPolicy.stateAfterAccessGranted(.notShown) == .notShown)
    }

    @Test func storedValuesRoundTrip() {
        for state in OnboardingState.allCases {
            #expect(OnboardingState(rawValue: state.rawValue) == state)
        }
        #expect(OnboardingSettings.state.defaultValue == "not-shown")
    }
}
