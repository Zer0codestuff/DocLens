#!/usr/bin/env python3
"""DocLens Docling worker.

Reads one JSON request per line on standard input and writes JSON messages, one per line, on
standard output. Diagnostics go to standard error. The worker never touches the DocLens
database; the application owns all writes.

Protocol version 1

Requests:
  {"protocol": 1, "type": "hello"}
  {"protocol": 1, "type": "extract", "job": "<id>", "pdf": "<path>", "page": <0-based>,
   "region": {"x": .., "y": .., "width": .., "height": ..}}   # display points, lower-left origin

Responses:
  {"type": "hello", "protocol": 1, "worker": "<version>", "python": "<version>", "docling": "<version>|null"}
  {"type": "progress", "job": "<id>", "fraction": 0.0-1.0, "message": "..."}
  {"type": "result", "job": "<id>", "engine": {...}, "table": {"rowCount": n, "columnCount": n, "cells": [...]}}
  {"type": "error", "job": "<id>", "code": "<code>", "message": "..."}

Each cell: {"row", "column", "rowSpan", "colSpan", "text", "header": bool,
            "bbox": {"l", "b", "r", "t"} | null}   # display points, lower-left origin
"""

import json
import platform
import sys
import traceback

WORKER_VERSION = "1.0.0"
PROTOCOL = 1


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def docling_version():
    try:
        from importlib.metadata import version

        return version("docling")
    except Exception:
        return None


def overlap(a, b):
    left = max(a["l"], b["l"])
    right = min(a["r"], b["r"])
    bottom = max(a["b"], b["b"])
    top = min(a["t"], b["t"])
    if right <= left or top <= bottom:
        return 0.0
    return (right - left) * (top - bottom)


def extract(request):
    job = request.get("job", "")
    version = docling_version()
    if version is None:
        send({"type": "error", "job": job, "code": "docling-missing",
              "message": "Docling is not installed for this Python interpreter. Run: python3 -m pip install docling"})
        return

    send({"type": "progress", "job": job, "fraction": 0.05, "message": "Loading Docling"})
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption

    page_no = int(request["page"]) + 1
    options = PdfPipelineOptions()
    options.do_table_structure = True
    options.do_ocr = bool(request.get("options", {}).get("ocr", True))
    converter = DocumentConverter(format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=options)})

    send({"type": "progress", "job": job, "fraction": 0.2, "message": "Converting page %d" % page_no})
    result = converter.convert(request["pdf"], page_range=(page_no, page_no))
    doc = result.document

    region = request.get("region")
    target = None
    if region:
        target = {"l": region["x"], "b": region["y"], "r": region["x"] + region["width"], "t": region["y"] + region["height"]}

    best = None
    best_score = -1.0
    for table in doc.tables:
        prov = next((p for p in table.prov if p.page_no == page_no), None)
        if prov is None:
            continue
        page_height = doc.pages[page_no].size.height
        bbox = prov.bbox.to_bottom_left_origin(page_height=page_height)
        box = {"l": bbox.l, "b": bbox.b, "r": bbox.r, "t": bbox.t}
        score = overlap(box, target) if target else (box["r"] - box["l"]) * (box["t"] - box["b"])
        if score > best_score:
            best, best_score = (table, page_height), score

    if best is None or (target is not None and best_score <= 0):
        send({"type": "error", "job": job, "code": "no-table", "message": "Docling found no table in the selected region."})
        return

    table, page_height = best
    cells = []
    for cell in table.data.table_cells:
        bbox = None
        if cell.bbox is not None:
            b = cell.bbox.to_bottom_left_origin(page_height=page_height)
            bbox = {"l": b.l, "b": b.b, "r": b.r, "t": b.t}
        cells.append({
            "row": cell.start_row_offset_idx,
            "column": cell.start_col_offset_idx,
            "rowSpan": max(1, cell.end_row_offset_idx - cell.start_row_offset_idx),
            "colSpan": max(1, cell.end_col_offset_idx - cell.start_col_offset_idx),
            "text": cell.text,
            "header": bool(cell.column_header),
            "bbox": bbox,
        })
    send({
        "type": "result",
        "job": job,
        "engine": {"docling": version, "worker": WORKER_VERSION, "python": platform.python_version(),
                   "ocr": str(options.do_ocr)},
        "table": {"rowCount": table.data.num_rows, "columnCount": table.data.num_cols, "cells": cells},
    })


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as error:
            send({"type": "error", "job": "", "code": "bad-request", "message": str(error)})
            continue
        if request.get("protocol") != PROTOCOL:
            send({"type": "error", "job": request.get("job", ""), "code": "protocol",
                  "message": "Unsupported protocol version %r" % request.get("protocol")})
            continue
        kind = request.get("type")
        if kind == "hello":
            send({"type": "hello", "protocol": PROTOCOL, "worker": WORKER_VERSION,
                  "python": platform.python_version(), "docling": docling_version()})
        elif kind == "extract":
            try:
                extract(request)
            except Exception as error:
                log(traceback.format_exc())
                send({"type": "error", "job": request.get("job", ""), "code": "exception", "message": str(error)})
        elif kind == "shutdown":
            return
        else:
            send({"type": "error", "job": request.get("job", ""), "code": "unknown-type", "message": str(kind)})


if __name__ == "__main__":
    main()
