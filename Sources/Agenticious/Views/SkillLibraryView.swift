import SwiftUI
import AppKit

struct SkillLibraryView: View {
    @EnvironmentObject private var locations: SkillLocations
    @StateObject private var catalog = SkillCatalog()
    @State private var project = Project.none
    @State private var query = ""
    @State private var selectedID: String?
    @State private var creating = false
    @State private var editing: InstalledSkill?
    @State private var refreshID = UUID()
    var selectedPaths: Binding<[String]>?

    init(project: Project = .none, selectedPaths: Binding<[String]>? = nil) {
        _project = State(initialValue: project)
        self.selectedPaths = selectedPaths
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skill library").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Find your agents' know-how. Make it your own.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                Button("New skill", systemImage: "plus") { creating = true }
                    .buttonStyle(AgenticiousButtonStyle(isCompact: true))
            }
            HStack {
                TextField("Search skills", text: $query).textFieldStyle(.roundedBorder)
                SkillProjectPicker(project: $project)
                    .frame(maxWidth: 320)
            }
            HStack(spacing: 12) {
                Text("Personal, project, and cached plugin skills · \(catalog.skills.count) found")
                    .font(.caption).foregroundStyle(.secondary)
                if catalog.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Menu("Search folders") {
                    Button("Add a folder…") {
                        if let url = FolderPicker.choose() { locations.add(url) }
                    }
                    ForEach(locations.paths, id: \.self) { path in
                        Button("Stop searching \(path)") { locations.remove(path) }
                    }
                }
                .fixedSize()
            }
            if !catalog.issues.isEmpty {
                DisclosureGroup("\(catalog.issues.count) folders or skills could not be read") {
                    ScrollView { Text(catalog.issues.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 80)
                }
                .foregroundStyle(.orange)
            }
            HSplitView {
                skillList.frame(minWidth: 220, idealWidth: 270, maxWidth: 340)
                detail.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .background(AgenticiousStyle.ink)
        .tint(AgenticiousStyle.lime)
        .preferredColorScheme(.dark)
        .task(id: "\(project.id)|\(locations.paths.joined(separator: "|"))|\(refreshID)") {
            await catalog.refresh(projectPath: project.path, extraPaths: locations.paths)
        }
        .sheet(isPresented: $creating) {
            SkillEditorSheet(project: project) { url in
                selectedID = url.resolvingSymlinksInPath().path
                refreshID = UUID()
            }
        }
        .sheet(item: $editing) { skill in
            SkillEditorSheet(project: project, skill: skill) { _ in refreshID = UUID() }
        }
    }

    private var matchingSkills: [InstalledSkill] {
        catalog.skills.filter { query.isEmpty || "\($0.name) \($0.summary) \($0.source)".localizedCaseInsensitiveContains(query) }
    }

    private var skillList: some View {
        List(selection: $selectedID) {
            ForEach(matchingSkills) { skill in
                HStack(alignment: .top, spacing: 8) {
                    if let selectedPaths {
                        Toggle("Use \(skill.name)", isOn: Binding(
                            get: { selectedPaths.wrappedValue.contains(skill.id) },
                            set: { selected in
                                selectedPaths.wrappedValue.removeAll { $0 == skill.id }
                                if selected { selectedPaths.wrappedValue.append(skill.id) }
                            }
                        ))
                        .labelsHidden().toggleStyle(.checkbox)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(skill.name).font(.headline).lineLimit(2)
                        Text(skill.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .tag(skill.id)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if matchingSkills.isEmpty && !catalog.isLoading {
                ContentUnavailableView("No skills found", systemImage: "sparkles", description: Text("Choose a project, add a search folder, or create a skill."))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let skill = catalog.skills.first(where: { $0.id == selectedID }) {
            SkillDetailView(skill: skill, edit: { editing = skill })
                .id("\(skill.id)|\(refreshID)")
        } else {
            ContentUnavailableView("Explore a skill", systemImage: "books.vertical", description: Text("Select a skill to read its instructions and see where it lives."))
        }
    }
}

private struct SkillDetailView: View {
    let skill: InstalledSkill
    let edit: () -> Void
    @State private var content = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(skill.name).font(.title2.bold()).textSelection(.enabled)
                Text(skill.summary).foregroundStyle(.secondary)
                Text(skill.url.path).font(.caption.monospaced()).foregroundStyle(AgenticiousStyle.violet).textSelection(.enabled)
                HStack {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([skill.url]) }
                        .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                    if skill.isEditable {
                        Button("Edit skill", systemImage: "pencil", action: edit)
                            .buttonStyle(AgenticiousButtonStyle(isCompact: true))
                    }
                }
                if !skill.isEditable { Text("Cached plugin skill. Availability and required tools depend on the agent's plugin setup.").font(.caption).foregroundStyle(.secondary) }
                Divider()
                Text(error ?? content).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .task {
            do { content = try SkillDocument.read(skill.url).text }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct SkillProjectPicker: View {
    @EnvironmentObject private var store: SessionStore
    @Binding var project: Project

    var body: some View {
        HStack {
            Picker("Project", selection: $project) {
                Text("Personal skills only").tag(Project.none)
                ForEach(choices) { Text($0.name).tag($0) }
            }
            Button("Choose project folder", systemImage: "folder.badge.plus") {
                if let url = FolderPicker.choose(startingAt: project.path) { project = Project(path: url.path) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private var choices: [Project] {
        var choices = store.favorites
        if project != .none && !choices.contains(project) { choices.append(project) }
        return choices
    }
}

struct SkillSelectionField: View {
    @Binding var paths: [String]
    let project: Project
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Skills", systemImage: "books.vertical").font(.headline)
                Spacer()
                Button("Choose skills", systemImage: "plus") { choosing = true }
                    .buttonStyle(AgenticiousButtonStyle(isCompact: true))
            }
            Text(paths.isEmpty ? "Optionally add installed skills to this task." : "The agent will be asked to read and apply these skills.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(paths, id: \.self) { path in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent).font(.callout.bold())
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Remove skill", systemImage: "xmark.circle") { paths.removeAll { $0 == path } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
        .sheet(isPresented: $choosing) {
            SkillPickerSheet(project: project, initialPaths: paths) { paths = $0 }
        }
    }
}

private struct SkillPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var paths: [String]
    let project: Project
    let apply: ([String]) -> Void

    init(project: Project, initialPaths: [String], apply: @escaping ([String]) -> Void) {
        self.project = project
        self.apply = apply
        _paths = State(initialValue: initialPaths)
    }

    var body: some View {
        VStack(spacing: 0) {
            SkillLibraryView(project: project, selectedPaths: $paths)
            HStack {
                Text("\(paths.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(AgenticiousButtonStyle(isPrimary: false)).keyboardShortcut(.cancelAction)
                Button("Use selected skills") { apply(paths); dismiss() }.buttonStyle(AgenticiousButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(20).background(AgenticiousStyle.panel)
        }
        .frame(width: 900, height: 650)
        .preferredColorScheme(.dark)
    }
}
