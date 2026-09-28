import SwiftUI
import UserNotifications

struct NotificationPreferencesView: View {
    @EnvironmentObject private var notifications: AgentNotifications
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("A little noise. At the right time.", systemImage: "bell.badge")
                .font(.headline).foregroundStyle(AgenticiousStyle.lime)
            Text("Get a heads-up when an agent needs input, completes a mission, or stops unexpectedly. Click a notification to open that agent.")
                .font(.callout).foregroundStyle(.secondary)
            if !notifications.available {
                Text("Launch with script/run to enable macOS notifications.")
                    .font(.callout).foregroundStyle(AgenticiousStyle.violet)
            } else if notifications.authorization == .denied {
                HStack {
                    Text("Notifications are disabled in macOS.").font(.callout)
                    Spacer()
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(AgenticiousButtonStyle(isCompact: true))
                }
            } else if notifications.authorization == .notDetermined {
                Button("Enable macOS notifications") {
                    Task { await notifications.enableNotifications() }
                }.buttonStyle(AgenticiousButtonStyle(isPrimary: true, isCompact: true))
            } else {
                Toggle("macOS notifications", isOn: $notifications.bannersEnabled)
            }
            Divider()
            Toggle("Play sounds", isOn: $notifications.soundsEnabled)
            Text("Distinct sounds for attention, success and errors. Soft feedback when starting an agent or marking it finished. Sounds also work with notifications turned off.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Preview sound") { notifications.playSound("Glass") }
                    .disabled(!notifications.soundsEnabled)
                if notifications.available && notifications.authorization == .authorized {
                    Button("Send test notification") { notifications.sendTest() }
                        .disabled(!notifications.bannersEnabled)
                }
            }.buttonStyle(AgenticiousButtonStyle(isCompact: true))
            if let error = notifications.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .toggleStyle(.switch).padding(20)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .task { await notifications.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refreshAuthorization() } }
        }
    }
}
