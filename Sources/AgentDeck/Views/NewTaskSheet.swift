import AppKit
import SwiftUI

struct NewTaskSheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @AppStorage("lastDirectory") private var directoryPath = FileManager.default.homeDirectoryForCurrentUser.path
    @AppStorage("lastAgent") private var agent: AgentKind = .claude
    @State private var task = ""
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New agent").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Task").font(.headline)
                TextEditor(text: $task)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("This becomes the big title on the agent's card. The agent is told to split it into chunks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Agent", selection: $agent) {
                ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Label(directoryPath, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Choose…", action: chooseDirectory)
            }

            if let launchError {
                Text(launchError).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: directoryPath)
        if panel.runModal() == .OK, let url = panel.url { directoryPath = url.path }
    }

    private func start() {
        do {
            let session = try store.launch(
                task: task.trimmingCharacters(in: .whitespacesAndNewlines),
                agent: agent,
                directory: URL(fileURLWithPath: directoryPath)
            )
            dismiss()
            openWindow(value: session.id)
        } catch {
            launchError = error.localizedDescription
        }
    }
}
