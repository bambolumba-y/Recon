"""Run the sing-box balancer scenario tests and collect their results; stdlib only."""

import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys


APP = Path(__file__).resolve().parents[2]

# The three controller-level scenario tests in protocol/group/balancer/scenario_test.go,
# in source order. Used to name a scenario whose test failed before it could print its
# SCENARIO line (see the README section on this script).
TEST_SCENARIO_NAMES = {
    "TestScenarioDialErrorRecovery": "dial_error_with_candidates",
    "TestScenarioAllUnknownRescue": "rescue_unknown_pool",
    "TestScenarioLatencyFlapDoesNotSwitch": "latency_jitter_24h",
}

SCENARIO_LINE = re.compile(
    r"SCENARIO name=(?P<name>\S+) probes=(?P<probes>\d+) "
    r"switches=(?P<switches>\d+) recovery_ms=(?P<recovery_ms>\d+)"
)

GO_TEST_ARGS = ["test", "./protocol/group/balancer/", "-run", "TestScenario", "-v", "-count=1", "-json"]
COMMAND_DISPLAY = "go test ./protocol/group/balancer/ -run 'TestScenario' -v -count=1 -json"


def run(command, cwd):
    result = subprocess.run(command, cwd=cwd, capture_output=True,
                            encoding="utf-8", errors="replace", shell=False)
    if result.returncode:
        raise RuntimeError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def parse_scenario_output(stdout):
    """Parse `go test -json` stdout into (test_order, scenario_by_test, status_by_test)."""
    test_order = []
    scenario_by_test = {}
    status_by_test = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        test = event.get("Test")
        action = event.get("Action")
        if not test or "/" in test:
            continue
        if action == "run" and test not in test_order:
            test_order.append(test)
        elif action == "output":
            match = SCENARIO_LINE.search(event.get("Output", ""))
            if match:
                scenario_by_test[test] = {
                    "scenario": match.group("name"),
                    "probes": int(match.group("probes")),
                    "switches": int(match.group("switches")),
                    "recovery_ms": int(match.group("recovery_ms")),
                }
        elif action in ("pass", "fail"):
            status_by_test[test] = action
    return test_order, scenario_by_test, status_by_test


def build_rows(test_order, scenario_by_test, status_by_test):
    rows = []
    for test in test_order:
        parsed = scenario_by_test.get(test)
        status = status_by_test.get(test, "fail")
        if parsed:
            rows.append({"scenario": parsed["scenario"], "probes": parsed["probes"],
                         "switches": parsed["switches"], "recovery_ms": parsed["recovery_ms"],
                         "status": status})
        else:
            # Test failed (or was aborted) before it reached its t.Logf call.
            rows.append({"scenario": TEST_SCENARIO_NAMES.get(test, test), "probes": "",
                         "switches": "", "recovery_ms": "", "status": status})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--singbox", type=Path, default=APP.parent / "recon-core" / "hiddify-sing-box",
                        help="sing-box workspace path (default: ../recon-core/hiddify-sing-box "
                             "relative to this script's location)")
    parser.add_argument("--out", type=Path, help="results directory (default: "
                        "docs/performance/<UTC date>-go-scenarios)")
    args = parser.parse_args()

    singbox = args.singbox.resolve()
    if not singbox.is_dir():
        parser.error(f"sing-box workspace not found: {singbox}")
    core = singbox.parent

    go_version = run(["go", "version"], cwd=APP)
    singbox_commit = run(["git", "rev-parse", "HEAD"], cwd=singbox)
    core_commit = run(["git", "rev-parse", "HEAD"], cwd=core)
    timestamp_utc = datetime.now(timezone.utc).isoformat(timespec="seconds")

    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    output = (args.out or APP / "docs/performance" / f"{date}-go-scenarios").resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        print(f"Refusing to overwrite existing results directory: {output}", file=sys.stderr)
        sys.exit(1)

    result = subprocess.run(["go"] + GO_TEST_ARGS, cwd=singbox, capture_output=True,
                            encoding="utf-8", errors="replace", shell=False)

    test_order, scenario_by_test, status_by_test = parse_scenario_output(result.stdout)
    rows = build_rows(test_order, scenario_by_test, status_by_test)

    with (output / "summary.csv").open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=["scenario", "probes", "switches", "recovery_ms", "status"])
        writer.writeheader()
        writer.writerows(rows)

    manifest = {
        "go_version": go_version,
        "singbox_commit": singbox_commit,
        "core_commit": core_commit,
        "timestamp_utc": timestamp_utc,
        "command": COMMAND_DISPLAY,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    for row in rows:
        print(f"{row['scenario']:28} {row['status']}")
    print(f"Results: {output}")

    if not rows or any(row["status"] != "pass" for row in rows) or result.returncode:
        sys.exit(1)


if __name__ == "__main__":
    main()
