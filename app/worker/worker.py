"""Queue worker: takes one job at a time from Redis and "processes" it by sleeping.

Modes (WORKER_MODE):
  once  - take a single job, process it, exit (used by the local scaler / KEDA ScaledJob)
  loop  - keep waiting for jobs and process them one after another

Run:  python app/worker/worker.py
"""

import json
import os
import random
import signal
import socket
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone

import redis

# Redis key names. The producer defines the same names; the two components are
# kept independent on purpose (each becomes its own container image later).
PROCESSING_KEY = "jobs:processing"
COMPLETED_KEY = "jobs:completed"
FAILED_KEY = "jobs:failed"
DEAD_KEY = "jobs:dead"
HISTORY_KEY = "jobs:history"
HISTORY_LIMIT = 50

PROGRESS_INTERVAL = 5  # seconds between progress log lines
BLPOP_TIMEOUT = 5  # seconds to wait for a job in loop mode before checking again


class ShutdownRequested(Exception):
    """Raised by our signal handler when SIGTERM/SIGINT arrives."""


@dataclass
class Config:
    redis_host: str
    redis_port: int
    queue_name: str
    mode: str
    fail_rate: float
    max_attempts: int
    worker_id: str
    host_name: str

    @classmethod
    def from_env(cls) -> "Config":
        # All configuration comes from environment variables with local defaults.
        hostname = socket.gethostname()
        mode = os.environ.get("WORKER_MODE", "loop")
        if mode not in ("loop", "once"):
            raise ValueError(f"WORKER_MODE must be 'loop' or 'once', got {mode!r}")
        return cls(
            redis_host=os.environ.get("REDIS_HOST", "localhost"),
            redis_port=int(os.environ.get("REDIS_PORT", "6379")),
            queue_name=os.environ.get("QUEUE_NAME", "jobs:queue"),
            mode=mode,
            fail_rate=float(os.environ.get("FAIL_RATE", "0.0")),
            max_attempts=int(os.environ.get("MAX_ATTEMPTS", "3")),
            worker_id=os.environ.get("WORKER_ID") or f"{hostname}-{os.getpid()}",
            host_name=os.environ.get("HOST_NAME") or hostname,
        )


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(cfg: Config, message: str) -> None:
    # One plain line per event on stdout; flush so output appears immediately.
    print(f"[{cfg.worker_id}] {message}", flush=True)


def short(job_id: str) -> str:
    return job_id[:8] + "…"


def process_job(r: redis.Redis, cfg: Config, raw_job: str,
                sleep=time.sleep, rand=random.random) -> str:
    """Process one job. Returns the result: 'completed', 'failed' or 'dead'.

    `sleep` and `rand` can be replaced in tests.
    If a shutdown signal arrives mid-job, the job is put back on the queue and
    ShutdownRequested is re-raised.
    """
    job = json.loads(raw_job)
    job_id = job["id"]
    duration = int(job["duration_seconds"])
    started_at = now_iso()

    try:
        # 1. Register the job as "in progress" so the status page can show it.
        r.hset(PROCESSING_KEY, job_id, json.dumps(
            {"worker": cfg.worker_id, "host": cfg.host_name, "started_at": started_at}))
        log(cfg, f"job {short(job_id)} started on host {cfg.host_name} ({duration}s)")

        # 2. "Work": sleep in small chunks so we can log progress.
        elapsed = 0
        while elapsed < duration:
            chunk = min(PROGRESS_INTERVAL, duration - elapsed)
            sleep(chunk)
            elapsed += chunk
            log(cfg, f"job {short(job_id)} progress {elapsed}/{duration}s")

        # 3./4. Simulated failure or success.
        if rand() < cfg.fail_rate:
            job["attempts"] = int(job.get("attempts", 0)) + 1
            r.incr(FAILED_KEY)
            if job["attempts"] < cfg.max_attempts:
                r.rpush(cfg.queue_name, json.dumps(job))  # retry later
                result = "failed"
                log(cfg, f"job {short(job_id)} failed (attempt {job['attempts']}), requeued")
            else:
                r.rpush(DEAD_KEY, json.dumps(job))  # give up: dead-letter list
                result = "dead"
                log(cfg, f"job {short(job_id)} failed (attempt {job['attempts']}), moved to dead-letter list")
        else:
            r.incr(COMPLETED_KEY)
            result = "completed"
            log(cfg, f"job {short(job_id)} completed")

        # 5. Clean up and record history (newest first, capped).
        entry = {"id": job_id, "worker": cfg.worker_id, "host": cfg.host_name,
                 "started_at": started_at, "finished_at": now_iso(), "result": result}
        pipe = r.pipeline()
        pipe.hdel(PROCESSING_KEY, job_id)
        pipe.lpush(HISTORY_KEY, json.dumps(entry))
        pipe.ltrim(HISTORY_KEY, 0, HISTORY_LIMIT - 1)
        pipe.execute()
        return result

    except ShutdownRequested:
        # 6. Interrupted: put the job back at the FRONT of the queue (it was
        # already waiting its turn) and forget that we were working on it.
        # An interruption is not the job's fault, so it doesn't count as an attempt.
        pipe = r.pipeline()
        pipe.lpush(cfg.queue_name, raw_job)
        pipe.hdel(PROCESSING_KEY, job_id)
        pipe.execute()
        log(cfg, f"job {short(job_id)} interrupted by shutdown signal, returned to queue")
        raise


def run_once(r: redis.Redis, cfg: Config, **kwargs) -> None:
    raw_job = r.lpop(cfg.queue_name)
    if raw_job is None:
        log(cfg, "no job available")
        return
    process_job(r, cfg, raw_job, **kwargs)


def run_loop(r: redis.Redis, cfg: Config) -> None:
    log(cfg, f"waiting for jobs on {cfg.queue_name}")
    while True:
        item = r.blpop([cfg.queue_name], timeout=BLPOP_TIMEOUT)
        if item is None:
            continue  # nothing yet, wait again
        _queue, raw_job = item
        # (A signal landing in the microseconds between BLPOP returning and
        # process_job starting would lose this job. We accept that tiny window
        # to keep the code simple; Redis's reliable-queue pattern with LMOVE
        # would close it.)
        process_job(r, cfg, raw_job)


def install_signal_handlers() -> None:
    # Turn SIGTERM (what Docker/Kubernetes send on stop) and SIGINT (Ctrl+C)
    # into an exception, which interrupts sleep() and BLPOP right away.
    def handler(signum, _frame):
        raise ShutdownRequested(signal.Signals(signum).name)

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


def main() -> int:
    cfg = Config.from_env()
    install_signal_handlers()
    r = redis.Redis(host=cfg.redis_host, port=cfg.redis_port, decode_responses=True)
    try:
        if cfg.mode == "once":
            run_once(r, cfg)
        else:
            run_loop(r, cfg)
    except ShutdownRequested as exc:
        log(cfg, f"received {exc}, exiting")
    except redis.ConnectionError as exc:
        # A real error: exit non-zero.
        log(cfg, f"cannot reach Redis at {cfg.redis_host}:{cfg.redis_port}: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
