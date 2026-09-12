"""Compile and run the real Dart merger in AOT mode; Python standard library only."""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys


APP = Path(__file__).resolve().parents[2]


def run(command, cwd=APP):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    if result.returncode:
        raise RuntimeError(f"Command failed: {command[0]}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def revision(path):
    if not (path / ".git").exists():
        return {"available": False}
    return {"available": True, "head": run(["git", "rev-parse", "HEAD"], path),
            "status": run(["git", "status", "--porcelain"], path)}


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", default=shutil.which("dart"))
    parser.add_argument("--iterations", type=positive, default=100)
    parser.add_argument("--samples", type=positive, default=5)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.dart:
        parser.error("Dart SDK not found; pass --dart")
    dart = Path(args.dart).resolve()
    # Use the SDK binary directly; no shell interpolation of paths or arguments.
    if dart.suffix.lower() == ".bat":
        dart = dart.parent / "cache/dart-sdk/bin/dart.exe"
    if not dart.is_file():
        parser.error("Dart executable not found; pass --dart pointing to the SDK binary")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output or APP / "build/performance" / stamp).resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest_path = output / "manifest.json"
    manifest = {
        "schema_version": 1, "started_utc": stamp, "status": "running",
        "scope": "synthetic Dart merger only; not VPN CPU or Android energy",
        "mode": "Dart AOT executable", "platform": platform.platform(),
        "machine": platform.machine(), "processor": platform.processor(),
        "python": platform.python_version(), "iterations": args.iterations,
        "samples": args.samples, "warmup_merges_per_scenario": 20,
        "scenario_order": ["single", "disjoint", "overlap", "detours"],
        "node_counts_per_profile": [10, 100, 1000],
    }

    def save():
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    save()
    try:
        manifest["dart"] = run([str(dart), "--version"])
        manifest["repositories"] = {name: revision(APP if name == "hiddify-app" else APP.parent / name)
                                    for name in ("hiddify-app", "hiddify-core", "hiddify-sing-box")}
        paths = ["tool/performance/merge_benchmark.dart", "tool/performance/run_baseline.py",
                 "lib/features/auto_group/data/auto_group_merger.dart", "dependencies.properties"]
        manifest["sha256"] = {p: hashlib.sha256((APP / p).read_bytes()).hexdigest() for p in paths}
        manifest["declared_android_core"] = (APP / "dependencies.properties").read_text().strip()
        manifest["local_core_matches_android_artifact"] = "unverified; core is not executed by this benchmark"
        save()
        exe = output / ("merge_benchmark.exe" if sys.platform == "win32" else "merge_benchmark")
        compile_command = [str(dart), "compile", "exe", str(APP / paths[0]), "-o", str(exe)]
        (output / "compile.log").write_text(run(compile_command) + "\n", encoding="utf-8")
        rows = []
        with (output / "samples.jsonl").open("w", encoding="utf-8") as raw:
            for nodes in manifest["node_counts_per_profile"]:
                for scenario in manifest["scenario_order"]:
                    payload = run([str(exe), scenario, str(nodes), str(args.iterations), str(args.samples)])
                    raw.write(payload + "\n")
                    raw.flush()
                    measurements = [json.loads(line) for line in payload.splitlines()]
                    if len(measurements) != args.samples:
                        raise RuntimeError("Unexpected number of samples")
                    timings = [m["us_per_merge"] for m in measurements]
                    rows.append({"scenario": scenario, "nodes_per_profile": nodes,
                                 "profiles": measurements[0]["profiles"],
                                 "output_nodes": measurements[0]["output_nodes"],
                                 "samples": args.samples, "iterations_per_sample": args.iterations,
                                 "median_us_per_merge": statistics.median(timings),
                                 "min_us_per_merge": min(timings), "max_us_per_merge": max(timings),
                                 "max_rss_after_validation_bytes": max(m["rss_after_validation_bytes"] for m in measurements)})
                    print(f"{scenario:8} {nodes:4}: {statistics.median(timings):.1f} us/merge", flush=True)
        with (output / "summary.csv").open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        manifest["status"] = "complete"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["finished_utc"] = datetime.now(timezone.utc).isoformat()
        save()
    print(f"Results: {output}")


if __name__ == "__main__":
    main()
