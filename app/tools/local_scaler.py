"""Local scaler: imitates what KEDA will do in Kubernetes, using plain processes.

Every few seconds it looks at how many jobs are waiting in the queue and starts
worker processes in `once` mode (each takes exactly one job and exits), so that
there is one worker per waiting job, but never more than --max at once.

Run:  python app/tools/local_scaler.py --max 5
Stop: Ctrl+C (running workers put their jobs back on the queue and exit)
"""

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import redis

WORKER_SCRIPT = Path(__file__).resolve().parent.parent / "worker" / "worker.py"


class StopScaler(Exception):
    """Raised by our signal handler; remembers which signal stopped us."""

    def __init__(self, signum: int):
        super().__init__(signal.Signals(signum).name)
        self.signum = signum


def install_signal_handlers() -> None:
    # Handle both explicitly: a process started in the background may inherit
    # "ignore SIGINT", which would otherwise make Ctrl+C-style stops do nothing.
    def handler(signum, _frame):
        raise StopScaler(signum)

    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


def decide(queue_len: int, running: int, max_workers: int) -> int:
    """How many new workers to start.

    Waiting jobs are NOT counted in `running`: a worker removes its job from the
    queue when it starts. So we need one new worker per waiting job, limited by
    how many free slots are left under the maximum.
    """
    return max(0, min(queue_len, max_workers - running))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--max", type=int, default=5, help="maximum workers at once (default 5)")
    parser.add_argument("--interval", type=float, default=2.0, help="seconds between checks (default 2)")
    args = parser.parse_args()
    install_signal_handlers()

    queue_name = os.environ.get("QUEUE_NAME", "jobs:queue")
    r = redis.Redis(host=os.environ.get("REDIS_HOST", "localhost"),
                    port=int(os.environ.get("REDIS_PORT", "6379")),
                    decode_responses=True)

    workers: list[subprocess.Popen] = []
    started_total = 0
    last_line = None
    print(f"[scaler] watching {queue_name}, max={args.max}, every {args.interval}s", flush=True)

    try:
        while True:
            # Forget workers that have finished their job and exited.
            workers = [w for w in workers if w.poll() is None]

            queue_len = r.llen(queue_name)
            to_start = decide(queue_len, len(workers), args.max)

            # Known race: a worker started on the previous tick that hasn't
            # popped its job yet is counted both as "running" and in the queue.
            # Worst case we start one worker too many; it logs "no job
            # available" and exits. KEDA faces the same question (see Stage 3b).
            decision = f"starting {to_start}" if to_start else "nothing to do"
            line = f"queue={queue_len} running={len(workers)} max={args.max} → {decision}"
            if line != last_line or to_start:  # don't spam identical idle lines
                print(f"[scaler] {line}", flush=True)
                last_line = line

            for _ in range(to_start):
                started_total += 1
                env = {**os.environ, "WORKER_MODE": "once", "WORKER_ID": f"scaler-worker-{started_total}"}
                workers.append(subprocess.Popen([sys.executable, str(WORKER_SCRIPT)], env=env))

            time.sleep(args.interval)
    except StopScaler as stop:
        # Ctrl+C in the terminal delivers SIGINT to the whole process group, so
        # the workers already got it and are requeueing their jobs. A SIGTERM
        # (e.g. `kill`) only reaches us, so we pass it on to the workers.
        if stop.signum == signal.SIGTERM:
            for w in workers:
                w.terminate()
        print(f"[scaler] received {stop}, waiting for {len(workers)} worker(s) to exit", flush=True)
        for w in workers:
            w.wait()
    except redis.ConnectionError as exc:
        print(f"[scaler] cannot reach Redis: {exc}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
