import json

import fakeredis
import pytest
import redis

import worker
from worker import Config, ShutdownRequested, process_job, run_once

QUEUE = "jobs:queue"


@pytest.fixture
def r():
    return fakeredis.FakeRedis(decode_responses=True)


@pytest.fixture
def cfg():
    return Config(redis_host="localhost", redis_port=6379, queue_name=QUEUE, mode="once",
                  fail_rate=0.0, max_attempts=3, worker_id="test-worker", host_name="test-host")


def make_job(job_id="job-1", duration=12, attempts=0):
    return json.dumps({"id": job_id, "created_at": "2026-01-01T00:00:00+00:00",
                       "duration_seconds": duration, "attempts": attempts})


def no_sleep(_seconds):
    pass


def test_success_updates_counters_and_history(r, cfg):
    sleeps = []
    result = process_job(r, cfg, make_job(duration=12), sleep=sleeps.append, rand=lambda: 0.99)

    assert result == "completed"
    assert sleeps == [5, 5, 2]  # progress logged in chunks of at most 5 s
    assert r.get("jobs:completed") == "1"
    assert r.get("jobs:failed") is None
    assert r.hlen("jobs:processing") == 0
    entry = json.loads(r.lindex("jobs:history", 0))
    assert entry["id"] == "job-1"
    assert entry["worker"] == "test-worker"
    assert entry["host"] == "test-host"
    assert entry["result"] == "completed"
    assert {"started_at", "finished_at"} <= entry.keys()


def test_job_is_registered_as_processing_while_running(r, cfg):
    seen = []
    process_job(r, cfg, make_job(duration=1),
                sleep=lambda _s: seen.append(r.hgetall("jobs:processing")), rand=lambda: 0.99)
    info = json.loads(seen[0]["job-1"])
    assert info["worker"] == "test-worker"
    assert info["host"] == "test-host"


def test_failure_requeues_with_incremented_attempts(r, cfg):
    cfg.fail_rate = 1.0
    result = process_job(r, cfg, make_job(attempts=0), sleep=no_sleep, rand=lambda: 0.0)

    assert result == "failed"
    assert r.get("jobs:failed") == "1"
    assert r.llen("jobs:dead") == 0
    assert json.loads(r.lindex(QUEUE, 0))["attempts"] == 1
    assert r.hlen("jobs:processing") == 0


def test_last_failure_goes_to_dead_letter_list(r, cfg):
    cfg.fail_rate = 1.0
    result = process_job(r, cfg, make_job(attempts=2), sleep=no_sleep, rand=lambda: 0.0)

    assert result == "dead"
    assert r.llen(QUEUE) == 0
    assert json.loads(r.lindex("jobs:dead", 0))["attempts"] == 3
    assert json.loads(r.lindex("jobs:history", 0))["result"] == "dead"


def test_history_is_capped(r, cfg):
    for i in range(55):
        process_job(r, cfg, make_job(job_id=f"job-{i}", duration=0), sleep=no_sleep, rand=lambda: 0.99)
    assert r.llen("jobs:history") == 50
    assert json.loads(r.lindex("jobs:history", 0))["id"] == "job-54"  # newest first


def test_interrupt_returns_job_to_front_of_queue(r, cfg):
    r.rpush(QUEUE, make_job(job_id="other"))
    raw = make_job(job_id="job-1")

    def interrupted_sleep(_s):
        raise ShutdownRequested("SIGTERM")

    with pytest.raises(ShutdownRequested):
        process_job(r, cfg, raw, sleep=interrupted_sleep)

    assert r.lindex(QUEUE, 0) == raw  # unchanged (no extra attempt) and first in line
    assert r.llen(QUEUE) == 2
    assert r.hlen("jobs:processing") == 0
    assert r.get("jobs:completed") is None


def test_run_once_with_empty_queue_does_nothing(r, cfg, capsys):
    run_once(r, cfg)
    assert "no job available" in capsys.readouterr().out


def test_run_once_takes_exactly_one_job(r, cfg):
    r.rpush(QUEUE, make_job(job_id="a", duration=0), make_job(job_id="b", duration=0))
    run_once(r, cfg, sleep=no_sleep, rand=lambda: 0.99)
    assert r.get("jobs:completed") == "1"
    assert json.loads(r.lindex(QUEUE, 0))["id"] == "b"


def test_main_returns_1_when_redis_unreachable(monkeypatch):
    monkeypatch.setenv("REDIS_PORT", "1")  # nothing listens here
    monkeypatch.setenv("WORKER_MODE", "once")
    monkeypatch.setattr(worker, "install_signal_handlers", lambda: None)
    assert worker.main() == 1


def test_socket_timeout_is_longer_than_blpop_timeout(cfg):
    # Otherwise an empty-queue BLPOP reply (sent after BLPOP_TIMEOUT) can
    # arrive after the client has already given up (seen on k3s, Stage 3a).
    client = worker.connect(cfg)
    assert client.connection_pool.connection_kwargs["socket_timeout"] > worker.BLPOP_TIMEOUT


def test_main_returns_1_when_redis_times_out(monkeypatch, capsys):
    class SilentRedis:
        def lpop(self, _queue):
            raise redis.TimeoutError("Timeout reading from socket")

    monkeypatch.setenv("WORKER_MODE", "once")
    monkeypatch.setattr(worker, "install_signal_handlers", lambda: None)
    monkeypatch.setattr(worker, "connect", lambda _cfg: SilentRedis())
    assert worker.main() == 1
    assert "cannot reach Redis" in capsys.readouterr().out
