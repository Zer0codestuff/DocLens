import Foundation

/// Result of parsing a numeric string under one decimal convention.
public struct ParsedNumber: Hashable, Sendable {
    /// Canonical machine form: optional minus sign, digits, optional "." and fraction digits.
    public var canonical: String
    public var fractionDigits: Int
    public var hadLeadingZeros: Bool
    public var usedGrouping: Bool
    public var isPercent: Bool
    public var currencySymbol: String?
    public var negativeByParentheses: Bool
}

public enum NumberParseError: Error, Hashable, Sendable, CustomStringConvertible {
    case notNumeric
    case multipleDecimalSeparators
    case invalidGrouping
    case empty

    public var description: String {
        switch self {
        case .notNumeric: "contains characters that are not part of a number"
        case .multipleDecimalSeparators: "contains more than one decimal separator"
        case .invalidGrouping: "digit grouping does not match the number format"
        case .empty: "contains no digits"
        }
    }
}

public enum NumberParsing {
    static let minusSigns: Set<Character> = ["-", "−", "–", "‒"]
    static let currencySymbols = ["€", "$", "£", "¥", "₹", "CHF", "EUR", "USD", "GBP", "JPY", "Fr."]
    static let spaceLike: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{2009}"]
    static let apostrophes: Set<Character> = ["'", "’"]

    public static func groupingSeparators(forDecimal decimal: Character) -> Set<Character> {
        decimal == "."
            ? [",", "'", "’", " ", "\u{00A0}", "\u{202F}", "\u{2009}"]
            : [".", "'", "’", " ", "\u{00A0}", "\u{202F}", "\u{2009}"]
    }

    /// Parses `raw` with the given decimal separator and accepted grouping separators.
    public static func parse(_ raw: String, decimal: Character, grouping: Set<Character>) -> Result<ParsedNumber, NumberParseError> {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.empty) }

        var negative = false
        var parentheses = false
        var percent = false
        var currency: String?

        if s.hasPrefix("("), s.hasSuffix(")"), s.count > 2 {
            parentheses = true
            negative = true
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if s.hasSuffix("%") {
            percent = true
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        for symbol in currencySymbols {
            if s.hasPrefix(symbol) {
                currency = symbol
                s = String(s.dropFirst(symbol.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            if s.hasSuffix(symbol) {
                currency = symbol
                s = String(s.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if let first = s.first, minusSigns.contains(first) {
            negative.toggle()
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if s.first == "+" {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if currency == nil {
            for symbol in currencySymbols where s.hasPrefix(symbol) {
                currency = symbol
                s = String(s.dropFirst(symbol.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !s.isEmpty else { return .failure(.empty) }

        var allowed = grouping
        allowed.insert(decimal)
        for ch in s where !ch.isASCIIDigit && !allowed.contains(ch) {
            return .failure(.notNumeric)
        }
        guard s.contains(where: \.isASCIIDigit) else { return .failure(.empty) }

        let decimalCount = s.filter { $0 == decimal }.count
        if decimalCount > 1 {
            // A repeated separator can only be grouping, which is invalid for this decimal mark.
            return .failure(.multipleDecimalSeparators)
        }

        var integerPart = s
        var fractionPart = ""
        if decimalCount == 1, let idx = s.lastIndex(of: decimal) {
            integerPart = String(s[..<idx])
            fractionPart = String(s[s.index(after: idx)...])
            guard fractionPart.allSatisfy(\.isASCIIDigit) else { return .failure(.invalidGrouping) }
        }

        var usedGrouping = false
        if integerPart.contains(where: { grouping.contains($0) }) {
            usedGrouping = true
            let separatorsUsed = Set(integerPart.filter { grouping.contains($0) })
            // Spaces and narrow spaces count as one family.
            let normalizedFamilies = Set(separatorsUsed.map { spaceLike.contains($0) ? " " : (apostrophes.contains($0) ? "'" : $0) })
            guard normalizedFamilies.count == 1 else { return .failure(.invalidGrouping) }
            let groups = integerPart.split(omittingEmptySubsequences: false) { grouping.contains($0) }.map(String.init)
            guard let firstGroup = groups.first, !firstGroup.isEmpty, firstGroup.count <= 3,
                  groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isASCIIDigit) }) else {
                return .failure(.invalidGrouping)
            }
            integerPart = groups.joined()
        }
        guard integerPart.allSatisfy(\.isASCIIDigit) else { return .failure(.notNumeric) }
        if integerPart.isEmpty { integerPart = "0" }

        let hadLeadingZeros = integerPart.count > 1 && integerPart.hasPrefix("0")
        var trimmed = String(integerPart.drop { $0 == "0" })
        if trimmed.isEmpty { trimmed = "0" }

        var canonical = trimmed
        if !fractionPart.isEmpty { canonical += "." + fractionPart }
        let isZero = canonical.allSatisfy { $0 == "0" || $0 == "." }
        if negative && !isZero { canonical = "-" + canonical }

        return .success(ParsedNumber(canonical: canonical, fractionDigits: fractionPart.count,
                                     hadLeadingZeros: hadLeadingZeros, usedGrouping: usedGrouping,
                                     isPercent: percent, currencySymbol: currency,
                                     negativeByParentheses: parentheses))
    }

    public static func parse(_ raw: String, format: NumberFormat) -> Result<ParsedNumber, NumberParseError>? {
        guard let decimal = format.decimalSeparator else { return nil }
        return parse(raw, decimal: decimal, grouping: format.groupingSeparators)
    }

    /// Interpretations of `raw` under the point and comma conventions.
    public static func interpretations(_ raw: String) -> [Character: ParsedNumber] {
        var result: [Character: ParsedNumber] = [:]
        for decimal in ["." as Character, ","] {
            if case .success(let p) = parse(raw, decimal: decimal, grouping: groupingSeparators(forDecimal: decimal)) {
                result[decimal] = p
            }
        }
        return result
    }

    /// True when the two conventions yield different values for `raw`.
    public static func isAmbiguous(_ raw: String) -> Bool {
        let i = interpretations(raw)
        guard let a = i["."], let b = i[","] else { return false }
        return a.canonical != b.canonical
    }

    /// Multiplies a canonical decimal string by a decimal scale, without binary floating point.
    public static func scale(_ canonical: String, by factor: String) -> String? {
        guard factor != "1" else { return canonical }
        guard let value = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")),
              let multiplier = Decimal(string: factor, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var product = value * multiplier
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 12, .plain)
        return canonicalString(rounded)
    }

    public static func canonicalString(_ decimal: Decimal) -> String {
        NSDecimalNumber(decimal: decimal).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    public static func decimal(_ canonical: String) -> Decimal? {
        Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
