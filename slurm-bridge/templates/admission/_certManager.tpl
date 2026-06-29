{{- /*
SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Name of the root CA certification.
*/}}
{{- define "slurm-bridge.admission.certManager.rootCA" -}}
{{ printf "%s-root-ca" (include "slurm-bridge.admission.name" .) }}
{{- end }}

{{/*
Name of the root issuer.
*/}}
{{- define "slurm-bridge.admission.certManager.rootIssuer" -}}
{{ printf "%s-root-issuer" (include "slurm-bridge.admission.name" .) }}
{{- end }}

{{/*
Name of the self signed certification.
*/}}
{{- define "slurm-bridge.admission.certManager.selfCert" -}}
{{ printf "%s-self-ca" (include "slurm-bridge.admission.name" .) }}
{{- end }}

{{/*
Name of the self signed issuer.
*/}}
{{- define "slurm-bridge.admission.certManager.selfIssuer" -}}
{{ printf "%s-self-issuer" (include "slurm-bridge.admission.name" .) }}
{{- end }}
