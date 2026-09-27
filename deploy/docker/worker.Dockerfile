# Worker image. Build from the REPOSITORY ROOT:
#   podman build -f deploy/docker/worker.Dockerfile -t localhost/kubernetes-test-app-worker:dev .

# Fully qualified base image name (Podman has no default search registry here).
FROM docker.io/library/python:3.12-slim

# Unbuffered output so every log line reaches stdout immediately;
# no .pyc files written at runtime.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Dependencies first, in their own layer: this layer is reused from cache
# as long as requirements.txt doesn't change, even when worker.py does.
COPY app/worker/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Then the code (changes often, so it goes last).
COPY app/worker/worker.py .

# Run as an unprivileged user. A numeric UID lets Kubernetes verify
# runAsNonRoot later without knowing the user name.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

# Exec form (a JSON list): python runs directly as PID 1 and receives
# SIGTERM itself. The shell form ("CMD python worker.py") would wrap it in
# /bin/sh, which does not forward signals.
CMD ["python", "worker.py"]
