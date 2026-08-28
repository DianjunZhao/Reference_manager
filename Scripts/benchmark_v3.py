#!/usr/bin/env python3
"""Deterministic local synthetic-library benchmark for the v3 audit contract.

This measures bounded dictionary lookup, link filtering, and JSON projection on
synthetic metadata only. It never reads the user's library or creates PDFs.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import resource
import sys
import time
from pathlib import Path


def timed(fn, repeats: int) -> list[float]:
    values = []
    for _ in range(repeats):
        start = time.perf_counter()
        fn()
        values.append((time.perf_counter() - start) * 1000.0)
    return values


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * p))))
    return round(ordered[index], 3)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="benchmark-v3.json")
    parser.add_argument("--repeats", type=int, default=9)
    args = parser.parse_args()
    counts = {"authors": 2_000, "papers": 20_000, "links": 100_000, "pdfs": 100}
    authors = {i: {"recid": i, "name": f"Synthetic Author {i:04d}"} for i in range(counts["authors"])}
    papers = {i: {"id": i, "title": f"Synthetic hep-lat paper {i:05d}", "citation": i % 37} for i in range(counts["papers"])}
    links = [(i % counts["papers"], i % counts["authors"]) for i in range(counts["links"])]
    pdfs = [{"paper_id": i * 199, "bytes": 2_000_000 + i, "hash": f"synthetic-{i:03d}"} for i in range(counts["pdfs"])]

    def cold_query() -> None:
        # Recreate bounded indexes to model a cold open/query path.
        index = {}
        for paper_id, author_id in links:
            index.setdefault(author_id, []).append(paper_id)
        _ = sorted(set(index.get(363, [])))[:100]

    def warm_query() -> None:
        _ = [paper_id for paper_id, author_id in links if author_id == 363][:100]

    def projection() -> None:
        _ = json.dumps({"authors": list(authors.values())[:20], "papers": list(papers.values())[:200], "pdfs": pdfs}, separators=(",", ":"))

    cold = timed(cold_query, max(1, args.repeats))
    warm = timed(warm_query, max(1, args.repeats))
    projected = timed(projection, max(1, args.repeats))
    result = {
        "schema": "v3-large-library-benchmark-1",
        "status": "passed",
        "synthetic_only": True,
        "counts": counts,
        "parameters": {"repeats": max(1, args.repeats), "query": "author_recid=363, max_results=100", "pdf_bytes_mode": "metadata-only"},
        "hardware": {"machine": platform.machine(), "system": platform.system(), "release": platform.release(), "python": platform.python_version()},
        "metrics_ms": {
            "cold_query": {"p50": percentile(cold, 0.50), "p95": percentile(cold, 0.95), "samples": [round(x, 3) for x in cold]},
            "warm_query": {"p50": percentile(warm, 0.50), "p95": percentile(warm, 0.95), "samples": [round(x, 3) for x in warm]},
            "projection": {"p50": percentile(projected, 0.50), "p95": percentile(projected, 0.95), "samples": [round(x, 3) for x in projected]},
        },
        "peak_rss_kb": int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 if sys.platform == "darwin" else 1)),
        "notes": ["Synthetic benchmark is not a claim about a user's database or GPU/CloudKit runtime.", "No raw PDF bytes were generated or persisted."],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "output": str(output), "cold_p95_ms": result["metrics_ms"]["cold_query"]["p95"], "warm_p95_ms": result["metrics_ms"]["warm_query"]["p95"], "peak_rss_kb": result["peak_rss_kb"]}, sort_keys=True))


if __name__ == "__main__":
    main()
