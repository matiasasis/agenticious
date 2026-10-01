import Foundation

/// One question from Claude's AskUserQuestion tool: a short header, the question, and its options.
struct AgentQuestion: Identifiable, Equatable {
    struct Option: Equatable, Hashable {
        let label: String
        let detail: String
    }

    var id: String { text }
    let header: String
    let text: String
    let options: [Option]
    let allowsMultiple: Bool

    static func parse(_ input: Any?) -> [AgentQuestion] {
        let questions = (input as? [String: Any])?["questions"] as? [[String: Any]] ?? []
        return questions.compactMap { question in
            guard let text = question["question"] as? String, !text.isEmpty else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option in
                (option["label"] as? String).map { Option(label: $0, detail: option["description"] as? String ?? "") }
            }
            return AgentQuestion(header: question["header"] as? String ?? "", text: text, options: options,
                                 allowsMultiple: question["multiSelect"] as? Bool ?? false)
        }
    }

    /// The answer Claude's own menu would give: the chosen labels, plus anything typed under Other.
    func answer(choosing labels: [String], other: String) -> String {
        let other = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return (options.map(\.label).filter(labels.contains) + (other.isEmpty ? [] : [other])).joined(separator: ", ")
    }
}

/// An AskUserQuestion call held open by its PreToolUse hook until the human answers in Agenticious,
/// or lets the terminal show Claude's own menu instead.
struct PendingQuestion {
    let toolUseID: String
    let questions: [AgentQuestion]
    let input: [String: Any]
    let respond: (Data?) -> Void

    /// Allows the call with the answers filled in, so Claude reads them without showing its menu.
    static func hookReply(input: [String: Any], answers: [String: String]) -> Data? {
        var updated = input
        updated["answers"] = answers
        let output: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Answered in Agenticious",
            "updatedInput": updated,
        ]]
        return try? JSONSerialization.data(withJSONObject: output)
    }
}
