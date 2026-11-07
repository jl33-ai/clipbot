import AppKit
import ClipbotCore
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let onClearHistory: () -> Void
    let onRecording: (Bool) -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axTrusted = Permissions.accessibilityTrusted
    @State private var pbAccess = Permissions.pasteboardAccess
    @State private var selectedIgnored: String?
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("History & snippets") {
                    ShortcutRecorder(shortcut: $prefs.mainShortcut, defaultValue: .mainDefault, onRecording: onRecording)
                }
                LabeledContent("History only") {
                    ShortcutRecorder(shortcut: $prefs.historyShortcut, defaultValue: .historyDefault, onRecording: onRecording)
                }
                LabeledContent("Snippets only") {
                    ShortcutRecorder(shortcut: $prefs.snippetsShortcut, defaultValue: .snippetsDefault, onRecording: onRecording)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {}
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }

            Section("Permissions") {
                permissionRow("Accessibility (to paste for you)", ok: axTrusted, action: Permissions.openAccessibilitySettings)
                permissionRow("Clipboard access", ok: pbAccess == .allowed,
                              detail: pbAccess == .ask ? "macOS will ask each time" : nil,
                              action: Permissions.openPrivacySettings)
            }

            Section {
                List(selection: $selectedIgnored) {
                    ForEach(prefs.ignoredBundleIDs, id: \.self) { id in
                        Text(appName(id)).tag(id)
                    }
                }
                .frame(minHeight: 110)
                HStack {
                    Button("Add App…", action: addIgnoredApp)
                    Button("Remove") {
                        prefs.ignoredBundleIDs.removeAll { $0 == selectedIgnored }
                        selectedIgnored = nil
                    }.disabled(selectedIgnored == nil)
                    Spacer()
                    Button("Restore Defaults") {
                        prefs.ignoredBundleIDs = Array(Set(prefs.ignoredBundleIDs).union(SecretFilter.defaultIgnoredBundleIDs)).sorted()
                    }
                }
            } header: {
                Text("Never record copies from")
            } footer: {
                Text("Passwords copied from 1Password, Apple Passwords and other password managers are always skipped, whatever this list says. Anything copied while a password field is focused is skipped too.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear History…", role: .destructive, action: onClearHistory)
            } header: {
                Text("History")
            } footer: {
                Text("Clipbot keeps your last 100 clips, encrypted with a key held by this Mac's Secure Enclave. Nothing ever leaves this Mac: no sync, no analytics, no network access.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            axTrusted = Permissions.accessibilityTrusted
            pbAccess = Permissions.pasteboardAccess
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func permissionRow(_ title: String, ok: Bool, detail: String? = nil, action: @escaping () -> Void) -> some View {
        LabeledContent {
            if ok {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open Settings", action: action)
            }
        } label: {
            Text(title)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        prefs.ignoredBundleIDs = Array(Set(prefs.ignoredBundleIDs).union(ids)).sorted()
    }
}
