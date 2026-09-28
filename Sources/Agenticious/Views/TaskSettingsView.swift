import SwiftUI
import AppKit

struct TaskSettingsView: View {
    @EnvironmentObject private var presets: TaskPresetStore
    @State private var editing: TaskTemplate?
    @State private var deleting: TaskTemplate?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your agents. Your rules.").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Configure the task presets shown when you summon an agent.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("New preset", systemImage: "plus") { editing = TaskTemplate(name: "New preset") }
                        .buttonStyle(AgenticiousButtonStyle())
                }
                if let loadError = presets.loadError {
                    Text(loadError).foregroundStyle(.orange)
                    Button("Show saved presets") { NSWorkspace.shared.activateFileViewerSelecting([presets.url]) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(presets.presets) { preset in
                        VStack(alignment: .leading, spacing: 14) {
                            Label(preset.name, systemImage: preset.symbol).font(.title3.bold()).foregroundStyle(AgenticiousStyle.lime)
                            Text(preset.summary.isEmpty ? "Your reusable agent prompt." : preset.summary)
                                .foregroundStyle(.secondary).lineLimit(3).frame(minHeight: 40, alignment: .topLeading)
                            Text("\(preset.skillPaths.count) attached skills").font(.caption).foregroundStyle(AgenticiousStyle.violet)
                            HStack {
                                Button("Edit preset", systemImage: "pencil") { editing = preset }
                                    .buttonStyle(AgenticiousButtonStyle(isCompact: true))
                                Spacer()
                                if !preset.isCustom {
                                    Button("Delete preset", systemImage: "trash", role: .destructive) { deleting = preset }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless).tint(.red)
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                Text("Saved on this Mac for your user account. Changes apply to new tasks; running agents keep their original prompts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .sheet(item: $editing) { PresetEditorSheet(preset: $0) }
        .confirmationDialog("Delete this preset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("Delete \(deleting.name)", role: .destructive) {
                    do { try presets.remove(deleting) }
                    catch { self.error = error.localizedDescription }
                    self.deleting = nil
                }
            }
        } message: { Text("Existing agent sessions will be kept.") }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} }
    }
}

private struct PresetEditorSheet: View {
    @EnvironmentObject private var presets: TaskPresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskTemplate
    @State private var project = Project.none
    @State private var error: String?

    init(preset: TaskTemplate) { _draft = State(initialValue: preset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Shape a task preset").font(.system(size: 26, weight: .bold, design: .rounded))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Name") { TextField("Preset name", text: $draft.name) }
                    LabeledContent("Description") { TextField("What does this task do?", text: $draft.summary) }
                    if !draft.isCustom {
                        LabeledContent("Input label") { TextField("Task input", text: $draft.fieldLabel) }
                        LabeledContent("Placeholder") { TextField("Input hint", text: $draft.fieldPlaceholder) }
                        Toggle("Require an input before starting", isOn: $draft.isFieldRequired)
                    }
                    LabeledContent("Task title") { TextField("{{input}}", text: $draft.titlePattern) }
                    Text("Prompt").font(.headline)
                    Text("Use {{input}} where the task text, ticket, or PR should go. Notes and selected skills are added automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.prompt)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10).frame(height: 190)
                        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Preset prompt")
                    SkillProjectPicker(project: $project)
                    SkillSelectionField(paths: $draft.skillPaths, project: project)
                    DisclosureGroup("Preview with example input") {
                        Text(draft.instructions(for: "Example task"))
                            .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let message = error ?? draft.validationMessage { Text(message).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(AgenticiousButtonStyle(isPrimary: false)).keyboardShortcut(.cancelAction)
                Button("Save preset") {
                    do { try presets.save(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(AgenticiousButtonStyle())
                .disabled(draft.validationMessage != nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 760, height: 690)
        .background(AgenticiousStyle.ink)
        .preferredColorScheme(.dark)
        .tint(AgenticiousStyle.lime)
    }
}
