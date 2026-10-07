# Docling compared with the built-in engines

Measured October 7, 2026 on a Mac16,1 (Apple M4, 16 GB), macOS 27.0, with Docling 2.135.0 on Python 3.12.14 and PyTorch 2.14.1 (CPU). The corpus is the 13 synthetic documents from `doclens corpus`, the same corpus used in `benchmark.md`. Raw results are in `benchmark.md` and `benchmark-docling.md`.

The corpus is synthetic. These numbers compare engines on known layout features. They are not accuracy claims for real reports.

## Exact cell accuracy

| Document | Text layer | Vision OCR | Vision Document | Automatic | Docling |
|---|---|---|---|---|---|
| 01 grid, point decimal | 100.0% | 96.9% | 98.5% | 100.0% | 100.0% |
| 02 borderless, comma decimal | 100.0% | 40.0% | 98.5% | 100.0% | 100.0% |
| 03 booktabs, missing values | 100.0% | 44.2% | 72.1% | 100.0% | 46.7% |
| 04 rotated landscape | 100.0% | 97.8% | 95.6% | 100.0% | no table found |
| 05 multipage, repeated header | 100.0% | 86.8% | 59.0% | 100.0% | 51.1% |
| 06 scanned grid | n/a | 95.4% | 90.8% | 90.8% | 100.0% |
| 07 scanned borderless | n/a | 40.0% | 93.8% | 93.8% | 100.0% |
| 08 financial statement | 100.0% | 35.7% | 96.4% | 100.0% | 100.0% |
| 09 dense dates | 100.0% | 42.9% | 83.4% | 100.0% | 100.0% |
| 10 spanning header | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% |
| 11 wrapped cells | 100.0% | 57.1% | 50.0% | 100.0% | 57.1% |
| 12 space grouping, French | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% |
| 13 scanned, low resolution | n/a | 65.1% | 65.1% | 65.1% | 81.4% |

## Cost

| | Built-in engines | Docling |
|---|---|---|
| Median latency per table | 0.04 s (text layer), 0.21 s (Vision Document) | 7.5 s, with a new worker per table (converter setup alone takes about 2 s) |
| Slow outliers | Vision OCR took 30 s and 14 s on two early documents, probably model loading | 68 s on the first document, including model download |
| Peak memory | 22 MB (text layer), up to 111 MB (Vision) | 1.5 GB digital page, 2.7 GB scanned page |
| Disk | None beyond the app | 1.2 GB Python environment, 1.0 GB Docling models, 62 MB OCR models |
| Packaging | Part of macOS | Requires bundling Python, PyTorch, and models |

Docling's peak memory was measured with `/usr/bin/time -l` on a direct conversion, because the benchmark's memory column does not reliably include the worker process.

## Findings

- On digital PDFs the text layer is exact on every document and close to 200 times faster than Docling. Docling adds nothing there and fails on the rotated page, the booktabs table, the multipage table, and wrapped cells.
- On scans Docling is clearly better: 100% on both regular scans and 81.4% on the low-resolution scan, against 90.8%, 93.8%, and 65.1% for Vision Document.
- Docling costs one to two orders of magnitude more memory and latency, and shipping it means bundling a Python runtime and about 2 GB of packages and models.

## Decision

The primary engine is `Automatic`: the PDF text layer when the region has readable text, Vision Document Structure otherwise. Docling stays an optional external engine, selectable per table, for scans where Vision makes mistakes. It is not bundled.

Revisit this if real scanned reports show the same gap. A bundled Docling worker, or a scan-only fallback to it, would then be worth its packaging cost.
