# Producer image. Build from the REPOSITORY ROOT:
#   podman build -f deploy/docker/producer.Dockerfile -t localhost/kubernetes-test-app-producer:dev .

FROM docker.io/library/python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Dependencies first (cached layer), code last.
COPY app/producer/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/producer/app.py .
COPY app/producer/static/ static/

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

# Inside the container, listen on all of the CONTAINER's interfaces;
# otherwise published ports (and later Kubernetes Services) can't reach it.
# This is the container's own network namespace, not the host's: which host
# address is exposed is decided when publishing the port (compose `ports:`).
ENV HOST=0.0.0.0 \
    PORT=8000
EXPOSE 8000

CMD ["python", "app.py"]
