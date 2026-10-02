import SwiftUI
import AppKit

struct TaskSettingsView: View {
    @EnvironmentObject private var presets: TaskPresetStore
    @State private var editing: TaskTemplate?
    @State private var deleting: TaskTemplate?
    @State private var dropTarget: String?
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
                orderPicker
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(Array(presets.presets.enumerated()), id: \.element.id) { index, preset in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: preset.symbol)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .background(AgenticiousStyle.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                Text(preset.name).font(.title3.bold())
                                Spacer(minLength: 0)
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                    .help("Drag to reorder")
                            }
                            .foregroundStyle(AgenticiousStyle.lime)
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
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AgenticiousStyle.lime, lineWidth: 2).opacity(dropTarget == preset.id ? 1 : 0))
                        .draggable(preset.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, id != preset.id else { return false }
                            move(id, to: index)
                            return true
                        } isTargeted: { dropTarget = $0 ? preset.id : (dropTarget == preset.id ? nil : dropTarget) }
                        .accessibilityAction(named: "Move earlier") { move(preset.id, to: index - 1) }
                        .accessibilityAction(named: "Move later") { move(preset.id, to: index + 1) }
                    }
                }
                Text("Saved on this Mac for your user account. Changes apply to new tasks; running agents keep their original prompts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .sheet(item: $editing) { preset in
            PresetEditorSheet(preset: preset, isNew: !presets.presets.contains { $0.id == preset.id })
        }
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

    private var orderPicker: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Order in the Summon sheet").font(.headline)
                Text(presets.order == .arranged ? "Drag the cards below to arrange them."
                     : "The custom task first, then the presets you start most.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Order in the Summon sheet", selection: $presets.order) {
                ForEach(TaskPresetOrder.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
        }
        .padding(20)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func move(_ id: String, to index: Int) {
        do { try presets.move(id: id, to: index) }
        catch { self.error = error.localizedDescription }
    }
}

private struct PresetEditorSheet: View {
    @EnvironmentObject private var presets: TaskPresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskTemplate
    @State private var project = Project.none
    @State private var error: String?
    @State private var choosingIcon = false
    private let isNew: Bool

    /// Stands in for what gets typed when summoning, in the title and prompt previews.
    private static let exampleInput = "‹input›"

    init(preset: TaskTemplate, isNew: Bool) {
        _draft = State(initialValue: preset)
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identity
                    summonForm
                    promptSection
                    skills
                    preview
                }
                .padding(24)
            }
            footer
        }
        .frame(width: min(900, (NSScreen.main?.visibleFrame.width ?? 980) - 80),
               height: min(820, (NSScreen.main?.visibleFrame.height ?? 920) - 100))
        .background(AgenticiousStyle.ink)
        .tint(AgenticiousStyle.lime)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: draft.symbol)
                .font(.system(size: 24))
                .foregroundStyle(AgenticiousStyle.lime)
                .frame(width: 44, height: 44)
                .background(AgenticiousStyle.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(isNew ? "Shape a task preset" : "Edit preset")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Icon, form, prompt and skills. All yours.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(AgenticiousStyle.panel)
    }

    private var identity: some View {
        card("Identity", symbol: "person.crop.square") {
            HStack(alignment: .top, spacing: 16) {
                Button { choosingIcon.toggle() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: draft.symbol).font(.system(size: 30))
                            .foregroundStyle(AgenticiousStyle.lime)
                            .frame(width: 76, height: 76)
                            .background(AgenticiousStyle.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AgenticiousStyle.lime.opacity(0.5)))
                        Text("Change").font(.caption.weight(.semibold)).foregroundStyle(AgenticiousStyle.violet)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Icon")
                .accessibilityValue(draft.symbol)
                .popover(isPresented: $choosingIcon) {
                    PresetIconPicker(symbol: $draft.symbol) { choosingIcon = false }
                }
                VStack(alignment: .leading, spacing: 12) {
                    field("NAME") { TextField("Preset name", text: $draft.name).font(.title3.weight(.semibold)) }
                    field("DESCRIPTION") { TextField("What does this task do?", text: $draft.summary) }
                }
            }
        }
    }

    private var summonForm: some View {
        card("Summon form", symbol: "rectangle.and.pencil.and.ellipsis",
             caption: draft.isCustom ? "The custom task always asks for the mission in your own words."
                                     : "What the Summon sheet asks for when you pick this preset.") {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    if !draft.isCustom {
                        field("FIELD LABEL") { TextField("Task input", text: $draft.fieldLabel) }
                        field("HINT") { TextField("Shown inside the empty field", text: $draft.fieldPlaceholder) }
                        Toggle(isOn: $draft.isFieldRequired) {
                            HStack(spacing: 10) {
                                Image(systemName: "asterisk").foregroundStyle(AgenticiousStyle.violet)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Required to start").font(.callout.weight(.semibold))
                                    Text("Turn off for optional input, like a branch that defaults to the current one.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)
                        .padding(12)
                        .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
                    }
                    field("CARD TITLE", caption: "{{input}} becomes what you typed. Shows as “\(draft.title(for: Self.exampleInput))”.") {
                        TextField("{{input}}", text: $draft.titlePattern).font(.body.monospaced())
                    }
                }
                if !draft.isCustom { formPreview.frame(width: 280) }
            }
        }
    }

    /// A miniature of the Summon sheet's field, so label and hint read in context.
    private var formPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            Text(draft.fieldLabel.isEmpty ? "Task input" : draft.fieldLabel).font(.headline)
            Text(draft.fieldPlaceholder.isEmpty ? " " : draft.fieldPlaceholder)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgenticiousStyle.violet.opacity(0.3)))
            Text(draft.isFieldRequired ? "Required" : "Optional").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var promptSection: some View {
        card("Prompt", symbol: "text.alignleft",
             caption: "Notes and selected skills are added automatically." +
                (draft.prompt.contains("{{input}}") ? "" : " Without {{input}}, what you type is added after the prompt.")) {
            VStack(alignment: .trailing, spacing: 10) {
                TextEditor(text: $draft.prompt)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 220)
                    .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgenticiousStyle.violet.opacity(0.3)))
                    .accessibilityLabel("Preset prompt")
                Button("Add {{input}}", systemImage: "plus") { draft.prompt += draft.prompt.hasSuffix("\n") || draft.prompt.isEmpty ? "{{input}}" : "\n{{input}}" }
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                    .disabled(draft.prompt.contains("{{input}}"))
            }
        }
    }

    private var skills: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("BROWSE SKILLS FROM").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                SkillProjectPicker(project: $project)
            }
            SkillSelectionField(paths: $draft.skillPaths, project: project)
        }
        .padding(18)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private var preview: some View {
        DisclosureGroup {
            Text(draft.instructions(for: Self.exampleInput))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 10)
        } label: {
            Label("Preview the full prompt", systemImage: "eye").font(.headline).foregroundStyle(AgenticiousStyle.violet)
        }
        .padding(18)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = error ?? draft.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            } else {
                Text("⌘ Return to save").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(AgenticiousButtonStyle(isPrimary: false))
            Button("Save preset", systemImage: "checkmark") {
                do { try presets.save(draft); dismiss() }
                catch { self.error = error.localizedDescription }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(AgenticiousButtonStyle())
            .disabled(draft.validationMessage != nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(AgenticiousStyle.panel)
        .overlay(alignment: .top) { Rectangle().fill(AgenticiousStyle.violet.opacity(0.2)).frame(height: 1) }
    }

    private func card(_ title: String, symbol: String, caption: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(AgenticiousStyle.violet)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func field(_ label: String, caption: String? = nil, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            input()
                .textFieldStyle(.plain)
                .padding(10)
                .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgenticiousStyle.violet.opacity(0.3)))
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
