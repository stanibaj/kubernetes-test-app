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
