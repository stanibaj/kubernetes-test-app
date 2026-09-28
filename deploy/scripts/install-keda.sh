#!/usr/bin/env bash
# Install (or upgrade) KEDA into the cluster of the current kubectl context,
# with KEDA's official Helm chart at a pinned version. Safe to re-run.
#
# KEDA is installed once per cluster, by whoever runs the cluster, separately
# from any app: it brings cluster-wide CRDs (ScaledJob, ScaledObject, ...)
# that many apps may use. See docs/stage-3b.md.
#
#   deploy/scripts/install-keda.sh          (or: make install-keda)
#   KUBE_CONTEXT=<context> deploy/scripts/install-keda.sh   (a named cluster,
#   e.g. make install-keda-gke; Stage 4 added this, see docs/stage-4.md)
set -euo pipefail

# KEDA 2.21 supports Kubernetes 1.34-1.36 (https://keda.sh/docs/2.21/operate/cluster/).
# Chart version == KEDA version for the kedacore/keda chart.
KEDA_VERSION="${KEDA_VERSION:-2.21.0}"
KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"
# Which cluster: empty = the current kubectl context.
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"

echo "Installing KEDA ${KEDA_VERSION} into namespace ${KEDA_NAMESPACE} (context: ${KUBE_CONTEXT})"

# --repo fetches the chart straight from the repository URL, so no
# `helm repo add` state is needed on this machine. --wait returns only when
# KEDA's pods are ready.
helm upgrade --install keda keda \
  --kube-context "${KUBE_CONTEXT}" \
  --repo https://kedacore.github.io/charts \
  --version "${KEDA_VERSION}" \
  --namespace "${KEDA_NAMESPACE}" --create-namespace \
  --wait --timeout 5m

kubectl --context "${KUBE_CONTEXT}" -n "${KEDA_NAMESPACE}" get pods
kubectl --context "${KUBE_CONTEXT}" get crd | grep keda.sh
