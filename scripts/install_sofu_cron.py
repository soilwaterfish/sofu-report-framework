#!/usr/bin/env python3
"""Install SOFU's locked two-hour schedule while retaining other cron jobs."""
from datetime import datetime
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BEGIN = "# BEGIN SOFU scheduled refresh"
END = "# END SOFU scheduled refresh"


def updated_crontab(current, root=ROOT):
    lines = []
    inside = False
    for line in current.splitlines():
        if line == BEGIN:
            inside = True
            continue
        if line == END:
            inside = False
            continue
        if inside:
            continue
        # Replace this repository's old daily compose job only.
        if str(root) in line and "docker compose run" in line and "sofureport-job" in line:
            continue
        lines.append(line)
    runner = f"/bin/bash {root}/scripts/run_scheduled_cron.sh"
    log = f" >> {root}/logs/cron.log 2>&1"
    while lines and not lines[-1].strip():
        lines.pop()
    lines.extend(["", BEGIN, "CRON_TZ=America/Denver",
        f"15 0,2,4,8,10,12,14,16,20,22 * * * {runner} frequent{log}",
        f"15 6,18 * * * {runner} full{log}", END])
    return "\n".join(lines).strip() + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Install after saving a backup; otherwise print proposed cron.")
    args = parser.parse_args()
    result = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    if result.returncode and "no crontab" not in result.stderr.lower():
        raise SystemExit(result.stderr)
    current = result.stdout
    updated = updated_crontab(current)
    if args.install:
        backup = ROOT / "logs" / f"crontab-before-{datetime.now():%Y%m%d-%H%M%S}.txt"
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_text(current)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".cron") as proposal:
            proposal.write(updated)
            proposal.flush()
            subprocess.run(["crontab", proposal.name], check=True)
        print(f"SOFU schedule installed. Previous crontab: {backup}")
    else:
        print(updated, end="")
