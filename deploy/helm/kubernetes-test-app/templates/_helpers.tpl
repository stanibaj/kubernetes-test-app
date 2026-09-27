{{/*
Shared snippets used by the templates. Files starting with "_" render nothing
by themselves; they only define named templates that others pull in with
  {{ include "kubernetes-test-app.<name>" <argument> }}
*/}}

{{/* "kubernetes-test-app-0.1.0": chart name and version, for the helm.sh/chart label. */}}
{{- define "kubernetes-test-app.chart" -}}
{{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels: the labels a Deployment uses to find its pods and a Service
uses to find its endpoints. Only labels that never change go here, because a
Deployment's selector is immutable after creation (changing it would force
deleting the Deployment). Called with a dict:
  include "kubernetes-test-app.selectorLabels" (dict "ctx" $ "component" "worker")
*/}}
{{- define "kubernetes-test-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
All labels for a resource: the selector labels plus the ones that may change
between releases (chart version, app version). Same dict argument as above.
*/}}
{{- define "kubernetes-test-app.labels" -}}
{{ include "kubernetes-test-app.selectorLabels" . }}
app.kubernetes.io/part-of: kubernetes-test-app
app.kubernetes.io/version: {{ .ctx.Values.image.tag | default .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
helm.sh/chart: {{ include "kubernetes-test-app.chart" .ctx }}
{{- end }}

{{/*
Image reference for one of our own images: "<registry>/<repository>:<tag>".
Called with a dict: (dict "ctx" $ "repository" .Values.worker.image.repository)
*/}}
{{- define "kubernetes-test-app.image" -}}
{{ printf "%s/%s:%s" .ctx.Values.image.registry .repository (.ctx.Values.image.tag | default .ctx.Chart.AppVersion) }}
{{- end }}

{{/*
Pod-level security settings. The argument is the numeric user ID the image
runs as (10001 for our images, 999 for Redis). runAsNonRoot makes the kubelet
refuse to start the container if it would run as root; fsGroup makes mounted
volumes writable by that group.
*/}}
{{- define "kubernetes-test-app.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ . }}
runAsGroup: {{ . }}
fsGroup: {{ . }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
Container-level security settings, the same for every container: no privilege
escalation (setuid binaries can't gain root), no Linux capabilities, and a
read-only root filesystem (our apps write nothing to disk; Redis writes only
to its /data volume).
*/}}
{{- define "kubernetes-test-app.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
Pod annotation holding a hash of the rendered ConfigMap. Environment
variables from a ConfigMap are read only when a container starts, so a
changed ConfigMap alone does nothing to running pods. Because this hash is
part of the pod template, changing any config value changes the template,
and the Deployment rolls out new pods.
*/}}
{{- define "kubernetes-test-app.configChecksum" -}}
checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
{{- end }}

{{/*
Stop with a clear message if worker.mode is misspelled, instead of silently
rendering no workers at all. Called once, from worker-deployment.yaml.
*/}}
{{- define "kubernetes-test-app.validateWorkerMode" -}}
{{- if not (has .Values.worker.mode (list "deployment" "scaledjob" "scaledobject")) }}
{{- fail (printf "worker.mode must be deployment, scaledjob or scaledobject (got %q)" .Values.worker.mode) }}
{{- end }}
{{- end }}

{{/*
The worker pod spec (everything under a pod template's "spec:"). Shared by
the Deployment (loop mode) and the KEDA ScaledJob (once mode), so the two
run exactly the same container and differ only in what is passed here:
  include "kubernetes-test-app.workerPodSpec"
    (dict "ctx" $ "workerMode" "loop" "restartPolicy" "Always")
*/}}
{{- define "kubernetes-test-app.workerPodSpec" -}}
{{- $v := .ctx.Values -}}
enableServiceLinks: false
# Always = a Deployment restarts a crashed container in place.
# Never  = a Job's pod runs once; a failed pod is not retried (see backoffLimit).
restartPolicy: {{ .restartPolicy }}
# On delete/scale-down: SIGTERM, then up to this long before SIGKILL.
# The worker requeues its current job on SIGTERM and exits.
terminationGracePeriodSeconds: {{ $v.worker.terminationGracePeriodSeconds }}
{{- with $v.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  {{- include "kubernetes-test-app.podSecurityContext" 10001 | nindent 2 }}
containers:
  - name: worker
    image: {{ include "kubernetes-test-app.image" (dict "ctx" .ctx "repository" $v.worker.image.repository) }}
    imagePullPolicy: {{ $v.image.pullPolicy }}
    envFrom:
      - configMapRef:
          name: app-config
    env:
      - name: WORKER_MODE
        value: {{ .workerMode }}
      # Downward API: Kubernetes fills these in from the pod's own
      # metadata, so logs and the status page show which pod did a
      # job, and on which node it ran.
      - name: WORKER_ID
        valueFrom:
          fieldRef:
            fieldPath: metadata.name
      - name: HOST_NAME
        valueFrom:
          fieldRef:
            fieldPath: spec.nodeName
    # No probes: the worker serves no HTTP.
    resources:
      {{- toYaml $v.worker.resources | nindent 6 }}
    securityContext:
      {{- include "kubernetes-test-app.containerSecurityContext" . | nindent 6 }}
{{- end }}

{{/*
KEDA trigger that reads the length of the Redis job list (LLEN). Shared by
the ScaledJob and the ScaledObject. The KEDA operator runs in its own "keda"
namespace, so it needs Redis's full DNS name, not just "redis".
*/}}
{{- define "kubernetes-test-app.redisTrigger" -}}
- type: redis
  metadata:
    address: redis.{{ .Release.Namespace }}.svc.cluster.local:6379
    listName: {{ .Values.config.queueName | quote }}
    # Target number of waiting items per worker. "1" = one worker per job.
    listLength: {{ .Values.worker.keda.listLength | quote }}
{{- end }}
