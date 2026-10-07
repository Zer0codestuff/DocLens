import Foundation

/// Suggests a column type from extracted values. Suggestions stay unconfirmed until the user
/// confirms them, and identifier detection wins over numeric parsing to preserve leading zeros.
public enum TypeInference {
    static let identifierKeywords = [
        "code", "codice", "cod.", "id", "istat", "zip", "cap", "postal", "postcode", "iso", "nuts",
        "fips", "ateco", "nace", "isin", "iban", "vat", "piva", "p.iva", "sku", "ean", "plz", "siren", "insee",
    ]

    /// Decimal separator suggested by unambiguous numbers anywhere in `values`.
    public static func decimalHint(_ values: [String], settings: TableSettings) -> Character? {
        ValueNormalizer.decimalEvidence(values, settings: settings)?.decimal
    }

    public static func infer(header: String, values: [String], settings: TableSettings,
                             decimalHint: Character? = nil) -> ColumnType {
        let cleaned: [String] = values.compactMap { raw in
            var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty || ValueNormalizer.isMissingMarker(v, tokens: settings.missingTokens) { return nil }
            if settings.stripFootnoteMarkers { v = ValueNormalizer.splitFootnote(v).value }
            return v
        }
        guard !cleaned.isEmpty else { return .text }

        let headerLower = header.lowercased()
        let headerWords = Set(headerLower.split(whereSeparator: { !$0.isLetter && $0 != "." }).map(String.init))
        let headerSaysIdentifier = identifierKeywords.contains { keyword in
            keyword.count <= 3 ? headerWords.contains(keyword) : headerLower.contains(keyword)
        }

        let digitsOnly = cleaned.allSatisfy { $0.allSatisfy(\.isASCIIDigit) }
        if digitsOnly {
            let leadingZero = cleaned.contains { $0.count > 1 && $0.hasPrefix("0") }
            let sameLength = Set(cleaned.map(\.count)).count == 1 && cleaned.count > 2 && (cleaned.first?.count ?? 0) >= 3
            if leadingZero || headerSaysIdentifier { return .identifier }
            if sameLength && headerSaysIdentifier { return .identifier }
        }
        if headerSaysIdentifier && cleaned.allSatisfy({ $0.rangeOfCharacter(from: .whitespaces) == nil && $0.count <= 20 }) {
            if cleaned.contains(where: { $0.contains(where: \.isLetter) }) || digitsOnly { return .identifier }
        }

        var numeric = 0, percent = 0, currency = 0, fractional = 0
        for v in cleaned {
            let i = NumberParsing.interpretations(v)
            guard !i.isEmpty else { continue }
            numeric += 1
            let any = i["."] ?? i[","]!
            if any.isPercent { percent += 1 }
            if any.currencySymbol != nil { currency += 1 }
            // A value counts as fractional only when no interpretation reads it as an integer.
            if i.values.allSatisfy({ $0.fractionDigits > 0 }) { fractional += 1 }
        }
        let ratio = Double(numeric) / Double(cleaned.count)
        if ratio >= 0.8 {
            if percent * 2 >= numeric { return .percent }
            if currency * 2 >= numeric { return .currency }
            if fractional > 0 { return .decimal }
            let ambiguousCount = cleaned.filter { NumberParsing.isAmbiguous($0) }.count
            if ambiguousCount > 0 {
                guard let d = settings.numberFormat.decimalSeparator ?? decimalHint else { return .decimal }
                let grouping = settings.numberFormat.decimalSeparator != nil
                    ? settings.numberFormat.groupingSeparators : NumberParsing.groupingSeparators(forDecimal: d)
                let anyFraction = cleaned.contains { v in
                    if case .success(let p) = NumberParsing.parse(v, decimal: d, grouping: grouping) { return p.fractionDigits > 0 }
                    return false
                }
                return anyFraction ? .decimal : .integer
            }
            return .integer
        }

        let dates = cleaned.filter { DateParsing.parse($0, order: .auto) != .invalid }.count
        let looksLikeYears = cleaned.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isASCIIDigit) }
        if !looksLikeYears && Double(dates) / Double(cleaned.count) >= 0.8 { return .date }
        return .text
    }

    /// Suggests a scale from header text such as "(thousands)" or "in migliaia".
    public static func inferScale(header: String) -> (scale: String, unit: String)? {
        let h = header.lowercased()
        let table: [(String, String)] = [
            ("thousand", "1000"), ("migliaia", "1000"), ("'000", "1000"), ("000s", "1000"), ("tausend", "1000"), ("milliers", "1000"),
            ("million", "1000000"), ("milioni", "1000000"), ("millionen", "1000000"), ("billion", "1000000000"), ("miliardi", "1000000000"),
        ]
        for (k, v) in table where h.contains(k) { return (v, "") }
        return nil
    }
}
