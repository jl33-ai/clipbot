import AppKit
import ClipbotCore
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var hotKeys = HotKeys.shared
    let onClearHistory: () -> Void
    let onEditSnippets: () -> Void
    let onRecording: (Bool) -> Void

    @State private var loginStatus = SMAppService.mainApp.status
    @State private var secureInput = SecureInput.isOn
    @State private var axTrusted = Permissions.accessibilityTrusted
    @State private var pbAccess = Permissions.pasteboardAccess
    @State private var selectedIgnored: String?
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Shortcuts") {
                ForEach(ShortcutSlot.allCases) { slot in shortcutRow(slot) }
            }

            Section("General") {
                LabeledContent("Snippets") { Button("Edit Snippets…", action: onEditSnippets) }
                Toggle("Show icon in menu bar", isOn: $prefs.showMenuBarIcon)
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {}
                        if on { prefs.loginItemPath = Bundle.main.bundlePath }
                        loginStatus = SMAppService.mainApp.status
                    }))
                if loginStatus == .requiresApproval {
                    Text("Approve Dclip in System Settings → General → Login Items.").foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                permissionRow("Accessibility (to paste for you)", ok: axTrusted, action: Permissions.openAccessibilitySettings)
                permissionRow("Clipboard access", ok: pbAccess == .allowed,
                              detail: pbAccess == .ask ? "macOS will ask each time" : nil,
                              action: Permissions.openPrivacySettings)
                if secureInput {
                    Label("Secure keyboard input is on — copies aren't recorded until it's off.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
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
                Text("Copies that password managers mark as passwords (1Password, Apple Passwords and others that follow the standard) are always skipped. Copies made in the apps above are skipped, and so is anything copied while a password field has focus.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear History…", role: .destructive, action: onClearHistory)
            } header: {
                Text("History")
            } footer: {
                Text("Dclip keeps your last 100 clips, encrypted with a key held by this Mac's Secure Enclave. Nothing ever leaves this Mac: no sync, no analytics, no network access.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            axTrusted = Permissions.accessibilityTrusted
            pbAccess = Permissions.pasteboardAccess
            loginStatus = SMAppService.mainApp.status
            secureInput = SecureInput.isOn
        }
    }

    private func shortcutRow(_ slot: ShortcutSlot) -> some View {
        LabeledContent {
            ShortcutRecorder(shortcut: Binding(get: { prefs.shortcuts[slot] ?? slot.defaultValue },
                                               set: { prefs.shortcuts[slot] = $0 }),
                             defaultValue: slot.defaultValue, onRecording: onRecording)
        } label: {
            Text(slot.title)
            if hotKeys.failed.contains(slot.id) {
                Text("Already in use by another app or shortcut").foregroundStyle(.red)
            }
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
