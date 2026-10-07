# DocLens

DocLens is a native macOS app that turns PDF tables into reviewed, exportable datasets. Every value keeps a link to where it came from on the page, so you can check it, correct it, and export data you have actually reviewed.

Everything runs locally. No accounts, no cloud processing.

## What it does

- **Import** PDFs into a local library. Each source is copied read-only and identified by its SHA-256 hash.
- **Find tables** by dragging a region on the page or by detecting tables on the page and clicking one.
- **Extract** with the PDF text layer (digital documents) or Apple Vision (scans). `Automatic` picks the text layer when the region has readable text.
- **Review** the PDF next to an editable grid. Selecting a cell highlights its source region; clicking a value in the PDF selects its cell. Cells are unreviewed, need review, or reviewed, and that state is kept separate from automatic checks.
- **Check** for conversion failures, ambiguous number formats, uneven rows, missing source evidence, schema changes, and totals that do not add up. A passing check never marks a cell as reviewed.
- **Correct** values, column types, units, and number formats, with full undo and a per-cell history. Re-extraction creates a new version and carries corrections over instead of overwriting them.
- **Export** CSV, XLSX (`Data`, `Sources`, `Corrections` sheets), and JSON with full provenance. Exports disclose unresolved issues and unreviewed cells, keep identifiers such as `00124` as text, and neutralize spreadsheet formulas in source text.
- **Reuse** a reviewed table as a recipe and apply it to other documents in a cancellable queue. Recipes locate the table by header text, fall back to the saved position, and snap to the detected table. Every result still needs review.
- **Multipage tables**: add regions on other pages. Repeated header rows are marked and excluded from the data.

## Requirements

- macOS 26 or later on Apple Silicon (uses Vision `RecognizeDocumentsRequest`).
- Xcode 26 or later to build.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the Xcode project from `project.yml`.
- Optional: a Python environment with Docling for the experimental external engine. The app does not need it.

## Build and run

```sh
# Core library, CLI, and tests
swift build
swift test

# App
xcodegen generate
xcodebuild -project DocLens.xcodeproj -scheme DocLens -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/DocLens.app
```

The library lives in `~/Library/Application Support/DocLens/Library`. Set `DOCLENS_LIBRARY=/path/to/dir` to use another one, for example for testing.

## Command line

The `doclens` executable uses the same extraction code as the app.

```sh
swift run doclens info report.pdf
swift run doclens detect report.pdf --page 2
swift run doclens extract report.pdf --page 2 --region 50,400,500,300 --format csv --out table.csv
swift run doclens add report.pdf --library /tmp/lib --detect
swift run doclens corpus /tmp/corpus
swift run doclens bench /tmp/corpus --engines text,ocr,vision,auto --out Evaluation/benchmark.md
```

Pages are 1-based. Regions are in PDF points, with a lower-left origin, in unrotated page space.

## Evaluation

`Evaluation/benchmark.md` holds the latest benchmark on the synthetic corpus produced by `doclens corpus`: 13 documents covering grids, borderless tables, comma and space decimal conventions, missing values, rotated pages, multipage tables with repeated headers, spanning headers, wrapped cells, and three simulated scans. `Evaluation/docling-comparison.md` compares Docling with the built-in engines on the same corpus.

The corpus is synthetic, so the numbers are regression measurements, not accuracy claims for real reports. A corpus of real annotated documents is still needed.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/DocLensCore/Model` | Engine-independent documents, tables, cells, sources, geometry |
| `Sources/DocLensCore/Extraction` | Text layer, Vision OCR, Vision document, and Docling engines; layout analysis |
| `Sources/DocLensCore/Normalization` | Locale-aware number parsing, type inference, value normalization |
| `Sources/DocLensCore/Checks` | Check rules and evaluation |
| `Sources/DocLensCore/Store` | SQLite library, versioned extractions, corrections, carry-over |
| `Sources/DocLensCore/Export` | CSV, XLSX, JSON exporters |
| `Sources/DocLensCore/Recipes` | Recipe creation, table location, header matching |
| `Sources/DocLensCore/Evaluation` | Corpus generator and benchmark |
| `Sources/doclens` | Command-line interface |
| `App/Sources` | SwiftUI and AppKit app |
| `Tests/DocLensCoreTests` | Core tests |
| `SPECIFICATIONS.md` | Product specification |
