import CoreGraphics
import Foundation
import PDFKit

/// Optional engine that runs Docling in a separate Python process using the versioned JSON
/// protocol in `docling_worker.py`. The packaged application does not depend on it.
public struct DoclingEngine: ExtractionEngine {
    public static let protocolVersion = 1
    public init() {}
    public var kind: EngineKind { .docling }

    public static var bundledWorkerURL: URL? {
        Bundle.module.url(forResource: "docling_worker", withExtension: "py")
    }

    public func descriptor(options: ExtractionOptions) -> EngineDescriptor {
        EngineDescriptor(kind: .docling, name: "Docling (Python worker)", version: "protocol \(Self.protocolVersion)",
                         configuration: ["python": options.doclingPython ?? "unset"])
    }

    public struct Hello: Codable, Sendable, Hashable {
        public var protocolVersion: Int
        public var worker: String
        public var python: String
        public var docling: String?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol", worker, python, docling
        }
    }

    struct Message: Decodable {
        struct Box: Decodable { var l: Double; var b: Double; var r: Double; var t: Double }
        struct Cell: Decodable {
            var row: Int; var column: Int; var rowSpan: Int; var colSpan: Int; var text: String
            var header: Bool?; var bbox: Box?
        }
        struct Table: Decodable { var rowCount: Int; var columnCount: Int; var cells: [Cell] }
        var type: String
        var job: String?
        var fraction: Double?
        var message: String?
        var code: String?
        var table: Table?
        var engine: [String: String]?
        var `protocol`: Int?
        var worker: String?
        var python: String?
        var docling: String?
    }

    static func launch(python: String, worker: URL) throws -> (Process, FileHandle, FileHandle) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", worker.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            throw ExtractionError.engineUnavailable("The Python interpreter at \(python) could not be started: \(error.localizedDescription)")
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { FileHandle.standardError.write(Data(("[docling] " + s).utf8)) }
        }
        return (process, input.fileHandleForWriting, output.fileHandleForReading)
    }

    static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    /// Checks that the interpreter runs the worker and reports Docling's version.
    public static func handshake(python: String, worker: URL? = DoclingEngine.bundledWorkerURL) async throws -> Hello {
        guard let worker else { throw ExtractionError.engineUnavailable("The Docling worker script is missing from the application bundle.") }
        let (process, input, output) = try launch(python: python, worker: worker)
        defer { if process.isRunning { process.terminate() } }
        try send(["protocol": protocolVersion, "type": "hello"], to: input)
        for try await line in output.bytes.lines {
            guard let data = line.data(using: .utf8), let m = try? JSONDecoder().decode(Message.self, from: data) else { continue }
            if m.type == "hello" {
                try? send(["protocol": protocolVersion, "type": "shutdown"], to: input)
                return Hello(protocolVersion: m.protocol ?? 0, worker: m.worker ?? "?", python: m.python ?? "?", docling: m.docling)
            }
            if m.type == "error" { throw ExtractionError.workerFailed(m.message ?? "unknown error") }
        }
        throw ExtractionError.workerFailed("The worker exited without answering.")
    }

    public func extract(_ input: SegmentInput, progress: ProgressHandler) async throws -> ExtractedTable {
        guard let python = input.options.doclingPython, !python.isEmpty else {
            throw ExtractionError.engineUnavailable("Docling needs a Python interpreter. Set one in Settings › Extraction.")
        }
        guard let worker = input.options.doclingWorker.map(URL.init(fileURLWithPath:)) ?? Self.bundledWorkerURL else {
            throw ExtractionError.engineUnavailable("The Docling worker script is missing.")
        }
        let (_, page) = try EngineSupport.page(input)
        let geometry = PDFSupport.geometry(of: page)
        let display = geometry.toDisplay(input.segment.region)
        let (process, stdin, stdout) = try Self.launch(python: python, worker: worker)
        let job = UUID().uuidString

        return try await withTaskCancellationHandler {
            defer { if process.isRunning { process.terminate() } }
            try Self.send(["protocol": Self.protocolVersion, "type": "extract", "job": job, "pdf": input.documentURL.path,
                           "page": input.segment.pageIndex,
                           "region": ["x": display.minX, "y": display.minY, "width": display.width, "height": display.height]],
                          to: stdin)
            for try await line in stdout.bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8), let m = try? JSONDecoder().decode(Message.self, from: data) else { continue }
                switch m.type {
                case "progress":
                    progress(m.fraction ?? 0, m.message ?? "Working")
                case "error":
                    if m.code == "no-table" { throw ExtractionError.noTableFound }
                    if m.code == "docling-missing" { throw ExtractionError.engineUnavailable(m.message ?? "Docling is not installed.") }
                    throw ExtractionError.workerFailed(m.message ?? m.code ?? "unknown error")
                case "result":
                    guard let t = m.table else { throw ExtractionError.workerFailed("The result had no table.") }
                    try? Self.send(["protocol": Self.protocolVersion, "type": "shutdown"], to: stdin)
                    return convert(t, engineInfo: m.engine ?? [:], geometry: geometry, input: input)
                default:
                    continue
                }
            }
            throw ExtractionError.workerFailed("The worker exited before returning a result.")
        } onCancel: {
            process.terminate()
        }
    }

    func convert(_ t: Message.Table, engineInfo: [String: String], geometry: PageGeometry, input: SegmentInput) -> ExtractedTable {
        var seen = Set<[Int]>()
        var cells: [ExtractedCell] = []
        var headerRows = 0
        for c in t.cells where !seen.contains([c.row, c.column]) {
            seen.insert([c.row, c.column])
            if c.header == true { headerRows = max(headerRows, c.row + c.rowSpan) }
            let regions: [PageRect] = c.bbox.map { b in
                [geometry.toPage(CGRect(x: b.l, y: b.b, width: b.r - b.l, height: b.t - b.b))]
            } ?? []
            let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            cells.append(ExtractedCell(row: c.row, column: c.column, rowSpan: c.rowSpan, colSpan: c.colSpan, text: text,
                                       pageIndex: input.segment.pageIndex, regions: text.isEmpty ? [] : regions,
                                       method: .doclingCell, flags: c.colSpan > 1 ? [CellFlag.spansColumns] : []))
        }
        var engine = descriptor(options: input.options)
        engine.version = "docling \(engineInfo["docling"] ?? "?"); worker \(engineInfo["worker"] ?? "?"); python \(engineInfo["python"] ?? "?")"
        for (k, v) in engineInfo { engine.configuration[k] = v }
        return ExtractedTable(rowCount: t.rowCount, columnCount: t.columnCount, cells: cells,
                              rowSegments: Array(repeating: 0, count: t.rowCount),
                              headerRowCount: min(headerRows, 3), engine: engine,
                              notes: ["Docling cell boxes cover whole cells, not individual words."])
    }
}
