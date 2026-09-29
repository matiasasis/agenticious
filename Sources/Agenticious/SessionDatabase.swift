import Foundation

/// Keeps every agent (its task, status, plan and the CLI conversation to resume) in SQLite, so quitting the app
/// doesn't lose the dashboard. Lives at ~/Library/Application Support/Agenticious/agenticious.sqlite.
@MainActor
struct SessionDatabase {
    private let database: Database

    init(url: URL? = nil) throws {
        let url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agenticious/agenticious.sqlite")
        database = try Database(url: url)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        if database.schemaVersion < 1 {
            try database.transaction {
                try database.execute("""
                    CREATE TABLE sessions (
                        id TEXT PRIMARY KEY,
                        task TEXT NOT NULL,
                        prompt TEXT NOT NULL,
                        agent TEXT NOT NULL,
                        project_path TEXT,
                        directory TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        last_activity REAL NOT NULL,
                        worktree_root TEXT,
                        worktree_path TEXT,
                        worktree_branch TEXT,
                        worktree_removed INTEGER NOT NULL DEFAULT 0,
                        model_id TEXT,
                        model_name TEXT,
                        effort TEXT,
                        status TEXT NOT NULL,
                        status_detail TEXT,
                        plan_source TEXT NOT NULL,
                        conversation_id TEXT
                    )
                    """)
                try database.execute("""
                    CREATE TABLE chunks (
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        id INTEGER NOT NULL,
                        title TEXT NOT NULL,
                        status TEXT NOT NULL,
                        note TEXT,
                        PRIMARY KEY (session_id, id)
                    )
                    """)
            }
            database.schemaVersion = 1
        }
        if database.schemaVersion < 2 {
            try database.execute("ALTER TABLE sessions ADD COLUMN pull_requests TEXT NOT NULL DEFAULT '[]'")
            database.schemaVersion = 2
        }
        if database.schemaVersion < 3 {
            try database.execute("ALTER TABLE sessions ADD COLUMN is_marked_finished INTEGER NOT NULL DEFAULT 0")
            database.schemaVersion = 3
        }
        if database.schemaVersion < 4 {
            try database.execute("ALTER TABLE sessions ADD COLUMN task_type TEXT")
            database.schemaVersion = 4
        }
    }

    // MARK: - Writing

    func save(_ session: AgentSession) throws {
        let (status, detail) = Self.encode(session.status)

        try database.transaction {
            try database.execute(
                """
                INSERT OR REPLACE INTO sessions (
                    id, task, prompt, agent, project_path, directory, started_at, last_activity,
                    worktree_root, worktree_path, worktree_branch, worktree_removed,
                    model_id, model_name, effort, status, status_detail, plan_source, conversation_id, pull_requests, is_marked_finished, task_type
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                session.id.uuidString, session.task, session.prompt, session.agent.rawValue, session.project.path,
                session.directory.path, session.startedAt.timeIntervalSince1970, session.lastActivity.timeIntervalSince1970,
                session.worktree?.repositoryRoot, session.worktree?.path, session.worktree?.branch, session.worktreeRemoved,
                session.model?.id, session.model?.name, session.effort, status, detail,
                Self.encode(session.planSource), session.conversationID,
                String(decoding: try JSONEncoder().encode(session.pullRequests.map { $0.url.absoluteString }), as: UTF8.self),
                session.isMarkedFinished,
                try session.taskType.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            )
            try database.execute("DELETE FROM chunks WHERE session_id = ?", session.id.uuidString)
            for chunk in session.chunks {
                try database.execute(
                    "INSERT INTO chunks (session_id, id, title, status, note) VALUES (?, ?, ?, ?, ?)",
                    session.id.uuidString, chunk.id, chunk.title, chunk.status.rawValue, chunk.note
                )
            }
        }
    }

    func delete(_ id: UUID) throws {
        try database.execute("DELETE FROM sessions WHERE id = ?", id.uuidString)
    }

    // MARK: - Reading

    /// Newest first. Nothing is running yet, so agents that were mid-task come back as interrupted.
    func load() throws -> [AgentSession] {
        let chunks = Dictionary(grouping: try database.query("SELECT * FROM chunks ORDER BY session_id, id")) {
            $0.string("session_id") ?? ""
        }

        return try database.query("SELECT * FROM sessions ORDER BY started_at DESC").compactMap { row in
            guard let id = row.string("id").flatMap(UUID.init(uuidString:)),
                  let agent = row.string("agent").flatMap(AgentKind.init(rawValue:)),
                  let directory = row.string("directory") else { return nil }

            let session = AgentSession(
                id: id,
                task: row.string("task") ?? "",
                prompt: row.string("prompt"),
                agent: agent,
                project: Project(path: row.string("project_path")),
                directory: URL(fileURLWithPath: directory),
                startedAt: Date(timeIntervalSince1970: row.double("started_at") ?? 0),
                worktree: Self.worktree(row),
                model: Self.model(row, agent: agent),
                effort: row.string("effort"),
                taskType: row.string("task_type")?.data(using: .utf8).flatMap { try? JSONDecoder().decode(TaskType.self, from: $0) }
            )
            let status = Self.decode(row.string("status"), detail: row.string("status_detail"))
            session.status = status.isFinished ? status : .interrupted
            session.isMarkedFinished = row.bool("is_marked_finished")
            session.lastActivity = Date(timeIntervalSince1970: row.double("last_activity") ?? 0)
            session.worktreeRemoved = row.bool("worktree_removed")
            session.planSource = Self.decodePlanSource(row.string("plan_source"))
            session.conversationID = row.string("conversation_id")
            if let data = row.string("pull_requests")?.data(using: .utf8),
               let urls = try? JSONDecoder().decode([String].self, from: data) {
                session.recordPullRequests(in: urls.joined(separator: "\n"))
            }
            session.chunks = (chunks[id.uuidString] ?? []).compactMap { chunk in
                guard let number = chunk.int("id") else { return nil }
                return Chunk(
                    id: number,
                    title: chunk.string("title") ?? "",
                    status: chunk.string("status").flatMap(ChunkStatus.init(rawValue:)) ?? .pending,
                    note: chunk.string("note")
                )
            }
            for chunk in session.chunks { session.recordPullRequests(in: chunk.note ?? "") }
            if case let .done(summary) = session.status { session.recordPullRequests(in: summary ?? "") }
            if case let .ended(reason) = session.status { session.recordPullRequests(in: reason) }
            return session
        }
    }

    private static func worktree(_ row: Database.Row) -> Worktree? {
        guard let root = row.string("worktree_root"), let path = row.string("worktree_path"),
              let branch = row.string("worktree_branch") else { return nil }
        return Worktree(repositoryRoot: root, path: path, branch: branch)
    }

    /// Prefer the catalog's entry so the effort list is current; fall back to what was stored.
    private static func model(_ row: Database.Row, agent: AgentKind) -> ModelChoice? {
        guard let id = row.string("model_id") else { return nil }
        return ModelCatalog.models(for: agent).first { $0.id == id }
            ?? ModelChoice(id: id, name: row.string("model_name") ?? id, efforts: [], defaultEffort: nil)
    }

    // MARK: - Encoding

    private static func encode(_ status: SessionStatus) -> (String, String?) {
        switch status {
        case .starting: ("starting", nil)
        case .working: ("working", nil)
        case .waiting: ("waiting", nil)
        case let .needsYou(reason): ("needs_you", reason)
        case .yourTurn: ("your_turn", nil)
        case let .done(summary): ("done", summary)
        case let .ended(reason): ("ended", reason)
        case let .exited(code): ("exited", code.map(String.init))
        case .interrupted: ("interrupted", nil)
        }
    }

    private static func decode(_ status: String?, detail: String?) -> SessionStatus {
        switch status {
        case "done": .done(detail)
        case "ended": .ended(detail ?? "Work was stopped.")
        case "exited": .exited(detail.flatMap { Int32($0) })
        case "needs_you": .needsYou(detail ?? "")
        case "your_turn": .yourTurn
        case "working": .working
        case "waiting": .waiting
        case "starting": .starting
        default: .interrupted
        }
    }

    private static func encode(_ source: PlanSource) -> String {
        switch source {
        case .none: "none"
        case .todoList: "todo_list"
        case .agent: "agent"
        }
    }

    private static func decodePlanSource(_ raw: String?) -> PlanSource {
        switch raw {
        case "todo_list": .todoList
        case "agent": .agent
        default: .none
        }
    }
}
