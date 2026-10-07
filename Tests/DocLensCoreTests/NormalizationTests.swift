import Foundation
import Testing
@testable import DocLensCore

@Suite struct NumberParsingTests {
    func canonical(_ raw: String, _ format: NumberFormat) -> String? {
        guard case .success(let p)? = NumberParsing.parse(raw, format: format) else { return nil }
        return p.canonical
    }

    @Test func pointDecimalWithCommaGrouping() {
        #expect(canonical("1,234.56", .pointDecimal) == "1234.56")
        #expect(canonical("9,104,772", .pointDecimal) == "9104772")
    }

    @Test func commaDecimalWithPointGrouping() {
        #expect(canonical("1.234,56", .commaDecimal) == "1234.56")
        #expect(canonical("1.287,36", .commaDecimal) == "1287.36")
    }

    @Test func spaceGroupingAndNarrowSpaces() {
        #expect(canonical("5 762,4", .spaceCommaDecimal) == "5762.4")
        #expect(canonical("657\u{202F}856", .spaceCommaDecimal) == "657856")
    }

    @Test func apostropheGrouping() {
        #expect(canonical("1'234.50", .apostrophePointDecimal) == "1234.50")
    }

    @Test func parenthesesAreNegative() throws {
        let result = try #require(NumberParsing.parse("(612,300.25)", format: .pointDecimal))
        let p = try result.get()
        #expect(p.canonical == "-612300.25")
        #expect(p.negativeByParentheses)
    }

    @Test func currencyAndPercent() throws {
        let money = try #require(NumberParsing.parse("€ 1,250,400.00", format: .pointDecimal)).get()
        #expect(money.canonical == "1250400.00")
        #expect(money.currencySymbol == "€")
        let pct = try #require(NumberParsing.parse("-689.9%", format: .pointDecimal)).get()
        #expect(pct.canonical == "-689.9")
        #expect(pct.isPercent)
    }

    @Test func rejectsMalformedGrouping() {
        #expect(canonical("12,34,567.0", .pointDecimal) == nil)
        #expect(canonical("1.2.3,4,5", .commaDecimal) == nil)
        #expect(canonical("abc", .pointDecimal) == nil)
    }

    @Test func ambiguityIsDetected() {
        #expect(NumberParsing.isAmbiguous("1.234"))
        #expect(NumberParsing.isAmbiguous("848,885"))
        #expect(!NumberParsing.isAmbiguous("1.5"))
        #expect(!NumberParsing.isAmbiguous("1,234.5"))
    }

    @Test func scalingIsExact() {
        #expect(NumberParsing.scale("1.5", by: "1000") == "1500")
        #expect(NumberParsing.scale("0.1", by: "3") == "0.3")
    }
}

@Suite struct DateParsingTests {
    @Test func ambiguousDayMonthIsFlagged() {
        if case .ambiguous(let candidates) = DateParsing.parse("03/04/2021", order: .auto) {
            #expect(Set(candidates) == ["2021-04-03", "2021-03-04"])
        } else {
            Issue.record("Expected an ambiguous reading")
        }
    }

    @Test func explicitOrderResolves() {
        #expect(DateParsing.parse("03/04/2021", order: .dmy) == .value("2021-04-03"))
        #expect(DateParsing.parse("03/04/2021", order: .mdy) == .value("2021-03-04"))
    }

    @Test func unambiguousDayFirst() {
        #expect(DateParsing.parse("29/12/2026", order: .auto) == .value("2026-12-29"))
    }

    @Test func rejectsImpossibleDates() {
        #expect(DateParsing.parse("31/02/2026", order: .dmy) == .invalid)
    }
}

@Suite struct TypeInferenceTests {
    let settings = TableSettings()

    @Test func leadingZeroCodesAreIdentifiers() {
        let type = TypeInference.infer(header: "Codice ISTAT", values: ["001272", "015146", "027042"], settings: settings)
        #expect(type == .identifier)
    }

    @Test func decimalsAndIntegers() {
        #expect(TypeInference.infer(header: "Density", values: ["108.5", "383.3", "68.0"], settings: settings) == .decimal)
        #expect(TypeInference.infer(header: "Population", values: ["9,104,772", "11,763,650"], settings: settings) == .integer)
    }

    @Test func percentAndCurrency() {
        #expect(TypeInference.infer(header: "Change", values: ["11.8%", "3.8%", "-689.9%"], settings: settings) == .percent)
        #expect(TypeInference.infer(header: "2025", values: ["€ 1,250.00", "€ 12.50"], settings: settings) == .currency)
    }

    @Test func missingMarkersDoNotChangeType() {
        #expect(TypeInference.infer(header: "Cases", values: ["1,204", "-", "..", "877"], settings: settings,
                                    decimalHint: ".") == .integer)
    }

    @Test func ambiguousIntegersWithoutEvidenceAreNotGuessed() {
        // "1,204" reads as 1204 or 1.204; without evidence the column stays decimal so the
        // ambiguity check flags it instead of silently picking integers.
        #expect(TypeInference.infer(header: "Cases", values: ["1,204", "877"], settings: settings) == .decimal)
    }
}

@Suite struct NormalizerTests {
    @Test func missingMarkerOnlyInTypedColumns() {
        let settings = TableSettings()
        let ctx = ColumnContext(decimal: ".", grouping: NumberParsing.groupingSeparators(forDecimal: "."),
                                resolution: .tableSetting, dateOrder: .auto, dateResolution: .notApplicable)
        let numeric = ColumnSpec(index: 0, name: "N", type: .integer)
        let text = ColumnSpec(index: 1, name: "T", type: .text)
        #expect(ValueNormalizer.normalize("-", column: numeric, context: ctx, settings: settings).kind == .missing)
        #expect(ValueNormalizer.normalize("-", column: text, context: ctx, settings: settings).kind == .value)
    }

    @Test func footnoteMarkerIsRecordedAsTransformation() {
        let settings = TableSettings()
        let ctx = ColumnContext(decimal: ".", grouping: NumberParsing.groupingSeparators(forDecimal: "."),
                                resolution: .tableSetting, dateOrder: .auto, dateResolution: .notApplicable)
        let v = ValueNormalizer.normalize("12.5*", column: ColumnSpec(index: 0, name: "Rate", type: .decimal), context: ctx,
                                          settings: settings)
        #expect(v.kind == .value)
        #expect(v.canonical == "12.5")
        #expect(!v.transformations.isEmpty)
    }

    @Test func unresolvedAmbiguityStaysAmbiguous() {
        let settings = TableSettings()
        let ctx = ColumnContext(decimal: nil, grouping: [], resolution: .unresolved, dateOrder: .auto, dateResolution: .notApplicable)
        let v = ValueNormalizer.normalize("1.234", column: ColumnSpec(index: 0, name: "X", type: .decimal), context: ctx,
                                          settings: settings)
        #expect(v.kind == .ambiguous)
        #expect(v.candidates.count == 2)
    }
}

@Suite struct GeometryTests {
    @Test(arguments: [0, 90, 180, 270])
    func pageDisplayRoundTrip(rotation: Int) {
        let g = PageGeometry(mediaBox: PageRect(x: 0, y: 0, width: 612, height: 792),
                             cropBox: PageRect(x: 10, y: 20, width: 590, height: 760), rotation: rotation)
        let r = PageRect(x: 100, y: 200, width: 50, height: 30)
        let back = g.toPage(g.toDisplay(r, scale: 3), scale: 3)
        #expect(abs(back.x - r.x) < 1e-6 && abs(back.y - r.y) < 1e-6)
        #expect(abs(back.width - r.width) < 1e-6 && abs(back.height - r.height) < 1e-6)
        let display = g.toDisplay(g.cropBox)
        #expect(abs(display.width - g.displaySize.width) < 1e-6)
        #expect(abs(display.minX) < 1e-6 && abs(display.minY) < 1e-6)
    }
}

@Suite struct ExportPrimitiveTests {
    @Test func crc32KnownValue() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func csvFormulaProtection() {
        #expect(CSVExporter.protect("=SUM(A1:A3)") == "'=SUM(A1:A3)")
        #expect(CSVExporter.protect("+cmd") == "'+cmd")
        #expect(CSVExporter.protect("Revenue") == "Revenue")
    }

    @Test func csvQuoting() {
        #expect(CSVExporter.quote("a,b", delimiter: ",") == "\"a,b\"")
        #expect(CSVExporter.quote("say \"hi\"", delimiter: ",") == "\"say \"\"hi\"\"\"")
        #expect(CSVExporter.quote("plain", delimiter: ",") == "plain")
    }

    @Test func recipeHeaderMatching() {
        #expect(RecipeMatching.similarity("Population", "Popolation") > 0.8)
        #expect(RecipeMatching.matches(header: "Area (km²)", aliases: ["area km2", "Area (km²)"]))
    }
}
