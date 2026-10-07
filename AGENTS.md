# DocLens project context

## Purpose and architecture

DocLens is a proposed native macOS application for extracting PDF tables into editable datasets with source evidence, corrections, and export.

Read `SPECIFICATIONS.md` before starting development. It is the current product specification.

Proposed architecture: SwiftUI interface, PDFKit viewer, Swift application services, SQLite persistence, immutable source PDFs, and an extraction adapter. Evaluate a separate Docling Python worker against Apple Vision before selecting the primary engine. The application owns database writes.

## Current status and recent changes

- October 7, 2026: created the project directory, `SPECIFICATIONS.md`, and this context file.
- The repository contains planning documents only. There is no application code, build system, dependency installation, or Git repository yet.
- The specification covers the product idea, initial scope, review behavior, architecture, data provenance, exports, evaluation, acceptance criteria, and implementation stages.

## Run, build, and test

No run, build, or test commands exist yet. Do not invent commands or report application checks as completed.

After selecting the engine and creating the application, replace this section with the actual setup, run, build, and focused validation commands.

## Project preferences and constraints

- Write source code, identifiers, UI copy, documentation, and metadata in English.
- Do not use em dashes in any authored text.
- Keep the interface native, minimal, spacious, and usable with the keyboard.
- Keep document processing local and usable offline after explicit resource installation.
- Preserve original PDFs, extracted text, and user corrections separately.
- Keep source references, automatic checks, and user review as distinct concepts.
- Record engine versions and configuration so extraction results can be reproduced.
- Confirm important unresolved product or implementation choices before material changes.
- Update this file after meaningful work and tell the user exactly what changed.
- If GitHub work is requested, use Zer0codestuff as the sole commit author and follow the user's branch and pull-request workflow.

## Known issues and next steps

The primary engine, supported layouts, minimum macOS version, packaging approach, project file format, and quality thresholds are unresolved. No extraction accuracy or performance has been measured.

Start with a small annotated PDF corpus and compare Docling with Apple Vision. Use the results to choose the engine and supported scope, then implement the single-page extraction and review workflow.

## Do not

- Do not implement the application or install dependencies solely to fulfill the documentation request that created this directory.
- Do not invent extracted values, source highlights, benchmark results, or calibrated confidence percentages.
- Do not mark data as user-reviewed because an automatic check passed.
- Do not overwrite source documents or silently discard corrections during re-extraction.
- Do not add cloud processing, accounts, document chat, or model training to the first release without an agreed scope change.
- Do not require end users to install Python manually for a packaged application.
- Do not publish, create a remote repository, or deploy the project without a user request.
