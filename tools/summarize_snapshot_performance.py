"""Summarize the checked-in before/after snapshot benchmark artifacts."""
from __future__ import annotations

import json
import statistics
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "build/snapshot-performance-20261002"


def samples(path: Path) -> dict[tuple[str, int], list[float]]:
    result: dict[tuple[str, int], list[float]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("SNAPSHOT_SAMPLE,"):
            continue
        fields = dict(item.split("=", 1) for item in line.split(",")[1:])
        key = (fields["scenario"], int(fields["n"]))
        result.setdefault(key, []).append(float(fields["elapsedCpuMs"]))
    return result


def summarize(values: list[float]) -> dict[str, float | int]:
    return {
        "samples": len(values),
        "medianCpuMs": statistics.median(values),
        "p95CpuMs": statistics.quantiles(values, n=20, method="inclusive")[18],
        "minCpuMs": min(values),
        "maxCpuMs": max(values),
    }


def main() -> None:
    before = samples(ARTIFACTS / "before/benchmark.txt")
    after = samples(ARTIFACTS / "after/benchmark.txt")
    rows = []
    for key in sorted(before, key=lambda item: (item[1], item[0])):
        before_stats = summarize(before[key])
        after_stats = summarize(after[key])
        rows.append(
            {
                "scenario": key[0],
                "n": key[1],
                "before": before_stats,
                "after": after_stats,
                "medianSpeedup": before_stats["medianCpuMs"] / after_stats["medianCpuMs"],
                "p95Speedup": before_stats["p95CpuMs"] / after_stats["p95CpuMs"],
            }
        )
    canonical_equal = (ARTIFACTS / "before/canonical.txt").read_bytes() == (ARTIFACTS / "after/canonical.txt").read_bytes()
    payload = {
        "metric": "Luau os.clock CPU milliseconds per Model.snapshot call",
        "warmups": 10,
        "samplesPerCase": 20,
        "canonicalSnapshotOutputEqual": canonical_equal,
        "rows": rows,
    }
    output = ARTIFACTS / "summary.json"
    output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(output)
    print(json.dumps(payload, indent=2))
    if not canonical_equal:
        raise SystemExit("before/after canonical snapshot output differs")


if __name__ == "__main__":
    main()
