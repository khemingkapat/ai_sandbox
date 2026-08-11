{{- /*
SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
SPDX-FileCopyrightText: Copyright (C) NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Check if DCGM integration is enabled
*/}}
{{- define "slurm.vendor.nvidia.dcgm.enabled" -}}
{{- $vendor := .Values.vendor | default dict -}}
{{- ($vendor | dig "nvidia" "dcgm" "enabled" false) | ternary "true" "" -}}
{{- end }}

{{/*
Get the DCGM job mapping directory
*/}}
{{- define "slurm.vendor.nvidia.dcgm.jobMappingDir" -}}
{{- $vendor := .Values.vendor | default dict -}}
{{- $vendor | dig "nvidia" "dcgm" "jobMappingDir" "/var/lib/dcgm-exporter/job-mapping" -}}
{{- end }}

{{/*
Check if a nodeset has GPU resources allocated
*/}}
{{- define "slurm.vendor.nvidia.dcgm.nodesetHasGPU" -}}
{{- $nodeset := . -}}
{{- $device := "nvidia.com/gpu" -}}

{{- $slurmd := $nodeset.slurmd | default dict -}}
{{- $podSpec := $nodeset.podSpec | default dict -}}
{{- $slurmdLimits := $slurmd | dig "resources" "limits" dict -}}
{{- $slurmdRequests := $slurmd | dig "resources" "requests" dict -}}
{{- $podLimits := $podSpec | dig "resources" "limits" dict -}}
{{- $podRequests := $podSpec | dig "resources" "requests" dict -}}
{{- if or (index $slurmdLimits $device) (index $slurmdRequests $device) (index $podLimits $device) (index $podRequests $device) -}}
  {{- print $device -}}
{{- end -}}
{{- end }}

{{/*
Return a nodeset values patch for DCGM, or empty when not applicable.
*/}}
{{- define "slurm.vendor.nvidia.dcgm.nodesetPatch" -}}
{{- $root := .root -}}
{{- $nodeset := .nodeset -}}
{{- if and (include "slurm.vendor.nvidia.dcgm.enabled" $root) (include "slurm.vendor.nvidia.dcgm.nodesetHasGPU" $nodeset) -}}
  {{- tpl ($root.Files.Get "_vendor/nvidia/dcgm/snippets/nodeset.yaml") $root -}}
{{- end -}}
{{- end -}}

{{/*
Generate DCGM prolog configmap name.
*/}}
{{- define "slurm.vendor.nvidia.dcgm.prologName" -}}
{{- printf "%s-prolog-dcgm" (include "slurm.fullname" .) -}}
{{- end }}

{{/*
Generate DCGM epilog configmap name.
*/}}
{{- define "slurm.vendor.nvidia.dcgm.epilogName" -}}
{{- printf "%s-epilog-dcgm" (include "slurm.fullname" .) -}}
{{- end }}

{{/*
Generate DCGM prolog script content
*/}}
{{- define "slurm.vendor.nvidia.dcgm.prologScripts" -}}
{{- $vendor := .Values.vendor | default dict -}}
{{- $scriptPriority := $vendor | dig "nvidia" "dcgm" "scriptPriority" "90" }}
{{- $jobMappingDir := include "slurm.vendor.nvidia.dcgm.jobMappingDir" . -}}
{{- range $path, $_ := .Files.Glob "_vendor/nvidia/dcgm/scripts/prolog/*.sh" -}}
  {{- $contents := $.Files.Get $path | replace "__JOB_MAPPING_DIR__" $jobMappingDir -}}
  {{- printf "prolog-%s-%s" $scriptPriority (base $path) | nindent 0 -}}: |
    {{- $contents | nindent 2 -}}
{{- end }}
{{- end }}

{{/*
Generate DCGM epilog script content
*/}}
{{- define "slurm.vendor.nvidia.dcgm.epilogScripts" -}}
{{- $vendor := .Values.vendor | default dict -}}
{{- $scriptPriority := $vendor | dig "nvidia" "dcgm" "scriptPriority" "90" }}
{{- $jobMappingDir := include "slurm.vendor.nvidia.dcgm.jobMappingDir" . -}}
{{- range $path, $_ := .Files.Glob "_vendor/nvidia/dcgm/scripts/epilog/*.sh" -}}
  {{- $contents := $.Files.Get $path | replace "__JOB_MAPPING_DIR__" $jobMappingDir -}}
  {{- printf "epilog-%s-%s" $scriptPriority (base $path) | nindent 0 -}}: |
    {{- $contents | nindent 2 -}}
{{- end }}
{{- end }}
