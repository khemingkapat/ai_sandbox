{{/*
SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Cluster config files.
*/}}
{{- define "slurm.vendor.google.a3mega.enabled" -}}
{{- if gt (len (.Values.vendor.google | dig "a3mega" list)) 0 -}}
  {{- print "true" -}}
{{- end -}}
{{- end }}

{{/*
Cluster config files.
*/}}
{{- define "slurm.vendor.google.a3mega.configName" -}}
{{- printf "%s-config-a3mega" (include "slurm.fullname" .) -}}
{{- end }}

{{/*
Return a nodeset values patch for A3 Mega, or empty when not applicable.
*/}}
{{- define "slurm.vendor.google.a3mega.nodesetPatch" -}}
{{- $root := .root -}}
{{- $key := .key -}}
{{- $a3megaConfig := dict -}}
{{- range $config := ($root.Values.vendor.google | dig "a3mega" list) -}}
  {{- if eq (get $config "targetNodeSet" | default "") $key -}}
    {{- $a3megaConfig = $config -}}
  {{- end -}}
{{- end -}}
{{- if $a3megaConfig -}}
  {{- $networks := get $a3megaConfig "networks" | default list -}}
  {{- if ne (len $networks) 9 -}}
    {{- fail (printf "Google Cloud GKE A3 Mega requires exactly 9 networks, but %d were specified." (len $networks)) -}}
  {{- end -}}
  {{- $_ := set $root "a3megaConfig" $a3megaConfig -}}
  {{- tpl ($root.Files.Get "_vendor/google/a3mega/snippets/nodeset.yaml") $root -}}
{{- end -}}
{{- end }}
