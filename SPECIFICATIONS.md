# DocLens

Project specification, October 7, 2026.

Status: product definition. No application code has been created.

## Product idea

DocLens is a native macOS application that turns PDF tables into editable, reusable datasets. It keeps a visible connection between extracted values and their source, so users can find mistakes, correct them, and export data they have reviewed.

The first audience is people who repeatedly extract tables from administrative and statistical reports: researchers, analysts, and small teams maintaining datasets.

The product should reduce the total time from receiving a PDF to obtaining a correct dataset, including review and corrections. Extraction alone is insufficient: existing tools already perform it. DocLens should make the remaining work easier through source inspection, explicit data types, correction history, and reusable extraction recipes.

### Example workflow

An analyst receives a monthly report containing a table spread across three pages. The table repeats its headers, uses commas as decimal separators, and includes codes with leading zeros.

1. Import the report and select the relevant pages or table region.
2. Extract the table and inspect it next to the PDF.
3. Select an ambiguous value to highlight its source.
4. Correct the value, confirm its type, and resolve flagged issues.
5. Export a spreadsheet with source references and correction history.
6. Save a recipe and apply it to the next report, reviewing any layout changes.

Steps 1 through 5 belong to the first useful release. Multipage joins and reusable recipes follow once the basic review workflow works reliably.

## Product principles

- Process documents locally, with offline operation after any required model installation.
- Preserve original documents, original extracted text, and user corrections separately.
- Make source inspection a primary interaction.
- Show uncertainty and missing evidence explicitly.
- Keep automatic checks separate from user review.
- Preserve identifiers, units, decimal precision, and missing-value semantics.
- Prefer a small workflow that users can complete over a broad set of partially supported document types.

## First release

The first release supports one selected table from one PDF page at a time. It should work with both readable digital PDFs and a documented set of scanned PDFs. Engine evaluation will determine the supported scan quality and layouts.

### Required capabilities

| Area | Requirement |
| --- | --- |
| Import | Open a local PDF, retain an immutable copy, and compute its SHA-256 hash. |
| Selection | Choose a page and select a table or rectangular extraction region. |
| Extraction | Recover rows, columns, text, and available source regions. Use usable native text when appropriate and OCR when required. |
| Review | Display the PDF beside an editable table. Selecting a cell highlights its source when available. |
| Editing | Edit values and column types, distinguish empty cells from zero, and support undo and redo. |
| Normalization | Apply explicit locale and unit settings. Preserve leading zeros in identifier columns. Flag ambiguous conversions. |
| Checks | Flag missing evidence, conversion failures, inconsistent row structure, and applicable data checks. |
| Persistence | Save and reopen a project with its source, extraction, edits, and review state intact. |
| Export | Export CSV, XLSX, and a JSON representation containing provenance. |
| Job control | Show progress, cancel extraction, and report actionable failures without freezing the interface. |

### Outside the first release

- General document chat, question answering, or document summarization.
- Receipt and form processing.
- Automatic extraction from every table in an arbitrary report.
- User accounts, cloud synchronization, collaboration, and hosted processing.
- Model training or fine-tuning.
- Windows, Linux, and mobile clients.

These are deferred possibilities, not requirements for shipping the initial product.

## Interface and review behavior

Use a native SwiftUI interface with the PDF on the left and the data table on the right. The user should be able to resize both panes and navigate a table with the keyboard. Keep extraction, issue navigation, and export controls in a compact toolbar.

Selecting a cell should navigate to its source page and show the relevant region or regions. Selecting a mapped region in the PDF should select the corresponding cell. If the engine provides no reliable source region, display that limitation instead of creating an approximate highlight that appears authoritative.

Track three independent concepts:

- Extraction result: original output and extraction method.
- Automatic checks: passed, failed, or not applicable, with a reason.
- User review: unreviewed, needs review, or reviewed by the user.

A passed check must not mark a value as reviewed. An engine score must not be presented as a calibrated probability of correctness without supporting evaluation. Editing a reviewed value should require reviewing it again.

Support light and dark appearance, accessible labels, keyboard operation, and readable focus states. Render visible PDF pages and table rows incrementally so large documents do not require rendering everything at once.

## Proposed architecture

The architecture below is the starting proposal. Extraction quality, packaging, and hardware measurements should settle the engine choice before implementation expands.

```text
SwiftUI application
    |
    +-- PDFKit viewer through a small AppKit bridge
    +-- Editable table and review controls
    +-- Application services and validation rules
    +-- SQLite project store and immutable source files
    |
    +-- Extraction adapter
            |
            +-- Python worker using Docling
            +-- Apple Vision adapter for comparison
```

### Application layer

SwiftUI owns the interface and application state. PDFKit handles PDF display. A Swift application layer owns persistence, review history, validation, and export.

The application is the only writer to the project database. Extraction engines return results through an adapter and do not modify the database directly.

### Extraction engines

Evaluate Docling as the initial baseline and Apple Vision document recognition as a native alternative. Compare their table structure, text accuracy, source mapping, latency, memory use, and distribution requirements on the same documents.

If Docling is selected, run it in a separate Python process. Use versioned JSON messages over standard input and standard output, with diagnostic logs on standard error. Messages should include job identifiers, progress, partial results where useful, cancellation, completion, and structured errors.

Bundle a compatible runtime for the distributed application. End users should not need to install Python or run pip. Pin model and package versions, record checksums, and document model storage. Network access for initial model installation must be explicit; ordinary document processing should work offline.

Keep engine-specific output behind the adapter. Do not expose raw parser objects as the application's data model.

### Storage

Store project metadata, tables, cells, review state, recipes, and correction history in SQLite. Keep source PDFs as immutable files in the project storage directory.

Record the document hash, engine version, configuration, and extraction time. Re-extraction creates a new result version and must not overwrite user corrections silently.

## Data and provenance model

The canonical representation must be independent of the extraction engine.

| Entity | Required information |
| --- | --- |
| Document | Stable ID, original filename, SHA-256 hash, page metadata, immutable source location. |
| Extraction run | Stable ID, engine and model versions, configuration, timestamps, status, errors. |
| Table | Stable ID, source pages, row and column structure, header associations, extraction run. |
| Cell | Stable ID, row and column indices, spans, original text, normalized value, type, source references, review state. |
| Source reference | Document ID, page index, one or more regions or token spans, coordinate convention, mapping method. |
| Transformation | Input value, output value, operation, locale or units where relevant, and originating cell IDs. |
| Correction | Cell ID, before and after values, timestamp, review action, and affected extraction version. |
| Check result | Rule ID and version, status, affected cells, explanation, and applicable tolerance. |

Use decimal-safe values for numeric data. Keep raw text available after normalization and editing. A code such as `00124` must remain an identifier unless the user explicitly changes its type.

Distinguish missing values, literal dashes, empty strings, and zero. Do not infer a missing number from surrounding values or totals. Derived values must carry their calculation and inputs, and must not appear as text found in the source.

Define and test coordinate conversion between PDF points, image pixels, page rotation, crop boxes, and any normalized engine coordinates. A cell may have several source regions. Preserve this information rather than reducing every cell to one rectangle.

## Validation rules

Start with explicit, inspectable rules:

- Type conversion failures and ambiguous numeric formats.
- Unexpected row widths or missing cells.
- Missing or unusable source references.
- Unexpected changes to a declared schema.
- Duplicate rows introduced by table joining in later releases.
- Totals and subtotals only when their relationship, scope, units, and rounding tolerance are defined.

A matching total does not prove that all values were extracted correctly. The interface must show what each check tested and allow the user to inspect the affected cells.

## Export contract

- CSV contains the selected data table with an explicit delimiter, encoding, and numeric-format policy.
- XLSX contains `Data`, `Sources`, and `Corrections` sheets. Source entries identify the document, page, cell, and available regions.
- JSON contains the full canonical representation, schema version, extraction metadata, transformations, checks, review state, and corrections.
- CSV and XLSX exports should also offer a JSON provenance sidecar, since standalone tabular files cannot preserve every source relationship.
- Export should disclose unresolved issues and unreviewed cells. A user may deliberately export them, but they must not be labeled as reviewed.
- Exported spreadsheets must preserve identifier strings and handle source text safely rather than treating arbitrary document text as spreadsheet formulas.

## Recurring-document workflow

After the first release, add multipage table joining and versioned extraction recipes.

A recipe records the target schema, header aliases, column types, locale, units, extraction anchors, region hints, transformations, and validation rules. Prefer text and structural anchors over fixed coordinates alone.

When a new document differs from the saved layout or schema, require inspection of the mapping. Do not silently assign values to the wrong columns. Repeated headers, continuation rows, footnotes, and page breaks need explicit handling.

Batch processing should use a cancellable queue. Cache results by source hash, engine version, and configuration. Preserve completed work after a failure and keep review history independent of cached extraction output.

## Optional local AI

Add model assistance only when a measured recurring error justifies it. Suitable tasks include suggesting header aliases, mapping a table to a saved schema, or proposing a join between two table sections.

Suggestions must point to supporting document content and require review when ambiguous. Models must not invent missing cells or silently change values.

Local fine-tuning is a later experiment. Collect approved corrections, obtain explicit consent for any dataset export, and split evaluation by document family or publisher. Pages from the same document must not appear in both training and test sets.

Compare an unchanged extraction engine, deterministic rules, a general model, and any tuned model. Keep the simpler approach if the tuned model does not improve the relevant outcome.

## Evaluation and usefulness

Build an initial corpus of about 20 representative PDFs with manually annotated tables. Include digital and scanned documents, borderless tables, decimal conventions, leading-zero identifiers, rotated pages, and multipage examples. The first release may support a narrower subset, but unsupported cases should remain visible in the evaluation.

Measure:

- Exact cell accuracy, numeric accuracy, and missing or duplicated rows and columns.
- Accuracy and coverage of source-region mapping.
- Schema mapping and table joining errors where supported.
- Total time to produce a reviewed, correct export, including corrections.
- Extraction latency, peak memory, disk use, interface responsiveness, and cancellation latency.

Compare the complete workflow with the user's existing manual or Tabula-assisted process. Test recurring use with three to five people who already extract tables from real reports. Record their task time and errors on a fresh document, not only their reaction to a demonstration.

Use an Apple Silicon Mac as the primary development target. An M4 machine with 16 GB of memory is a proposed reference configuration, subject to confirming available hardware. Set performance thresholds after the first measurements; do not claim results before measuring them.

## First-release acceptance criteria

1. A packaged application can import a PDF and complete the supported extraction workflow without a system Python installation.
2. After required resources are installed, extraction and review work with network access disabled.
3. Every exported cell retains a source reference or an explicit indication that source evidence is unavailable.
4. The evaluation corpus includes checks for leading zeros, decimal conversion, missing values, rotated pages, and source highlighting.
5. Editing and undoing a value preserve the original extraction and correction history.
6. Saving and reopening a project preserves its source, values, checks, and review state.
7. Cancellation and worker failure leave the application usable and do not corrupt saved work.
8. CSV, XLSX, and JSON exports agree on the selected values and disclose unresolved review status.
9. A published evaluation reports observed accuracy, task time, hardware, software versions, and known failure cases.

Quality targets for supported layouts must be set after the initial baseline evaluation and before declaring the release ready.

## Implementation stages

| Stage | Deliverable | Completion condition |
| --- | --- | --- |
| 1. Engine evaluation | Annotated corpus, reproducible benchmark, Docling and Vision comparison. | Choose an engine and supported layouts using measured results. |
| 2. First useful application | Single-page extraction, source review, editing, persistence, and export. | Complete the first-release acceptance criteria on the supported corpus. |
| 3. Recurring use | Multipage joins, recipes, batch queue, and recovery. | Process a new report with a saved recipe and expose layout changes correctly. |
| 4. Model experiments | Optional local suggestions and correction-based evaluation. | Demonstrate an improvement over the existing workflow on held-out documents. |

## Portfolio deliverables

The project should produce an installable macOS application, a reproducible extraction benchmark, a redistributable sample corpus where permissions allow, and a case study showing actual before-and-after task time and failure cases.

A command-line entry point to the same extraction adapter can make the project useful in data pipelines after the application workflow is established. Keep the benchmark runnable independently of the interface.

## Decisions to resolve before application development

- Primary extraction engine and supported PDF layouts.
- Minimum macOS version required by the selected APIs.
- Python runtime packaging and model distribution, if needed.
- Project file format and storage location.
- Measured quality and performance thresholds.
- Sample-document redistribution rights and the first pilot workflow.

## Technical references

These references informed the proposed design. Recheck API availability and package versions during implementation.

- [Tabula](https://tabula.technology/): existing table extraction workflow for comparison.
- [Docling documentation](https://docling-project.github.io/docling/): extraction, OCR, and table processing.
- [Docling document model](https://docling-project.github.io/docling/concepts/docling_document/): structured representation and available provenance.
- [Docling advanced options](https://docling-project.github.io/docling/usage/advanced_options/): model storage and processing configuration.
- [Docling confidence scores](https://docling-project.github.io/docling/concepts/confidence_scores/): score definitions and limitations.
- [Apple document recognition](https://developer.apple.com/videos/play/wwdc2025/272/): native structured-document recognition.
- [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest): API reference and availability.
