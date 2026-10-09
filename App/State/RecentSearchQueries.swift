import Foundation

struct SearchQuerySuggestion: Identifiable, Equatable, Sendable {
    let label: String
    let query: String

    // Exact UTF-8 identity: no case folding, translation or Unicode rewriting.
    var id: Data { Data(query.utf8) }
}

/// History is newest-first. Three is a presentation/product requirement, not a
/// text-length limit; labels and stored queries retain the complete user text.
enum RecentSearchQueries {
    static let count = 3
    static let defaults: [SearchQuerySuggestion] = [
        SearchQuerySuggestion(label: "身份证", query: "身份证"),
        SearchQuerySuggestion(label: "猫猫追逐逗猫棒", query: "猫猫追逐逗猫棒"),
        SearchQuerySuggestion(label: "海边日落", query: "海边的日落")
    ]

    static func normalized(_ queries: [String]) -> [String] {
        var seen = Set<Data>()
        var result: [String] = []
        for value in queries {
            let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, seen.insert(Data(query.utf8)).inserted else { continue }
            result.append(query)
            if result.count == count { break }
        }
        return result
    }

    static func recording(_ query: String, in history: [String]) -> [String] {
        normalized([query] + history)
    }

    static func suggestions(for history: [String]) -> [SearchQuerySuggestion] {
        let recent = normalized(history)
        let identities = Set(recent.map { Data($0.utf8) })
        let actual = recent.map { SearchQuerySuggestion(label: $0, query: $0) }
        // Fill the remaining slots in the original default order, skipping any
        // default whose actual query is already in history (not just its label).
        return Array((actual + defaults.filter { !identities.contains($0.id) }).prefix(count))
    }
}