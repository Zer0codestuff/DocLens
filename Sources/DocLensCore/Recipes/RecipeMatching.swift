import Foundation

public enum RecipeMatching {
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a)), y = Array(normalize(b))
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = previous[y.count]
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }

    public static func matches(header: String, aliases: [String], threshold: Double = 0.8) -> Bool {
        aliases.contains { similarity(header, $0) >= threshold }
    }

    /// Maps each extracted column to the best recipe column. Returns nil entries when no alias
    /// matches well enough; callers must surface those for inspection rather than guess.
    public static func mapColumns(headers: [String], recipe: Recipe, threshold: Double = 0.8) -> [Int?] {
        var used = Set<Int>()
        return headers.map { header in
            var best: (Int, Double)?
            for (i, column) in recipe.columns.enumerated() where !used.contains(i) {
                let score = (column.aliases + [column.name]).map { similarity(header, $0) }.max() ?? 0
                if score >= threshold, score > (best?.1 ?? 0) { best = (i, score) }
            }
            if let best { used.insert(best.0) }
            return best?.0
        }
    }
}
