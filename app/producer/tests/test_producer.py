import json

import fakeredis
import pytest
from fastapi.testclient import TestClient

import app as producer

QUEUE = "jobs:queue"


@pytest.fixture
def r():
    return fakeredis.FakeRedis(decode_responses=True)


@pytest.fixture
def client(r):
    producer.app.dependency_overrides[producer.get_redis] = lambda: r
    yield TestClient(producer.app)
    producer.app.dependency_overrides.clear()


def test_create_jobs_pushes_payloads(client, r):
    res = client.post("/api/jobs", json={"count": 3, "duration_seconds": 15})
    assert res.status_code == 200
    ids = res.json()["job_ids"]
    assert len(ids) == 3

    jobs = [json.loads(j) for j in r.lrange(QUEUE, 0, -1)]
    assert [j["id"] for j in jobs] == ids  # in submission order
    assert all(j["duration_seconds"] == 15 and j["attempts"] == 0 for j in jobs)
    assert all("created_at" in j for j in jobs)


def test_defaults_to_one_job_of_30_seconds(client, r):
    client.post("/api/jobs", json={})
    job = json.loads(r.lindex(QUEUE, 0))
    assert r.llen(QUEUE) == 1
    assert job["duration_seconds"] == 30


def test_random_duration_is_between_10_and_60(client, r):
    client.post("/api/jobs", json={"count": 50, "duration_seconds": "random"})
    durations = [json.loads(j)["duration_seconds"] for j in r.lrange(QUEUE, 0, -1)]
    assert all(10 <= d <= 60 for d in durations)


@pytest.mark.parametrize("body", [{"count": 0}, {"count": 201}, {"duration_seconds": "soon"}, {"duration_seconds": 0}])
def test_invalid_requests_are_rejected(client, body):
    assert client.post("/api/jobs", json=body).status_code == 422


def test_status_reports_everything(client, r):
    client.post("/api/jobs", json={"count": 2})
    r.hset("jobs:processing", "job-x", json.dumps({"worker": "w1", "host": "h1", "started_at": "2026-01-01T00:00:00+00:00"}))
    r.set("jobs:completed", 4)
    r.set("jobs:failed", 2)
    r.rpush("jobs:dead", "{}")
    for i in range(25):
        r.lpush("jobs:history", json.dumps({"id": f"h{i}"}))

    s = client.get("/api/status").json()
    assert s["queue_length"] == 2
    assert s["processing"] == [{"id": "job-x", "worker": "w1", "host": "h1", "started_at": "2026-01-01T00:00:00+00:00"}]
    assert (s["completed"], s["failed"], s["dead"]) == (4, 2, 1)
    assert len(s["history"]) == 20


def test_status_on_empty_redis(client):
    s = client.get("/api/status").json()
    assert s == {"queue_length": 0, "processing": [], "completed": 0, "failed": 0, "dead": 0, "history": []}


def test_reset_clears_all_job_keys(client, r):
    client.post("/api/jobs", json={"count": 2})
    r.set("jobs:completed", 1)
    r.set("unrelated", "keep me")
    client.post("/api/reset")
    assert r.keys("jobs:*") == []
    assert r.get("unrelated") == "keep me"


def test_index_serves_html(client):
    res = client.get("/")
    assert res.status_code == 200
    assert "text/html" in res.headers["content-type"]
