import DocLensCore
import Foundation
import PDFKit

let usage = """
DocLens command-line interface

USAGE
  doclens info <file.pdf>
  doclens detect <file.pdf> [--page N]
  doclens extract <file.pdf> [--page N] [--region x,y,w,h] [--engine auto|text|ocr|vision|docling]
                  [--format grid|csv|json|xlsx] [--out PATH] [--number-format auto|point|comma|space|apostrophe]
                  [--languages en,it] [--python PATH]
  doclens corpus <directory>
  doclens bench <corpus-directory> [--engines text,ocr,vision,auto,docling] [--out report.md] [--python PATH]
  doclens docling-check --python PATH
  doclens add <file.pdf>... [--library DIR] [--detect] [--page N --region x,y,w,h] [--engine auto|text|ocr|vision]
              Imports PDFs into a DocLens library and optionally extracts tables into it.

Pages are 1-based. Regions are in PDF points (lower-left origin, unrotated page space).
Without --region, the whole page is used.
"""

struct CLIError: Error, CustomStringConvertible {
    var description: String
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ args: ArraySlice<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    options[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else {
                    options[key] = it.next() ?? ""
                }
            } else {
                positional.append(a)
            }
        }
    }

    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }
}

func engineKind(_ name: String?) throws -> EngineKind {
    switch (name ?? "auto").lowercased() {
    case "auto": .auto
    case "text", "textlayer": .textLayer
    case "ocr", "visionocr": .visionOCR
    case "vision", "document", "visiondocument": .visionDocument
    case "docling": .docling
    default: throw CLIError(description: "Unknown engine “\(name ?? "")”.")
    }
}

func numberFormat(_ name: String?) throws -> NumberFormat {
    switch (name ?? "auto").lowercased() {
    case "auto": .auto
    case "point": .pointDecimal
    case "comma": .commaDecimal
    case "space": .spaceCommaDecimal
    case "apostrophe": .apostrophePointDecimal
    default: throw CLIError(description: "Unknown number format “\(name ?? "")”.")
    }
}

func parseRegion(_ s: String) throws -> PageRect {
    let parts = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else { throw CLIError(description: "Region must be x,y,width,height.") }
    return PageRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Builds an in-memory snapshot so the CLI can reuse normalization, checks, and exporters.
func makeSnapshot(url: URL, segments: [TableSegment], extracted: ExtractedTable, settings: TableSettings) throws -> TableSnapshot {
    let pdf = try PDFSupport.open(url)
    let doc = DocumentRecord(filename: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent,
                             sha256: try Hashing.sha256(fileAt: url), pageCount: pdf.pageCount,
                             pages: PDFSupport.geometries(of: pdf), storedName: url.lastPathComponent, fileSize: 0,
                             hasTextLayer: PDFSupport.hasTextLayer(pdf))
    let table = TableRecord(documentID: doc.id, name: url.deletingPathExtension().lastPathComponent, settings: settings, segments: segments)
    var output = TableBuilder.build(table: table, document: doc, extracted: extracted, startedAt: Date(), cacheKey: nil)
    var t = table
    t.columns = output.columns
    t.currentRunID = output.run.id
    output.run.tableID = t.id
    return TableSnapshot(document: doc, table: t, run: output.run, cells: output.cells, corrections: [])
}

func renderGrid(_ snapshot: TableSnapshot, _ evaluation: TableEvaluation) -> String {
    var lines: [String] = []
    let widths = (0..<snapshot.columnCount).map { c in
        min(28, max(4, (0..<snapshot.rowCount).map { snapshot.cell(row: $0, column: c)?.text.count ?? 0 }.max() ?? 4))
    }
    for r in 0..<snapshot.rowCount {
        let role = snapshot.role(of: r)
        let marker = role == .header ? "H" : role == .total ? "T" : role == .excluded ? "x" : " "
        let fields = (0..<snapshot.columnCount).map { c -> String in
            let t = snapshot.cell(row: r, column: c)?.text ?? ""
            let s = t.count > widths[c] ? String(t.prefix(widths[c] - 1)) + "…" : t
            return s.padding(toLength: widths[c], withPad: " ", startingAt: 0)
        }
        lines.append(String(format: "%3d %@ | ", r + 1, marker) + fields.joined(separator: " | "))
    }
    lines.append("")
    lines.append("Columns: " + snapshot.table.columns.map { "\($0.letter) \($0.name) [\($0.type.rawValue)]" }.joined(separator: ", "))
    let failed = evaluation.results.filter { $0.status == .failed }
    lines.append("Checks: \(failed.count) failed")
    for f in failed.prefix(20) { lines.append("  [\(f.severity.rawValue)] \(f.ruleID): \(f.message)") }
    lines.append("Engine: \(snapshot.run.engine.name) (\(snapshot.run.engine.version))")
    for n in snapshot.run.notes { lines.append("Note: \(n)") }
    return lines.joined(separator: "\n")
}

// MARK: Commands

func info(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw CLIError(description: usage) }
    let url = fileURL(path)
    let pdf = try PDFSupport.open(url)
    print("File:        \(url.lastPathComponent)")
    print("SHA-256:     \(try Hashing.sha256(fileAt: url))")
    print("Pages:       \(pdf.pageCount)")
    print("Text layer:  \(PDFSupport.hasTextLayer(pdf) ? "yes" : "no")")
    for (i, g) in PDFSupport.geometries(of: pdf).enumerated().prefix(50) {
        let chars = pdf.page(at: i).map { PDFSupport.textCharacterCount(page: $0) } ?? 0
        print(String(format: "  page %3d  crop %.0f×%.0f  rotation %3d  characters %d", i + 1, g.cropBox.width, g.cropBox.height, g.rotation, chars))
    }
}

func detect(_ args: Arguments) async throws {
    guard let path = args.positional.first else { throw CLIError(description: usage) }
    let page = (args.int("page") ?? 1) - 1
    let candidates = try await VisionDocumentEngine.detectTables(documentURL: fileURL(path), pageIndex: page)
    if candidates.isEmpty { print("No tables detected on page \(page + 1).") }
    for c in candidates {
        print(String(format: "page %d  region %.1f,%.1f,%.1f,%.1f  %d×%d", c.pageIndex + 1, c.region.x, c.region.y,
                     c.region.width, c.region.height, c.rowCount, c.columnCount))
    }
}

func extract(_ args: Arguments) async throws {
    guard let path = args.positional.first else { throw CLIError(description: usage) }
    let url = fileURL(path)
    let pdf = try PDFSupport.open(url)
    let pageIndex = (args.int("page") ?? 1) - 1
    guard let page = pdf.page(at: pageIndex) else { throw PDFSupportError.pageOutOfRange(pageIndex, pdf.pageCount) }
    let region = try args.options["region"].map(parseRegion) ?? PageRect(page.bounds(for: .cropBox))
    let segment = TableSegment(pageIndex: pageIndex, region: region)
    var options = ExtractionOptions()
    options.recognitionLanguages = args.options["languages"]?.split(separator: ",").map(String.init) ?? []
    options.doclingPython = args.options["python"]
    var settings = TableSettings()
    settings.numberFormat = try numberFormat(args.options["number-format"])
    let started = Date()
    let extracted = try await ExtractionService.extract(documentURL: url, documentID: UUID(), segments: [segment],
                                                        engine: try engineKind(args.options["engine"]), options: options) { f, m in
        printErr(String(format: "[%3.0f%%] %@", f * 100, m))
    }
    printErr(String(format: "Extracted %d×%d in %.2f s", extracted.rowCount, extracted.columnCount, Date().timeIntervalSince(started)))
    let snapshot = try makeSnapshot(url: url, segments: [segment], extracted: extracted, settings: settings)
    let evaluation = CheckEngine.evaluate(snapshot)
    let format = args.options["format"] ?? "grid"
    let exportOptions = ExportOptions(writeSidecar: false)
    if format == "grid" {
        print(renderGrid(snapshot, evaluation))
        return
    }
    let dataset = ExportDataset(snapshot: snapshot, evaluation: evaluation, options: exportOptions)
    let data: Data
    switch format {
    case "csv": data = Data(CSVExporter.render(dataset, options: exportOptions).utf8)
    case "json": data = try JSONExporter.render(snapshot: snapshot, evaluation: evaluation, options: exportOptions, dataset: dataset)
    case "xlsx": data = XLSXExporter.render(snapshot: snapshot, evaluation: evaluation, dataset: dataset, options: exportOptions)
    case "raw":
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try e.encode(extracted)
    default: throw CLIError(description: "Unknown format “\(format)”.")
    }
    if let out = args.options["out"] {
        try data.write(to: fileURL(out))
        printErr("Wrote \(out)")
    } else if format == "xlsx" {
        throw CLIError(description: "XLSX output needs --out.")
    } else {
        FileHandle.standardOutput.write(data)
    }
}

func corpus(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw CLIError(description: usage) }
    let docs = try CorpusGenerator.generate(into: fileURL(path))
    for d in docs { print("\(d.document)  [\(d.tags.joined(separator: ", "))]") }
    print("Generated \(docs.count) documents in \(path)")
}

func doclingCheck(_ args: Arguments) async throws {
    guard let python = args.options["python"] else { throw CLIError(description: "Pass --python PATH.") }
    let hello = try await DoclingEngine.handshake(python: python)
    print("Worker \(hello.worker), protocol \(hello.protocolVersion), Python \(hello.python), Docling \(hello.docling ?? "not installed")")
}

// MARK: Benchmark

func loadTruths(_ dir: URL) throws -> [TruthDocument] {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".truth.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try files.map { try JSONDecoder().decode(TruthDocument.self, from: Data(contentsOf: $0)) }
}

func benchOne(_ args: Arguments) async throws {
    guard args.positional.count >= 4 else { throw CLIError(description: "bench-one <dir> <document> <engine> <out>") }
    let dir = fileURL(args.positional[0])
    let truthDoc = try loadTruths(dir).first { $0.document == args.positional[1] }!
    let kind = try engineKind(args.positional[2])
    var options = ExtractionOptions()
    options.doclingPython = args.options["python"]
    let url = dir.appendingPathComponent(truthDoc.document)
    let truth = truthDoc.tables[0]
    let started = Date()
    var score: BenchmarkScore
    do {
        let extracted = try await ExtractionService.extract(documentURL: url, documentID: UUID(), segments: truth.segments,
                                                            engine: kind, options: options) { _, _ in }
        score = BenchmarkScorer.score(truth: truth, extracted: extracted, document: truthDoc.document, engine: kind.rawValue,
                                      latency: Date().timeIntervalSince(started), memoryMB: nil)
    } catch {
        score = .failure(truth: truth, document: truthDoc.document, engine: kind.rawValue,
                         latency: Date().timeIntervalSince(started), error: error.localizedDescription)
    }
    try JSONEncoder().encode(score).write(to: fileURL(args.positional[3]))
}

/// Runs one measurement in a child process to record its own peak memory.
func spawnMeasured(_ arguments: [String]) throws -> (status: Int32, peakMB: Double, seconds: Double) {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + arguments).map { strdup($0) } + [nil]
    defer { for p in argv { free(p) } }
    let start = Date()
    let rc = posix_spawn(&pid, exe, nil, nil, argv, environ)
    guard rc == 0 else { throw CLIError(description: "posix_spawn failed: \(rc)") }
    var status: Int32 = 0
    var usage = rusage()
    wait4(pid, &status, 0, &usage)
    return (status, Double(usage.ru_maxrss) / 1_048_576, Date().timeIntervalSince(start))
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(1, size))
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func measureCancellation(url: URL, segment: TableSegment, kind: EngineKind) async -> Double {
    let task = Task {
        try await ExtractionService.extract(documentURL: url, documentID: UUID(), segments: [segment], engine: kind,
                                            options: ExtractionOptions()) { _, _ in }
    }
    try? await Task.sleep(for: .milliseconds(150))
    let cancelAt = Date()
    task.cancel()
    _ = try? await task.value
    return Date().timeIntervalSince(cancelAt)
}

func bench(_ args: Arguments) async throws {
    guard let path = args.positional.first else { throw CLIError(description: usage) }
    let dir = fileURL(path)
    let truths = try loadTruths(dir)
    guard !truths.isEmpty else { throw CLIError(description: "No *.truth.json files in \(path). Run `doclens corpus` first.") }
    let engines = try (args.options["engines"] ?? "text,ocr,vision,auto").split(separator: ",").map { try engineKind(String($0)) }
    var scores: [BenchmarkScore] = []
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("doclens-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    for truth in truths {
        for engine in engines {
            if engine == .textLayer && truth.scanned { continue }
            let out = temp.appendingPathComponent(UUID().uuidString + ".json")
            var a = ["bench-one", dir.path, truth.document, engine.rawValue, out.path]
            if let p = args.options["python"] { a += ["--python", p] }
            let m = try spawnMeasured(a)
            guard var s = try? JSONDecoder().decode(BenchmarkScore.self, from: Data(contentsOf: out)) else {
                printErr("\(truth.document) \(engine.rawValue): child exited with status \(m.status)")
                continue
            }
            s.peakMemoryMB = m.peakMB
            scores.append(s)
            printErr(String(format: "%-34@ %-15@ cells %5.1f%%  numeric %5.1f%%  rows -%d/+%d  cols %d/%d  src %5.1f%%  %.2fs  %.0f MB%@",
                            truth.document as NSString, engine.rawValue as NSString, s.cellAccuracy * 100, s.numericAccuracy * 100,
                            s.missingRows, s.extraRows, s.extractedColumns, s.truthColumns, s.sourceCorrect * 100,
                            s.latencySeconds, s.peakMemoryMB ?? 0, (s.error.map { "  ERROR " + $0 } ?? "") as NSString))
        }
    }

    // Cancellation latency on a scanned page.
    var cancellation: [(String, Double)] = []
    if let scanned = truths.first(where: \.scanned) {
        for engine in engines where engine != .textLayer && engine != .docling {
            let latency = await measureCancellation(url: dir.appendingPathComponent(scanned.document),
                                                    segment: scanned.tables[0].segments[0], kind: engine)
            cancellation.append((engine.rawValue, latency))
        }
    }

    let report = benchReport(scores: scores, truths: truths, engines: engines, cancellation: cancellation)
    let outPath = args.options["out"] ?? "benchmark-report.md"
    try report.write(to: fileURL(outPath), atomically: true, encoding: .utf8)
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(scores).write(to: fileURL(outPath).deletingPathExtension().appendingPathExtension("json"))
    print("Wrote \(outPath)")
}

func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

func benchReport(scores: [BenchmarkScore], truths: [TruthDocument], engines: [EngineKind], cancellation: [(String, Double)]) -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    let df = ISO8601DateFormatter()
    var r = "# DocLens extraction benchmark\n\n"
    r += "Generated \(df.string(from: Date())) by `doclens bench`.\n\n"
    r += "## Environment\n\n"
    r += "- Hardware: \(sysctlString("hw.model")), \(sysctlString("machdep.cpu.brand_string")), \(String(format: "%.0f", memGB)) GB memory\n"
    r += "- macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\n"
    r += "- Layout analyzer \(LayoutAnalyzer.version)\n"
    r += "- Corpus: \(truths.count) synthetic documents generated by `doclens corpus` (\(truths.filter(\.scanned).count) simulated scans)\n\n"
    r += "The corpus is synthetic. It exercises known layout features with exact ground truth, but it does not represent real administrative or statistical reports. Treat these numbers as regression measurements, not as accuracy claims for real documents.\n\n"
    r += "## Metrics\n\n"
    r += "- **Cells**: exact text match per cell after aligning rows.\n- **Numeric**: numeric cells whose parsed value matches.\n"
    r += "- **Rows**: missing / extra rows against the truth.\n- **Source**: share of compared cells whose highlighted region falls inside the true cell box.\n"
    r += "- **Latency** includes opening the PDF and rendering. **Peak memory** is the maximum resident size of a separate process running one extraction.\n\n"
    r += "## Summary by engine\n\n| Engine | Documents | Cells | Numeric | Missing rows | Extra rows | Source | Median latency | Max peak memory |\n|---|---|---|---|---|---|---|---|---|\n"
    for e in engines {
        let s = scores.filter { $0.engine == e.rawValue }
        guard !s.isEmpty else { continue }
        let cells = Double(s.map(\.cellsExact).reduce(0, +)) / Double(max(1, s.map(\.cellsCompared).reduce(0, +)))
        let numeric = Double(s.map(\.numericExact).reduce(0, +)) / Double(max(1, s.map(\.numericCells).reduce(0, +)))
        let lat = s.map(\.latencySeconds).sorted()[s.count / 2]
        let mem = s.compactMap(\.peakMemoryMB).max() ?? 0
        let src = s.map(\.sourceCorrect).reduce(0, +) / Double(s.count)
        r += "| \(e.label) | \(s.count) | \(pct(cells)) | \(pct(numeric)) | \(s.map(\.missingRows).reduce(0, +)) | \(s.map(\.extraRows).reduce(0, +)) | \(pct(src)) | \(String(format: "%.2f s", lat)) | \(String(format: "%.0f MB", mem)) |\n"
    }
    r += "\n## Results per document\n\n| Document | Engine | Cells | Numeric | Rows (truth/got) | Columns (truth/got) | Leading zeros kept | Header rows (truth/got) | Source | Latency | Peak memory |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
    for s in scores {
        let lz = s.leadingZeroCells == 0 ? "n/a" : "\(s.leadingZeroPreserved)/\(s.leadingZeroCells)"
        if let err = s.error {
            r += "| \(s.document) | \(s.engine) | failed: \(err) | | | | | | | \(String(format: "%.2f s", s.latencySeconds)) | |\n"
            continue
        }
        r += "| \(s.document) | \(s.engine) | \(pct(s.cellAccuracy)) | \(pct(s.numericAccuracy)) | \(s.truthRows)/\(s.extractedRows) | \(s.truthColumns)/\(s.extractedColumns) | \(lz) | \(s.headerRowsExpected)/\(s.headerRowsDetected) | \(pct(s.sourceCorrect)) | \(String(format: "%.2f s", s.latencySeconds)) | \(String(format: "%.0f MB", s.peakMemoryMB ?? 0)) |\n"
    }
    if !cancellation.isEmpty {
        r += "\n## Cancellation latency\n\nTime from cancelling an extraction 150 ms after it started until the task returned, on a scanned page.\n\n| Engine | Latency |\n|---|---|\n"
        for (e, l) in cancellation { r += "| \(e) | \(String(format: "%.0f ms", l * 1000)) |\n" }
    }
    let failures = scores.filter { $0.error != nil || $0.cellAccuracy < 0.999 || $0.missingRows + $0.extraRows > 0 }
    r += "\n## Known failure cases\n\n"
    if failures.isEmpty { r += "None in this corpus.\n" }
    for s in failures {
        var why: [String] = []
        if let e = s.error { why.append(e) }
        if s.extractedColumns != s.truthColumns && s.error == nil { why.append("column count \(s.extractedColumns) instead of \(s.truthColumns)") }
        if s.missingRows > 0 { why.append("\(s.missingRows) rows not matched") }
        if s.extraRows > 0 { why.append("\(s.extraRows) extra rows") }
        if s.cellsCompared > 0 && s.cellAccuracy < 0.999 { why.append("\(s.cellsCompared - s.cellsExact) of \(s.cellsCompared) cells differ") }
        if s.headerRowsDetected != s.headerRowsExpected && s.error == nil { why.append("header rows \(s.headerRowsDetected) instead of \(s.headerRowsExpected)") }
        r += "- `\(s.document)` with `\(s.engine)`: \(why.joined(separator: "; ")).\n"
    }
    return r
}

// MARK: Library

func addToLibrary(_ args: Arguments) async throws {
    guard !args.positional.isEmpty else { throw CLIError(description: usage) }
    let directory = args.options["library"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LibraryStore.defaultDirectory
    let store = try LibraryStore(directory: directory)
    let kind = try engineKind(args.options["engine"])
    for path in args.positional {
        let (doc, isNew) = try store.importDocument(from: fileURL(path))
        print("\(isNew ? "imported" : "already in library")  \(doc.title)  (\(doc.pageCount) pages, sha256 \(doc.sha256.prefix(12)))")
        var segments: [TableSegment] = []
        if let region = args.options["region"] {
            segments.append(TableSegment(pageIndex: (args.int("page") ?? 1) - 1, region: try parseRegion(region)))
        } else if args.options["detect"] != nil {
            let pages = args.int("page").map { [$0 - 1] } ?? Array(0..<doc.pageCount)
            for page in pages {
                let found = try await VisionDocumentEngine.detectTables(documentURL: store.sourceURL(for: doc), pageIndex: page)
                segments += found.map { TableSegment(pageIndex: $0.pageIndex, region: $0.region) }
            }
        }
        for segment in segments {
            let table = try store.createTable(document: doc, segments: [segment])
            let started = Date()
            do {
                let extracted = try await ExtractionService.extract(documentURL: store.sourceURL(for: doc), documentID: doc.id,
                                                                    segments: [segment], engine: kind, options: ExtractionOptions(),
                                                                    progress: { _, _ in })
                let (snapshot, _) = try store.commitExtraction(tableID: table.id, extracted: extracted, startedAt: started, cacheKey: nil)
                let issues = store.evaluate(snapshot).unresolved(in: snapshot).count
                print("  \(table.name): page \(segment.pageIndex + 1), \(snapshot.rowCount) rows x \(snapshot.columnCount) columns, \(issues) issues, \(snapshot.run.engine.name)")
            } catch {
                try? store.recordFailedRun(tableID: table.id, engine: ExtractionService.engine(for: kind).descriptor(options: ExtractionOptions()),
                                           startedAt: started, error: error, cancelled: false)
                print("  \(table.name): extraction failed: \(error.localizedDescription)")
            }
        }
    }
    print("library: \(store.directory.path)")
}

// MARK: Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let parsed = Arguments(arguments.dropFirst())
do {
    switch command {
    case "info": try info(parsed)
    case "detect": try await detect(parsed)
    case "extract": try await extract(parsed)
    case "corpus": try corpus(parsed)
    case "bench": try await bench(parsed)
    case "bench-one": try await benchOne(parsed)
    case "docling-check": try await doclingCheck(parsed)
    case "add": try await addToLibrary(parsed)
    default: print(usage)
    }
} catch {
    printErr("error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
    exit(1)
}
