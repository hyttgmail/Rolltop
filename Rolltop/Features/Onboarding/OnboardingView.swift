import AppKit
import SwiftUI

/// Debug-only stand-in for the live permission state, so both states can be captured
/// under a shell launch (which inherits the terminal's Accessibility grant).
struct OnboardingSimulation: Equatable {
    var accessibility: Bool
    var screenRecording: Bool
}

/// The first-run window: what Rolltop does, the Accessibility step, the optional Screen
/// Recording step, and Done.
struct OnboardingView: View {
    let permissions: Permissions
    var simulation: OnboardingSimulation?
    let onDone: () -> Void

    static let size = CGSize(width: 520, height: 560)

    private var accessibilityGranted: Bool { simulation?.accessibility ?? permissions.accessibility }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("Welcome to Rolltop", tableName: "Onboarding")
                    .font(.title2.weight(.semibold))
                Text("Rolltop hides the menu bar items you don’t need all the time. Click its icon in the menu bar to bring them back.",
                     tableName: "Onboarding")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 36)
            .padding(.horizontal, 40)

            Form {
                SwiftUI.Section {
                    PermissionRow(kind: .accessibility, permissions: permissions, isRequired: true,
                                  purpose: Text("Lets Rolltop see which items are in the menu bar, and hide or open them.",
                                                tableName: "Onboarding"),
                                  grantedOverride: simulation?.accessibility)
                } header: {
                    Text("Step 1", tableName: "Onboarding")
                }
                SwiftUI.Section {
                    PermissionRow(kind: .screenRecording, permissions: permissions, isRequired: false,
                                  purpose: Text("Shows the real icons of hidden items. You can skip this: Rolltop then shows app icons.",
                                                tableName: "Onboarding"),
                                  grantedOverride: simulation?.screenRecording)
                } header: {
                    Text("Step 2, optional", tableName: "Onboarding")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack(alignment: .center) {
                if !accessibilityGranted {
                    Text("You can allow it later in Settings › Permissions.", tableName: "Onboarding")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onDone()
                } label: {
                    Text("Done", tableName: "Onboarding")
                        .frame(minWidth: 64)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding.done")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
