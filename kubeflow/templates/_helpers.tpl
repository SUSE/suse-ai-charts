{{/*
Return the proper Docker Image Registry Secret Names evaluating global and
chart-level imagePullSecrets. Supports both string and object formats.
*/}}
{{- define "kubeflow.imagePullSecrets" -}}
{{- if and (hasKey .Values "global") .Values.global }}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  {{- $imagePullSecrets := list }}
  {{- if kindIs "string" . }}
    {{- $imagePullSecrets = append $imagePullSecrets (dict "name" .) }}
  {{- else }}
    {{- $imagePullSecrets = append $imagePullSecrets . }}
  {{- end }}
  {{- toYaml $imagePullSecrets | nindent 2 }}
{{- end }}
{{- else if .Values.imagePullSecrets }}
imagePullSecrets:
    {{ toYaml .Values.imagePullSecrets }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the proper Application Collection Image Registry.
Precedence: global.imageRegistry > global.suseApplicationCollectionRegistry > component image.registry
Usage: {{ include "kubeflow.suseApplicationCollectionRegistry" (dict "ctx" . "registry" .Values.component.image.registry) }}
*/}}
{{- define "kubeflow.suseApplicationCollectionRegistry" -}}
{{- $ctx := .ctx -}}
{{- if $ctx.Values.global.imageRegistry -}}
  {{- $ctx.Values.global.imageRegistry -}}
{{- else if $ctx.Values.global.suseApplicationCollectionRegistry -}}
  {{- $ctx.Values.global.suseApplicationCollectionRegistry -}}
{{- else -}}
  {{- .registry -}}
{{- end -}}
{{- end -}}

{{/*
Component registry, from components.yaml (see the comment there). Fails with a clear message
when the file is missing or isn't valid YAML.
*/}}
{{- define "kubeflow.components" -}}
{{- $raw := .Files.Get "components.yaml" -}}
{{- if not $raw }}{{ fail "components.yaml is missing from the kubeflow chart" }}{{ end -}}
{{- $reg := fromYaml $raw -}}
{{- if hasKey $reg "Error" }}{{ fail (printf "components.yaml is not valid YAML: %s" (index $reg "Error")) }}{{ end -}}
{{- $raw -}}
{{- end -}}

{{/* String value at a dotted values path (dict "root" .Values "path" "a.b" "default" "x"). */}}
{{- define "kubeflow.valueAt" -}}
{{- $cur := .root -}}
{{- $found := true -}}
{{- range $k := splitList "." .path -}}
{{-   if and $found (kindIs "map" $cur) (hasKey $cur $k) }}{{ $cur = index $cur $k }}{{ else }}{{ $found = false }}{{ end -}}
{{- end -}}
{{- if and $found (not (kindIs "invalid" $cur)) }}{{ toString $cur }}{{ else if not (kindIs "invalid" .default) }}{{ toString .default }}{{ end -}}
{{- end -}}

{{/* "true" when a registry condition holds: {path, default, equals} or {helper} (dict "ctx" . "cond" $cond). */}}
{{- define "kubeflow.conditionMet" -}}
{{- if .cond.helper }}{{ include .cond.helper .ctx }}
{{- else if eq (include "kubeflow.valueAt" (dict "root" .ctx.Values "path" .cond.path "default" .cond.default)) (toString .cond.equals) }}true{{ end -}}
{{- end -}}

{{/* "true" when KServe's default deployment mode needs Knative: Knative, or its old name Serverless
     (the default). Read from the JSON in kserve.inferenceServiceConfig.deploy. */}}
{{- define "kubeflow.kserveKnativeMode" -}}
{{- $deploy := dig "inferenceServiceConfig" "deploy" "" (index .Values "kserve" | default dict) -}}
{{- $mode := "" -}}
{{- if $deploy }}{{ $mode = (fromJson $deploy).defaultDeploymentMode | default "" | toString }}{{ end -}}
{{- if has ($mode | default "Serverless") (list "Serverless" "Knative") }}true{{ end -}}
{{- end -}}

{{/* "true" when a registry entry is enabled (dict "ctx" . "c" $entry). */}}
{{- define "kubeflow.componentOn" -}}
{{- if .c.enabledBy }}{{ include .c.enabledBy .ctx }}
{{- else if eq (include "kubeflow.valueAt" (dict "root" .ctx.Values "path" .c.toggle "default" "false")) "true" }}true{{ end -}}
{{- end -}}

{{/* JSON list of enabled registry entries, sorted (add-ons included). */}}
{{- define "kubeflow.enabledComponents" -}}
{{- $reg := include "kubeflow.components" . | fromYaml -}}
{{- $on := list -}}
{{- range $name := keys $reg | sortAlpha -}}
{{-   if include "kubeflow.componentOn" (dict "ctx" $ "c" (index $reg $name)) }}{{ $on = append $on $name }}{{ end -}}
{{- end -}}
{{- toJson $on -}}
{{- end -}}

{{/* JSON list of the enabled settings that need Istio, as the user would name them. */}}
{{- define "kubeflow.istioUsers" -}}
{{- $reg := include "kubeflow.components" . | fromYaml -}}
{{- $users := list -}}
{{- range $name := include "kubeflow.enabledComponents" . | fromJsonArray -}}
{{-   $c := index $reg $name -}}
{{-   if and $c.istio (not (and $c.istioOptional (include "kubeflow.conditionMet" (dict "ctx" $ "cond" $c.istioOptional)))) -}}
{{-     $users = append $users ($c.istioHint | default $c.toggle) -}}
{{-   end -}}
{{- end -}}
{{- toJson $users -}}
{{- end -}}

{{/* JSON list of unmet "requires" of enabled components: {component, requires (component or
     capability name), message}. CI reads it to add prerequisites; requirementErrors shows the messages. */}}
{{- define "kubeflow.unmetRequirements" -}}
{{- $reg := include "kubeflow.components" . | fromYaml -}}
{{- $on := include "kubeflow.enabledComponents" . | fromJsonArray -}}
{{- $login := or (has "oauth2Proxy" $on) (eq (include "kubeflow.valueAt" (dict "root" .Values "path" "istioResources.externalAuth" "default" "false")) "true") -}}
{{- $unmet := list -}}
{{- range $name := $on -}}
{{-   $c := index $reg $name -}}
{{-   range $r := $c.requires | default list -}}
{{-     if or (not $r.when) (include "kubeflow.conditionMet" (dict "ctx" $ "cond" $r.when)) -}}
{{-       $met := false -}}
{{-       $dep := "" -}}
{{-       $depName := $r.capability | default $r.component -}}
{{-       if eq ($r.capability | default "") "login" -}}
{{-         $met = $login -}}
{{-         $dep = "login (global.oauth2Proxy.enabled=true, or istioResources.externalAuth=true)" -}}
{{-       else -}}
{{-         $d := index $reg $r.component -}}
{{-         $met = has $r.component $on -}}
{{-         $dep = $d.label | default (printf "%s=true" $d.toggle) -}}
{{-       end -}}
{{-       if not $met -}}
{{-         $when := "" -}}
{{-         if $r.when -}}
{{-           if $r.when.label }}{{ $when = printf " when %s" $r.when.label }}{{ else }}{{ $when = printf " when %s=%s" $r.when.path (toString $r.when.equals) }}{{ end -}}
{{-         end -}}
{{-         $msg := printf "%s requires %s%s: %s" ($c.label | default (printf "%s=true" $c.toggle)) $dep $when $r.why -}}
{{-         $unmet = append $unmet (dict "component" $name "requires" $depName "message" $msg) -}}
{{-       end -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- toJson $unmet -}}
{{- end -}}

{{/* JSON list of the messages of kubeflow.unmetRequirements. */}}
{{- define "kubeflow.requirementErrors" -}}
{{- $errs := list -}}
{{- range $u := include "kubeflow.unmetRequirements" . | fromJsonArray }}{{ $errs = append $errs $u.message }}{{ end -}}
{{- toJson $errs -}}
{{- end -}}

{{/* "true" when Trainer is the only Kubeflow component enabled (add-ons aside); NOTES then shows the
     Trainer-only banner. */}}
{{- define "kubeflow.trainerOnly" -}}
{{- $reg := include "kubeflow.components" . | fromYaml -}}
{{- $on := list -}}
{{- range $n := include "kubeflow.enabledComponents" . | fromJsonArray }}{{ if not (index $reg $n).addon }}{{ $on = append $on $n }}{{ end }}{{ end -}}
{{- if eq (toJson $on) (toJson (list "trainer")) }}true{{ end -}}
{{- end -}}


{{/*
Gateway TLS source (kubeflow-istio-resources.tls.source), "" when unset. One lookup
for every umbrella template that branches on it.
*/}}
{{- define "kubeflow.tlsSource" -}}
{{- ((index .Values "kubeflow-istio-resources" | default dict).tls | default dict).source | default "" -}}
{{- end -}}

{{/*
"true" when cert-manager is required: an enabled component declares certManager in the
registry, or cert-manager issues the gateway TLS cert (any tls.source except "" and
"secret"). Used by the preflight hook.
*/}}
{{- define "kubeflow.needsCertManager" -}}
{{- $src := include "kubeflow.tlsSource" . -}}
{{- $reg := include "kubeflow.components" . | fromYaml -}}
{{- $need := and $src (ne $src "secret") -}}
{{- range $n := include "kubeflow.enabledComponents" . | fromJsonArray }}{{ if (index $reg $n).certManager }}{{ $need = true }}{{ end }}{{ end -}}
{{- if $need }}true{{ end -}}
{{- end -}}

{{/* What must exist in the cluster before this release installs, space-separated: istio, cert-manager,
     eso (External Secrets Operator, unless the release installs it) and knative-namespace (created
     and adopted up front). Read by install.sh, which installs or prepares them. */}}
{{- define "kubeflow.clusterPrerequisites" -}}
{{- $on := include "kubeflow.enabledComponents" . | fromJsonArray -}}
{{- $need := list -}}
{{- if has "istioResources" $on }}{{ $need = append $need "istio" }}{{ end -}}
{{- if include "kubeflow.needsCertManager" . }}{{ $need = append $need "cert-manager" }}{{ end -}}
{{- $eso := eq (include "kubeflow.valueAt" (dict "root" .Values "path" "externalSecrets.enabled" "default" "false")) "true" -}}
{{- if and $eso (not (has "externalSecretsOperator" $on)) }}{{ $need = append $need "eso" }}{{ end -}}
{{- if has "knativeServing" $on }}{{ $need = append $need "knative-namespace" }}{{ end -}}
{{- join " " $need -}}
{{- end -}}

{{/* global.istio.cni as "true"/"false" (default true). Copied per chart; CI keeps the copies equal. */}}
{{- define "kubeflow.istioCni" -}}
{{- ne (toString (dig "istio" "cni" true (.Values.global | default dict))) "false" -}}
{{- end -}}

{{/* "true" when Dex's built-in password login uses auth.initialUser (enablePasswordDB and a staticPasswords
     entry reading KUBEFLOW_INITIAL_USER_HASH). Off when an external identity provider replaces it. */}}
{{- define "kubeflow.dexPasswordLogin" -}}
{{- if and .Values.dex.enabled (.Values.dex.config | default dict).enablePasswordDB -}}
{{-   range ((.Values.dex.config | default dict).staticPasswords | default list) -}}
{{-     if and (eq (.hashFromEnv | default "") "KUBEFLOW_INITIAL_USER_HASH") (not .hash) }}true{{ break }}{{ end -}}
{{-   end -}}
{{- end -}}
{{- end -}}

{{/* The published demo credentials, used for empty credential values when global.demoMode=true. */}}
{{- define "kubeflow.demoCredentials" -}}
clientSecret: pUBnBOY80SnXgjibTYM9ZWNzY2xreNGQok
cookieSecret: 3GvvtL75w3Y8ERsQ9ma81nIngIx4YrjXNtQpCNDa4Vc=
passwordHash: $2y$12$arGZ9p14vTUDsOg/GZ6DRu8UjXxtB60UI3A1Api5/UXjdBz5qTEjm
accessKey: kubeflow
secretKey: kubeflow123
{{- end -}}

{{/* "true" when the render sees the cluster (helm install/upgrade); "" for helm template, Argo CD and
     --dry-run=client, where lookup finds nothing, so generated credentials would change on every render. */}}
{{- define "kubeflow.clusterVisible" -}}
{{- if lookup "v1" "Namespace" "" "kube-system" }}true{{ end -}}
{{- end -}}

{{/* "true" when cni=true and an enabled component creates profile namespaces (they get Pod Security baseline). */}}
{{- define "kubeflow.istioCniCheckNeeded" -}}
{{- $reg := include "kubeflow.components" . | fromYaml -}}
{{- $ns := false -}}
{{- range $n := include "kubeflow.enabledComponents" . | fromJsonArray }}{{ if (index $reg $n).profileNamespaces }}{{ $ns = true }}{{ end }}{{ end -}}
{{- if and (eq (include "kubeflow.istioCni" .) "true") $ns }}true{{ end -}}
{{- end -}}

{{/* Istio CNI check rules, shared by validations.yaml (Helm lookup) and the preflight Job (kubectl).
     Names also match revisioned "<name>-<rev>" objects; the injector fails only on an explicit false. */}}
{{- define "kubeflow.istioCniProbe" -}}
istiod: istiod                    # Deployment in istio-system
cniDaemonSet: istio-cni-node      # DaemonSet, any namespace
injector: istio-sidecar-injector  # ConfigMap in istio-system, key "values" (JSON)
injectorField: [pilot, cni, enabled]
{{- end -}}

{{- define "kubeflow.istioCniMissingMsg" -}}
global.istio.cni=true (the default) but Istio in istio-system runs WITHOUT the istio-cni plugin (no istio-cni-node DaemonSet in any namespace). Profile namespaces would enforce Pod Security Standards 'baseline', which rejects pods using the istio-init container. Either install Istio with CNI (runMe.sh default; -f istio-cni-values.yaml) and restart meshed workloads, or set global.istio.cni=false. See docs/upgrade-notes.md#istio-cni.
{{- end -}}

{{/* Takes the injector ConfigMap name(s). */}}
{{- define "kubeflow.istioCniInjectorMsg" -}}
global.istio.cni=true (the default) but istiod's sidecar injector (ConfigMap istio-system/{{ . }}) has pilot.cni.enabled=false, so pods still get the istio-init container, which Pod Security Standards 'baseline' rejects. Install Istio with -f istio-cni-values.yaml (it sets both cni.enabled and istiod.pilot.cni.enabled) and restart meshed workloads, or set global.istio.cni=false. See docs/upgrade-notes.md#istio-cni.
{{- end -}}

{{/* global.modelRegistry.mode, "perProfile" when unset. Also resolved in kubeflow-hub and user-namespace;
     test/ci/check_model_registry_consistency.py keeps the three in agreement. */}}
{{- define "kubeflow.modelRegistryMode" -}}
{{- dig "modelRegistry" "mode" "" (.Values.global | default dict) | default "perProfile" | toString -}}
{{- end -}}

{{/* "true" when the per-profile registries render (mode, user-namespace.modelRegistry.enabled, userNamespace.enabled). */}}
{{- define "kubeflow.modelRegistryDataPlane" -}}
{{- $on := eq (include "kubeflow.modelRegistryMode" .) "perProfile" -}}
{{- $unMR := dig "modelRegistry" (dict) (index .Values "user-namespace" | default dict) -}}
{{- if kindIs "bool" $unMR.enabled }}{{ $on = $unMR.enabled }}{{ end -}}
{{- if and $on .Values.userNamespace.enabled }}true{{ end -}}
{{- end -}}

{{/* First per-profile registry namespace, "" when none. Mirrors user-namespace.profileNamespace and
     .modelRegistry.namespaces; test/ci/check_model_registry_consistency.py keeps them in agreement. */}}
{{- define "kubeflow.modelRegistryFirstNamespace" -}}
{{- if include "kubeflow.modelRegistryDataPlane" . -}}
{{- $uns := index .Values "user-namespace" | default dict -}}
{{- $users := $uns.additionalUsers | default list -}}
{{- $extra := dig "modelRegistry" "extraNamespaces" list $uns -}}
{{- if ne (toString (dig "profile" "enabled" true $uns)) "false" -}}{{ dig "profile" "name" "kubeflow-user-example-com" $uns }}
{{- else if $users -}}{{ $u := first $users }}{{ $u.namespace | default ($u.email | lower | replace "." "-" | replace "@" "--") }}
{{- else if $extra -}}{{ first $extra }}
{{- end -}}
{{- end -}}
{{- end -}}
