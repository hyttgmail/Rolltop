import SwiftUI

/// One permission with its live state, what Rolltop uses it for, where its switch is while it is
/// missing, and a button that opens the exact System Settings pane. Titled with the name of
/// that pane. Used by Settings › Permissions and the onboarding window.
struct PermissionRow: View {
    let kind: Permissions.Kind
    let permissions: Permissions
    let isRequired: Bool
    let purpose: Text
    /// Debug-only simulation (onboarding captures); nil reads the live state.
    var grantedOverride: Bool?

    private var isGranted: Bool { grantedOverride ?? permissions.isGranted(kind) }

    var body: some View {
        LabeledContent {
            PermissionStatus(isGranted: isGranted, isRequired: isRequired)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    title
                    Text(isRequired ? LocalizedStringResource("Required", table: "UI") : LocalizedStringResource("Optional", table: "UI"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                purpose
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isGranted {
                    // Where the switch is, by the names macOS 27 shows (scripts/l10n/glossary.md).
                    location
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    open()
                } label: {
                    Text("Open System Settings", tableName: "UI")
                }
                .controlSize(.small)
                .padding(.top, 2)
                .accessibilityIdentifier("permission.open.\(kind.rawValue)")
            }
        }
    }

    private var title: Text {
        switch kind {
        case .accessibility: Text("Device Control and Data Access", tableName: "UI")
        case .screenRecording: Text("Screen & System Audio Recording", tableName: "UI")
        }
    }

    private var location: Text {
        switch kind {
        case .accessibility:
            Text("Allow Rolltop in System Settings › Privacy & Security › Device Control and Data Access.", tableName: "UI")
        case .screenRecording:
            Text("Allow Rolltop in System Settings › Privacy & Security › Screen & System Audio Recording.", tableName: "UI")
        }
    }

    /// Runs only from a click. While the permission is missing, the request call adds Rolltop
    /// to the list in System Settings (macOS may show its own dialog for that); then the
    /// pane opens.
    private func open() {
        if !permissions.isGranted(kind) {
            switch kind {
            case .accessibility: permissions.requestAccessibility()
            case .screenRecording: permissions.requestScreenRecording()
            }
        }
        permissions.openSettings(for: kind)
    }
}

/// "Allowed" / "Not allowed" with a coloured symbol.
struct PermissionStatus: View {
    let isGranted: Bool
    var isRequired = true

    var body: some View {
        if isGranted {
            Label {
                Text("Allowed", tableName: "UI")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label {
                Text("Not allowed", tableName: "UI")
            } icon: {
                Image(systemName: isRequired ? "exclamationmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isRequired ? Color.orange : Color.secondary)
            }
        }
    }
}
