#!/usr/bin/env bash
# Follow the logs of ALL worker pods, including ones that start later.
#
# `kubectl logs -l ... -f` only follows the pods that exist when it starts,
# but with KEDA new worker pods keep appearing (one per Job in scaledjob
# mode). So every 2 s this looks for worker pods it isn't following yet and
# starts a `kubectl logs -f` for each one. Ctrl+C stops everything.
#
#   deploy/scripts/logs-worker.sh [namespace]      (or: make logs-worker)
set -uo pipefail

NS="${1:-kubernetes-test-app}"
SELECTOR="app.kubernetes.io/component=worker"

# On Ctrl+C / exit, stop all background `kubectl logs` processes.
trap 'kill $(jobs -p) 2>/dev/null; exit 0' INT TERM EXIT

declare -A following=()
while true; do
  # Skip Pending pods (not started yet: no logs to follow); they are picked
  # up on a later round, once running. Finished pods kept in the Job history
  # just print their log and end.
  for pod in $(kubectl -n "$NS" get pods -l "$SELECTOR" \
                 --field-selector=status.phase!=Pending -o name 2>/dev/null); do
    if [[ -z "${following[$pod]:-}" ]]; then
      following[$pod]=1
      # --prefix adds "[pod/<name>/worker]" to every line.
      kubectl -n "$NS" logs -f --prefix "$pod" &
    fi
  done
  sleep 2
done
