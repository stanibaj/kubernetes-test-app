import pytest

from local_scaler import decide


@pytest.mark.parametrize("queue_len, running, max_workers, expected", [
    (0, 0, 5, 0),    # nothing waiting
    (3, 0, 5, 3),    # one worker per waiting job
    (12, 0, 5, 5),   # capped at the maximum
    (7, 3, 5, 2),    # only the free slots
    (4, 5, 5, 0),    # already at the maximum
    (2, 6, 5, 0),    # above the maximum (e.g. --max lowered) never goes negative
])
def test_decide(queue_len, running, max_workers, expected):
    assert decide(queue_len, running, max_workers) == expected
