{{- define "flux-operator-bootstrap.test-image-repository" -}}
terraform-kubernetes-flux-operator-bootstrap-test
{{- end -}}

{{- define "flux-operator-bootstrap.job-image-tag" -}}
{{- if eq .Values.job.image.repository (include "flux-operator-bootstrap.test-image-repository" .) -}}
dev
{{- else -}}
v{{ .Chart.Version }}
{{- end -}}
{{- end -}}
