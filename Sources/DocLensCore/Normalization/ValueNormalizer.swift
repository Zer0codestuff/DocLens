import Foundation

public struct Transformation: Codable, Hashable, Sendable {
    public var operation: String
    public var input: String
    public var output: String
    public var detail: String

    public init(operation: String, input: String, output: String, detail: String = "") {
        self.operation = operation
        self.input = input
        self.output = output
        self.detail = detail
    }
}

public enum ValueKind: String, Codable, Sendable {
    /// No text in the cell.
    case empty
    /// The cell contains a declared missing-value marker such as "-" or "..".
    case missing
    case value
    /// The text could be read under more than one convention.
    case ambiguous
    /// The text cannot be converted to the column type.
    case invalid
}

public struct NormalizedValue: Codable, Hashable, Sendable {
    public var kind: ValueKind
    /// Machine value: canonical decimal ("-1234.50"), ISO date, or text.
    public var canonical: String?
    public var fractionDigits: Int?
    public var transformations: [Transformation]
    public var candidates: [String]
    public var problem: String?
    public var missingToken: String?
    public var hadLeadingZeros: Bool

    public init(kind: ValueKind, canonical: String? = nil, fractionDigits: Int? = nil,
                transformations: [Transformation] = [], candidates: [String] = [], problem: String? = nil,
                missingToken: String? = nil, hadLeadingZeros: Bool = false) {
        self.kind = kind
        self.canonical = canonical
        self.fractionDigits = fractionDigits
        self.transformations = transformations
        self.candidates = candidates
        self.problem = problem
        self.missingToken = missingToken
        self.hadLeadingZeros = hadLeadingZeros
    }

    public static let empty = NormalizedValue(kind: .empty)
}

/// How a column's decimal convention was decided. Shown to the user next to the value.
public enum FormatResolution: String, Codable, Sendable {
    case columnSetting
    case tableSetting
    case columnEvidence
    case tableEvidence
    case unresolved
    case notApplicable

    public var label: String {
        switch self {
        case .columnSetting: "Column setting"
        case .tableSetting: "Table setting"
        case .columnEvidence: "Detected from this column"
        case .tableEvidence: "Detected from other columns"
        case .unresolved: "Not determined"
        case .notApplicable: "Not applicable"
        }
    }
}

public struct ColumnContext: Sendable, Hashable {
    public var decimal: Character?
    public var grouping: Set<Character>
    public var resolution: FormatResolution
    public var dateOrder: DateOrder
    public var dateResolution: FormatResolution

    public init(decimal: Character?, grouping: Set<Character>, resolution: FormatResolution,
                dateOrder: DateOrder, dateResolution: FormatResolution) {
        self.decimal = decimal
        self.grouping = grouping
        self.resolution = resolution
        self.dateOrder = dateOrder
        self.dateResolution = dateResolution
    }
}

public enum ValueNormalizer {
    static let footnotePattern = try! NSRegularExpression(
        pattern: #"(?:\s*(?:[*†‡§¹²³⁴⁵⁶⁷⁸⁹⁰]+|\((?:[a-zA-Z]|\d{1,2})\)))+$"#)

    /// Splits a trailing footnote marker from `text`.
    public static func splitFootnote(_ text: String) -> (value: String, marker: String?) {
        let ns = text as NSString
        guard let m = footnotePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range.location > 0 else { return (text, nil) }
        let value = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return (text, nil) }
        let marker = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
        return (value, marker)
    }

    public static func isMissingMarker(_ text: String, tokens: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return tokens.contains(t)
    }

    /// Resolves the decimal convention and date order for each column.
    public static func contexts(columns: [ColumnSpec], settings: TableSettings,
                                valuesByColumn: [[String]]) -> [ColumnContext] {
        var evidence: [Character?] = []
        var tableCounts: [Character: Int] = [:]
        for (i, column) in columns.enumerated() {
            let values = i < valuesByColumn.count ? valuesByColumn[i] : []
            let e = column.type.isNumeric ? decimalEvidence(values, settings: settings) : nil
            evidence.append(e.map(\.decimal))
            if let e { tableCounts[e.decimal, default: 0] += e.weight }
        }
        let tableDecimal: Character? = {
            let point = tableCounts[".", default: 0], comma = tableCounts[",", default: 0]
            if point > 0 && comma == 0 { return "." }
            if comma > 0 && point == 0 { return "," }
            if point >= comma * 4 && point > 0 { return "." }
            if comma >= point * 4 && comma > 0 { return "," }
            return nil
        }()

        return columns.enumerated().map { i, column in
            let values = i < valuesByColumn.count ? valuesByColumn[i] : []
            let (order, orderResolution) = resolveDateOrder(column: column, settings: settings, values: values)
            guard column.type.isNumeric else {
                return ColumnContext(decimal: nil, grouping: [], resolution: .notApplicable,
                                     dateOrder: order, dateResolution: orderResolution)
            }
            if let f = column.numberFormat, let d = f.decimalSeparator {
                return ColumnContext(decimal: d, grouping: f.groupingSeparators, resolution: .columnSetting,
                                     dateOrder: order, dateResolution: orderResolution)
            }
            if let d = settings.numberFormat.decimalSeparator {
                return ColumnContext(decimal: d, grouping: settings.numberFormat.groupingSeparators,
                                     resolution: .tableSetting, dateOrder: order, dateResolution: orderResolution)
            }
            if let d = evidence[i] {
                return ColumnContext(decimal: d, grouping: NumberParsing.groupingSeparators(forDecimal: d),
                                     resolution: .columnEvidence, dateOrder: order, dateResolution: orderResolution)
            }
            if let d = tableDecimal {
                return ColumnContext(decimal: d, grouping: NumberParsing.groupingSeparators(forDecimal: d),
                                     resolution: .tableEvidence, dateOrder: order, dateResolution: orderResolution)
            }
            return ColumnContext(decimal: nil, grouping: [], resolution: .unresolved,
                                 dateOrder: order, dateResolution: orderResolution)
        }
    }

    /// Returns the decimal separator supported by unambiguous values in a column, if one dominates.
    static func decimalEvidence(_ values: [String], settings: TableSettings) -> (decimal: Character, weight: Int)? {
        var point = 0, comma = 0
        for raw in values {
            let text = settings.stripFootnoteMarkers ? splitFootnote(raw).value : raw
            if text.isEmpty || isMissingMarker(text, tokens: settings.missingTokens) { continue }
            let i = NumberParsing.interpretations(text)
            switch (i["."], i[","]) {
            case (.some(let a), .some(let b)) where a.canonical != b.canonical:
                continue
            case (.some, .none):
                point += 1
            case (.none, .some):
                comma += 1
            default:
                continue
            }
        }
        if point > 0 && comma == 0 { return (".", point) }
        if comma > 0 && point == 0 { return (",", comma) }
        if point >= comma * 4 && point > 0 { return (".", point - comma) }
        if comma >= point * 4 && comma > 0 { return (",", comma - point) }
        return nil
    }

    static func resolveDateOrder(column: ColumnSpec, settings: TableSettings, values: [String]) -> (DateOrder, FormatResolution) {
        guard column.type == .date else { return (settings.dateOrder, .notApplicable) }
        if settings.dateOrder != .auto { return (settings.dateOrder, .tableSetting) }
        var dmy = false, mdy = false
        for v in values {
            guard let parts = DateParsing.numericParts(v) else { continue }
            if parts.count == 3, parts[0].count <= 2, parts[1].count <= 2 {
                let a = Int(parts[0]) ?? 0, b = Int(parts[1]) ?? 0
                if a > 12 && b <= 12 { dmy = true }
                if b > 12 && a <= 12 { mdy = true }
            }
        }
        if dmy && !mdy { return (.dmy, .columnEvidence) }
        if mdy && !dmy { return (.mdy, .columnEvidence) }
        return (.auto, .unresolved)
    }

    public static func normalize(_ raw: String, column: ColumnSpec, context: ColumnContext,
                                 settings: TableSettings) -> NormalizedValue {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        var transformations: [Transformation] = []
        if text != raw {
            transformations.append(Transformation(operation: "trim", input: raw, output: text,
                                                  detail: "Removed surrounding whitespace"))
        }
        if column.type.usesMissingMarkers && isMissingMarker(text, tokens: settings.missingTokens) {
            return NormalizedValue(kind: .missing, transformations: transformations, missingToken: text)
        }

        switch column.type {
        case .text:
            return NormalizedValue(kind: .value, canonical: text, transformations: transformations)
        case .identifier:
            return NormalizedValue(kind: .value, canonical: text, transformations: transformations,
                                   hadLeadingZeros: text.count > 1 && text.hasPrefix("0"))
        case .date:
            return normalizeDate(text, context: context, transformations: transformations)
        case .integer, .decimal, .percent, .currency:
            return normalizeNumber(text, column: column, context: context, settings: settings,
                                   transformations: transformations)
        }
    }

    static func normalizeNumber(_ input: String, column: ColumnSpec, context: ColumnContext,
                                settings: TableSettings, transformations: [Transformation]) -> NormalizedValue {
        var transformations = transformations
        var text = input
        if settings.stripFootnoteMarkers {
            let (value, marker) = splitFootnote(text)
            if let marker {
                transformations.append(Transformation(operation: "footnote", input: text, output: value,
                                                      detail: "Separated footnote marker \(marker)"))
                text = value
            }
            if isMissingMarker(text, tokens: settings.missingTokens) {
                return NormalizedValue(kind: .missing, transformations: transformations, missingToken: text)
            }
        }

        let parsed: ParsedNumber
        if let decimal = context.decimal {
            switch NumberParsing.parse(text, decimal: decimal, grouping: context.grouping) {
            case .success(let p):
                parsed = p
            case .failure(let error):
                let alternative = NumberParsing.interpretations(text)
                var problem = "“\(text)” \(error.description)"
                if !alternative.isEmpty, context.resolution != .columnSetting, context.resolution != .tableSetting {
                    problem += ". It would parse with a different decimal separator"
                }
                return NormalizedValue(kind: .invalid, transformations: transformations, problem: problem)
            }
        } else {
            let i = NumberParsing.interpretations(text)
            switch (i["."], i[","]) {
            case (.some(let a), .some(let b)) where a.canonical != b.canonical:
                return NormalizedValue(kind: .ambiguous, transformations: transformations,
                                       candidates: [a.canonical, b.canonical],
                                       problem: "“\(text)” reads as \(a.canonical) with a decimal point or \(b.canonical) with a decimal comma")
            case (.some(let a), _):
                parsed = a
            case (.none, .some(let b)):
                parsed = b
            default:
                return NormalizedValue(kind: .invalid, transformations: transformations,
                                       problem: "“\(text)” is not a number")
            }
        }

        if parsed.canonical != text {
            var detail = "Parsed number"
            if let d = context.decimal { detail += " with decimal separator “\(d)”" }
            if parsed.negativeByParentheses { detail += ", parentheses as negative sign" }
            if let c = parsed.currencySymbol { detail += ", removed currency \(c)" }
            if parsed.isPercent { detail += ", removed percent sign" }
            if parsed.hadLeadingZeros { detail += ", removed leading zeros" }
            transformations.append(Transformation(operation: "parseNumber", input: text, output: parsed.canonical, detail: detail))
        }

        var canonical = parsed.canonical
        var fraction = parsed.fractionDigits
        if column.type == .integer && parsed.fractionDigits > 0 {
            let fractionDigits = canonical.split(separator: ".").last ?? ""
            if fractionDigits.allSatisfy({ $0 == "0" }) {
                canonical = String(canonical.split(separator: ".").first ?? "0")
                fraction = 0
            } else {
                return NormalizedValue(kind: .invalid, canonical: canonical, fractionDigits: fraction,
                                       transformations: transformations,
                                       problem: "“\(text)” has a fractional part in an integer column",
                                       hadLeadingZeros: parsed.hadLeadingZeros)
            }
        }
        if column.scale != "1", !column.scale.isEmpty {
            guard let scaled = NumberParsing.scale(canonical, by: column.scale) else {
                return NormalizedValue(kind: .invalid, transformations: transformations,
                                       problem: "Scale “\(column.scale)” is not a decimal number")
            }
            transformations.append(Transformation(operation: "scale", input: canonical, output: scaled,
                                                  detail: "Multiplied by \(column.scale)"))
            canonical = scaled
            fraction = scaled.split(separator: ".").count > 1 ? scaled.split(separator: ".")[1].count : 0
        }
        return NormalizedValue(kind: .value, canonical: canonical, fractionDigits: fraction,
                               transformations: transformations, hadLeadingZeros: parsed.hadLeadingZeros)
    }

    static func normalizeDate(_ text: String, context: ColumnContext, transformations: [Transformation]) -> NormalizedValue {
        var transformations = transformations
        switch DateParsing.parse(text, order: context.dateOrder) {
        case .value(let iso):
            if iso != text {
                transformations.append(Transformation(operation: "parseDate", input: text, output: iso,
                                                      detail: "Date order \(context.dateOrder.rawValue.uppercased())"))
            }
            return NormalizedValue(kind: .value, canonical: iso, transformations: transformations)
        case .ambiguous(let candidates):
            return NormalizedValue(kind: .ambiguous, transformations: transformations, candidates: candidates,
                                   problem: "“\(text)” could be \(candidates.joined(separator: " or "))")
        case .invalid:
            return NormalizedValue(kind: .invalid, transformations: transformations,
                                   problem: "“\(text)” is not a recognized date")
        }
    }
}

public enum DateParsing {
    public enum Outcome: Equatable {
        case value(String)
        case ambiguous([String])
        case invalid
    }

    static let monthNames: [String: Int] = {
        let names: [[String]] = [
            ["jan", "gen", "janv", "ene", "jän"], ["feb", "fev", "fév", "febr"], ["mar", "mär", "mars"],
            ["apr", "avr", "abr"], ["may", "mag", "mai"], ["jun", "giu", "juin"], ["jul", "lug", "juil"],
            ["aug", "ago", "aoû", "aou"], ["sep", "set", "sept"], ["oct", "ott", "okt"], ["nov"], ["dec", "dic", "déc", "dez"],
        ]
        var map: [String: Int] = [:]
        for (i, list) in names.enumerated() { for n in list { map[n] = i + 1 } }
        return map
    }()

    static func numericParts(_ text: String) -> [String]? {
        let parts = text.split(whereSeparator: { "/.-".contains($0) }).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        return parts
    }

    static func iso(_ y: Int, _ m: Int, _ d: Int?) -> String? {
        guard (1...12).contains(m), (1000...2999).contains(y) else { return nil }
        guard let d else { return String(format: "%04d-%02d", y, m) }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        let cal = Calendar(identifier: .gregorian)
        guard (1...31).contains(d), let date = cal.date(from: comps),
              cal.component(.day, from: date) == d else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func parse(_ text: String, order: DateOrder) -> Outcome {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.count == 4, let y = Int(t), (1000...2999).contains(y) { return .value(t) }

        if let parts = numericParts(t) {
            if parts.count == 3 {
                let n = parts.compactMap { Int($0) }
                if parts[0].count == 4 {
                    return iso(n[0], n[1], n[2]).map(Outcome.value) ?? .invalid
                }
                guard parts[2].count == 4 else { return .invalid }
                let dmy = iso(n[2], n[1], n[0])
                let mdy = iso(n[2], n[0], n[1])
                switch order {
                case .dmy: return dmy.map(Outcome.value) ?? .invalid
                case .mdy: return mdy.map(Outcome.value) ?? .invalid
                case .ymd: return .invalid
                case .auto:
                    switch (dmy, mdy) {
                    case let (a?, b?) where a != b: return .ambiguous([a, b])
                    case let (a?, _): return .value(a)
                    case let (nil, b?): return .value(b)
                    default: return .invalid
                    }
                }
            }
            if parts.count == 2 {
                let n = parts.compactMap { Int($0) }
                if parts[1].count == 4 { return iso(n[1], n[0], nil).map(Outcome.value) ?? .invalid }
                if parts[0].count == 4 { return iso(n[0], n[1], nil).map(Outcome.value) ?? .invalid }
            }
            return .invalid
        }

        // Month name forms: "Jan 2024", "12 March 2024", "March 12, 2024".
        let words = t.lowercased().replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" }).map(String.init)
        var year: Int?, month: Int?, day: Int?
        for w in words {
            if let v = Int(w) {
                if w.count == 4 { year = v } else if v <= 31 { day = v }
            } else if month == nil {
                let key3 = String(w.prefix(3))
                month = monthNames[w] ?? monthNames[String(w.prefix(4))] ?? monthNames[key3]
            }
        }
        if let year, let month { return iso(year, month, day).map(Outcome.value) ?? .invalid }
        return .invalid
    }
}
