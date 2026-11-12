"""Preserve complete native logs while reporting bounded progress to CI."""
import argparse
from pathlib import Path
import subprocess
import sys
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A native command is required")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding="utf-8", errors="replace", bufsize=1)

    def capture():
        with args.log.open("w", encoding="utf-8") as output:
            for line in process.stdout:
                output.write(line)
                output.flush()
                if any(marker in line for marker in ("error:", "** TEST", "** BUILD", "Test Suite", "Executed ", "failed", "passed")):
                    print(line.rstrip(), flush=True)

    reader = threading.Thread(target=capture, daemon=True)
    reader.start()
    while True:
        try:
            code = process.wait(timeout=60)
            break
        except subprocess.TimeoutExpired:
            print(f"Native check running: {int(time.monotonic() - started)}s; full log: {args.log}", flush=True)
            if sys.platform == "darwin":
                status = subprocess.run(["ps", "-axo", "pid,pcpu,rss,comm"], capture_output=True, text=True)
                rows = [line.split(maxsplit=3) for line in status.stdout.splitlines()[1:]]
                rows = [row for row in rows if len(row) == 4]
                for row in sorted(rows, key=lambda row: float(row[1]), reverse=True)[:5]:
                    print("CPU/RSS process: " + " ".join(row), flush=True)
    reader.join(timeout=10)
    print(f"Native command exited {code}; full log: {args.log}", flush=True)
    if code:
        print("\n".join(args.log.read_text(encoding="utf-8").splitlines()[-60:]), flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
