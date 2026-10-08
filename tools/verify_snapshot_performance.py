"""Static call-shape guard for the Model.snapshot sale-factor optimization.

This is deliberately source-structural: it proves that the snapshot loop has
one shared factor and no per-fish salePrice call without adding a production
counter, debug flag, or alternate runtime behavior.
"""
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "fishing/src/shared/Model.luau"


def section(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish]


def main() -> None:
    source = MODEL.read_text(encoding="utf-8")
    copy_body = section(source, "local function copyFish(", "local function safeRandom")
    snapshot_body = section(source, "function Model.snapshot(", "return Model")

    checks = {
        "copyFish accepts shared factor": "saleMultiplier" in source[source.index("local function copyFish(") : source.index("local function safeRandom")],
        "snapshot computes one factor": snapshot_body.count("coinMultiplier(profile, now)") == 1,
        "snapshot passes shared factor": "copyFish(item, profile, now, saleMultiplier)" in snapshot_body,
        "snapshot does not call salePrice": "Model.salePrice(" not in snapshot_body,
        "copyFish keeps command fallback": "Model.salePrice(profile, fish, now)" in copy_body,
        "public sale formula remains": "return fish.value * coinMultiplier(profile, now)" in source,
    }
    failed = [name for name, passed in checks.items() if not passed]
    for name, passed in checks.items():
        print(f"SNAPSHOT_STRUCTURE,{name}={'PASS' if passed else 'FAIL'}")
    if failed:
        raise SystemExit("snapshot structure guard failed: " + ", ".join(failed))
    print("SNAPSHOT_STRUCTURE_DONE")


if __name__ == "__main__":
    main()
