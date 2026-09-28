#!/usr/bin/env bash
# Install (or upgrade) the Tailscale Kubernetes operator with its official
# Helm chart at a pinned version. Safe to re-run. Stage 4 (GKE): it handles
# Ingresses with ingressClassName "tailscale", so the producer page is
# reachable only over the tailnet. See docs/stage-4.md.
#
# Needs a Tailscale OAuth client (admin console, see docs/stage-4.md "One-time
# Tailscale setup"), given as environment variables or in a file that is
# never committed:
#   ~/.config/kubernetes-test-app/tailscale-oauth.env
#     TS_OAUTH_CLIENT_ID=...
#     TS_OAUTH_CLIENT_SECRET=tskey-client-...
#
#   KUBE_CONTEXT=<context> deploy/scripts/install-tailscale-operator.sh
#   (or: make install-tailscale-operator, which targets the GKE context)
set -euo pipefail

TS_OPERATOR_VERSION="${TS_OPERATOR_VERSION:-1.102.4}"
TS_NAMESPACE="${TS_NAMESPACE:-tailscale}"
OAUTH_FILE="${OAUTH_FILE:-$HOME/.config/kubernetes-test-app/tailscale-oauth.env}"
# Empty = the current kubectl context.
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"

# Environment variables win; otherwise read them from the file.
if [[ -z "${TS_OAUTH_CLIENT_ID:-}" || -z "${TS_OAUTH_CLIENT_SECRET:-}" ]] && [[ -f "$OAUTH_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$OAUTH_FILE"
fi
if [[ -z "${TS_OAUTH_CLIENT_ID:-}" || -z "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
  echo "error: set TS_OAUTH_CLIENT_ID and TS_OAUTH_CLIENT_SECRET, or put them in $OAUTH_FILE" >&2
  exit 1
fi

echo "Installing Tailscale operator ${TS_OPERATOR_VERSION} into namespace ${TS_NAMESPACE} (context: ${KUBE_CONTEXT})"

# The chart stores the OAuth credentials in the Secret "operator-oauth".
# The operator joins the tailnet tagged tag:k8s-operator; the proxies it
# creates are tagged tag:k8s (both need tagOwners in the tailnet policy).
# The API server proxy (kubectl over the tailnet) stays off, the default.
helm upgrade --install tailscale-operator tailscale-operator \
  --kube-context "${KUBE_CONTEXT}" \
  --repo https://pkgs.tailscale.com/helmcharts \
  --version "${TS_OPERATOR_VERSION}" \
  --namespace "${TS_NAMESPACE}" --create-namespace \
  --set-string oauth.clientId="${TS_OAUTH_CLIENT_ID}" \
  --set-string oauth.clientSecret="${TS_OAUTH_CLIENT_SECRET}" \
  --set-string apiServerProxyConfig.mode=false \
  --wait --timeout 5m

kubectl --context "${KUBE_CONTEXT}" -n "${TS_NAMESPACE}" get pods
kubectl --context "${KUBE_CONTEXT}" get ingressclass tailscale
