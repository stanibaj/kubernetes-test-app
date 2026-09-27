"""Producer: a small web app/API to submit jobs to the Redis queue and view live status.

Run:  HOST=<ip> python app/producer/app.py   (or: uvicorn app:app --app-dir app/producer --host <ip>)
Then open http://<ip>:8000
"""

import json
import os
import random
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

import redis
import uvicorn
from redis.backoff import NoBackoff
from redis.retry import Retry
from fastapi import Depends, FastAPI
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field, PositiveInt

# Configuration from environment variables (same defaults as the worker).
REDIS_HOST = os.environ.get("REDIS_HOST", "localhost")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
QUEUE_NAME = os.environ.get("QUEUE_NAME", "jobs:queue")
# Address to listen on. Defaults to loopback only; set HOST explicitly (e.g. a
# Tailscale IP) to reach the page from another machine.
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8000"))

# Redis key names. The worker defines the same names; the two components are
# kept independent on purpose (each becomes its own container image later).
PROCESSING_KEY = "jobs:processing"
COMPLETED_KEY = "jobs:completed"
FAILED_KEY = "jobs:failed"
DEAD_KEY = "jobs:dead"
HISTORY_KEY = "jobs:history"

RANDOM_DURATION_RANGE = (10, 60)
STATUS_HISTORY_COUNT = 20

INDEX_HTML = Path(__file__).parent / "static" / "index.html"

app = FastAPI(title="kubernetes-test-app producer")

# Fail fast when Redis is down: short timeouts and a single quick retry
# (redis-py's default is 10 retries with backoff). A web request, and
# especially /readyz, should answer "not ready" within seconds, not hang.
_redis = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True,
                     socket_connect_timeout=2, socket_timeout=2,
                     retry=Retry(NoBackoff(), retries=1))


def get_redis() -> redis.Redis:
    # A FastAPI dependency, so tests can swap in a fake Redis.
    return _redis


class JobRequest(BaseModel):
    count: int = Field(1, ge=1, le=200)
    duration_seconds: PositiveInt | Literal["random"] = 30


@app.get("/")
def index() -> FileResponse:
    return FileResponse(INDEX_HTML)


@app.get("/healthz")
def healthz() -> dict:
    # Liveness: "is this process alive and able to answer HTTP?"
    # Deliberately does NOT touch Redis: a Redis outage is not fixed by
    # restarting the producer.
    return {"status": "ok"}


@app.get("/readyz")
def readyz(r: redis.Redis = Depends(get_redis)):
    # Readiness: "can this instance do useful work right now?"
    # Only when Redis answers PING; otherwise 503 so traffic is held back.
    try:
        r.ping()
    except redis.RedisError as exc:
        return JSONResponse(status_code=503, content={"status": "not ready", "error": str(exc)})
    return {"status": "ready"}


@app.post("/api/jobs")
def create_jobs(req: JobRequest, r: redis.Redis = Depends(get_redis)) -> dict:
    job_ids = []
    pipe = r.pipeline()
    for _ in range(req.count):
        if req.duration_seconds == "random":
            duration = random.randint(*RANDOM_DURATION_RANGE)
        else:
            duration = req.duration_seconds
        job = {
            "id": str(uuid.uuid4()),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "duration_seconds": duration,
            "attempts": 0,
        }
        pipe.rpush(QUEUE_NAME, json.dumps(job))  # add to the end of the queue
        job_ids.append(job["id"])
    pipe.execute()
    return {"job_ids": job_ids}


@app.get("/api/status")
def status(r: redis.Redis = Depends(get_redis)) -> dict:
    processing = [
        {"id": job_id, **json.loads(info)}
        for job_id, info in r.hgetall(PROCESSING_KEY).items()
    ]
    processing.sort(key=lambda j: j["started_at"])
    return {
        "queue_length": r.llen(QUEUE_NAME),
        "processing": processing,
        "completed": int(r.get(COMPLETED_KEY) or 0),
        "failed": int(r.get(FAILED_KEY) or 0),
        "dead": r.llen(DEAD_KEY),
        "history": [json.loads(e) for e in r.lrange(HISTORY_KEY, 0, STATUS_HISTORY_COUNT - 1)],
    }


@app.post("/api/reset")
def reset(r: redis.Redis = Depends(get_redis)) -> dict:
    # Delete every jobs:* key, plus the queue in case QUEUE_NAME was customised.
    keys = set(r.scan_iter(match="jobs:*"))
    keys.add(QUEUE_NAME)
    r.delete(*keys)
    return {"deleted": sorted(keys)}


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT)
