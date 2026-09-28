import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Whether Flatlink opens at login, so that watching carries on after a restart. Listed in System
/// Settings › General › Login Items, where it can be switched off too.
@MainActor @Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    /// On, or on as soon as it is allowed in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    /// There is no notification when it is changed in System Settings, so this is asked again whenever
    /// the app comes to the front.
    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether this launch was the login item's. Only answers truly in `applicationDidFinishLaunching`,
    /// while the event that opened the app is still the current one.
    static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

struct SettingsView: View {
    @Bindable var loginItem: LoginItem

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open Flatlink at login")
                        Text("Starts with its window closed, so the folders set to update automatically are watched again after a restart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if loginItem.needsApproval {
                    LabeledContent("Allow Flatlink in System Settings to finish.") {
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                    .font(.callout)
                }
                if let error = loginItem.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
    }
}
