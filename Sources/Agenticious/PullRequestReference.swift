import Foundation

struct PullRequestReference: Codable, Hashable, Identifiable {
    let url: URL
    var id: String { url.absoluteString }
    var label: String {
        let parts = url.pathComponents
        return "\(parts[1])/\(parts[2]) #\(parts[4])"
    }

    init?(_ value: String) {
        guard let input = URLComponents(string: value), input.scheme?.lowercased() == "https",
              let host = input.host, !host.isEmpty, input.user == nil, input.password == nil,
              let path = input.url?.pathComponents, path.count >= 5,
              path[3] == "pull", let number = Int(path[4]), number > 0 else { return nil }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = host.lowercased()
        canonical.port = input.port
        canonical.path = "/\(path[1])/\(path[2])/pull/\(number)"
        guard let url = canonical.url else { return nil }
        self.url = url
    }

    static func extract(from text: String) -> [Self] {
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s<>\"\]\)]+"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Self(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!")))
        }
    }
}
