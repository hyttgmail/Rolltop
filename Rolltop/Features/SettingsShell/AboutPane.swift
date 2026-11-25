import AppKit
import SwiftUI

/// Settings › About: name, version, what Rolltop is, and acknowledgements.
struct AboutPane: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    var body: some View {
        Form {
            SwiftUI.Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text(verbatim: "Rolltop")
                        .font(.title2.weight(.semibold))
                    Text("Version \(version) (\(build))", tableName: "SettingsShell")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Keeps your menu bar tidy: hide the items you don’t need all the time and bring them back with a click.",
                         tableName: "SettingsShell")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            SwiftUI.Section {
                Text("Rolltop is an independent app. It is not made, endorsed or supported by Apple or by the makers of any other menu bar app.",
                     tableName: "SettingsShell")
                    .fixedSize(horizontal: false, vertical: true)
            }
            SwiftUI.Section {
                LabeledContent {
                    if Self.thirdPartyNotices != nil {
                        Button {
                            showsNotices = true
                        } label: {
                            Text("Show License", tableName: "SettingsShell")
                        }
                    }
                } label: {
                    Text("Parts of Rolltop are adapted from Hidden Bar by Dwarves Foundation and Console Labs, used under the MIT License.",
                         tableName: "SettingsShell")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Acknowledgments", tableName: "SettingsShell")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsNotices) {
            AboutNoticesSheet(text: Self.thirdPartyNotices ?? "")
        }
    }

    @State private var showsNotices = false

    /// THIRD_PARTY_NOTICES.md from the repository root, copied into the app's resources.
    static let thirdPartyNotices: String? = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}

/// The license text as it ships: never translated.
private struct AboutNoticesSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(verbatim: text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done", tableName: "SettingsShell")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
    }
}
