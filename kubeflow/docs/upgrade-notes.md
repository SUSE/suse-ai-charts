# Upgrade Notes

[← Back to README](../README.md) · Related: [Installation](../README.md#installation) · [Accessing & TLS](access-and-tls.md) · [Troubleshooting](troubleshooting.md)

---

> **Always pass `--force-conflicts` (and `--server-side=true`) on upgrade** — see
> [why](../README.md#force-conflicts). From a source checkout, after editing any sub-chart's
> `Chart.yaml` version you must repackage before upgrading: run `helm dependency update charts/kubeflow`
> first (and `helm dependency update charts/apps/<chart-name>` if the bumped sub-chart itself has
> dependencies, e.g. kubeflow-pipelines). Avoid `helm upgrade --reuse-values` for the
> migrations below — it carries forward the old value tree and can miss new `global.*` structure;
> re-supply your full values file. If you no longer have it, recover the values you originally
> supplied with `helm get values kubeflow -n kubeflow -o yaml > current-values.yaml` — keep it to the
> **user-supplied** values (do **not** add `-a`/`--all`, which also dumps chart defaults and would
> re-pin you to the old ones). The file may contain secrets set via values, so handle it accordingly.

**How to use this page.** Notes are grouped by release, and each release has one subsection per area
of change. When upgrading across several releases, work through every release section above your
current version, oldest first. [Procedures for any upgrade](#procedures-for-any-upgrade) apply to
every release.

- [Upgrading to 0.6.0](#upgrading-to-060)
- [Upgrading to 0.5.0](#upgrading-to-050)
- [Upgrading to 0.4.x](#upgrading-to-04x) (`0.4.0-alpha.2`, `0.4.0`, `0.4.1`)
- [Procedures for any upgrade](#procedures-for-any-upgrade)

---

## Upgrading to 0.6.0

Multi-tenancy now matches upstream Kubeflow 26.03.1: one Model Registry per profile, Kubeflow
Pipelines' per-profile resources created by the KFP profile controller with per-profile artifact
credentials, and Pod Security Standards on profile namespaces when Istio runs with CNI.

**Before you upgrade:**

1. Check how Istio is installed and act on it — see [Istio CNI and Pod Security](#istio-cni).
2. Decide what happens to registered models: they are not migrated to the per-profile registries —
   see [Model Registry is now per-profile](#model-registry-per-profile).
3. If you set `hub.enabled: false`, also set `user-namespace.modelRegistry.enabled: false`.
4. Remove any `user-namespace.pipelines.*` overrides from your values file
   ([Removed and stricter values](#removed-and-stricter-values-060)).
5. Check your values file against the new render-time checks for the now-optional infrastructure
   sub-charts ([Optional infrastructure sub-charts](#optional-infrastructure-sub-charts-and-trainer-only-installs)).
6. If you run the Model Registry controller (`hub.controller.enabled: true`), set
   `hub.controller.env.registriesNamespace` to a profile namespace, or keep the old behaviour with
   `hub.controller.env.inferenceServiceController: "false"`
   ([Removed and stricter values](#removed-and-stricter-values-060)).

**After you upgrade:** restart metacontroller and give existing profiles their own artifact
credentials — see [KFP per-profile resources](#kfp-profile-controller). Add a per-InferenceService
policy to KServe models called from outside the cluster
([KServe models called from outside the cluster](#kserve-external-calls-060)).

### Model Registry is now per-profile (breaking)

<a id="model-registry-per-profile"></a>

To match upstream Kubeflow 26.03.1, the Model Registry now runs **one registry per profile namespace**
(server + Postgres) instead of one shared registry in `kubeflow`. The Model Registry UI stays a single
instance in `kubeflow`.

**Upgrading from `0.5.0` or earlier works, but there is no migration path for registered models.**
`helm upgrade` to `0.6.0` completes and per-profile registries come up, but:

- the shared registry in `kubeflow` is removed;
- each profile gets a new, **empty** registry;
- registered models from the previous release are **not migrated**. They stay in KFP's MariaDB
  (database `modelregistry`), unused. Nothing in the chart copies them into the per-profile registries.

Choose before upgrading:

- **No registered models to keep** (or you will re-register them): upgrade normally.
- **Keep the previous single registry and its models:** set `global.modelRegistry.mode: shared` in your
  values before upgrading. This is a legacy mode kept for compatibility. **`shared` is deprecated and
  will be removed in a future release** — upstream Kubeflow supports only per-profile registries — so
  treat it as a temporary bridge, not a long-term setting.

What changes for clients in per-profile mode:

| Client | `0.5.0` | `0.6.0` |
|---|---|---|
| Model Registry UI | `/model-registry/` | Unchanged; select the profile namespace in the UI |
| REST through the gateway | `/api/model_registry/v1alpha3/...` | `/api/model_registry/<profile>/v1alpha3/...` (the profile's owner and contributors only) |
| REST in-cluster | `model-registry-service.kubeflow.svc.cluster.local:8080` | `model-registry-service.<profile>.svc.cluster.local:8080`, from pods in that profile's namespace only |
| KServe `storageUri` (optional storage initializer) | `model-registry://<model>/<version>` | `model-registry://<model>/<version>?namespace=<profile>` (required) — see [KServe integration](optional-features.md#model-registry-kserve-integration) |

Notes:

- Registries are created for the example profile and every `user-namespace.additionalUsers[]` entry.
  Profiles created outside the chart get one only when listed in
  `user-namespace.modelRegistry.extraNamespaces`.

### Istio CNI and Pod Security on profile namespaces (breaking)

<a id="istio-cni"></a>

As upstream, the chart now assumes Istio **with the istio-cni plugin** (`global.istio.cni: true`):
profile namespaces enforce Pod Security `baseline` and are labelled `istio-injection: enabled`.
Istio ≥ 1.27 is required. Details: [Pod Security Standards on profile
namespaces](production-and-tenancy.md#9-pod-security-standards-on-profile-namespaces).

**Before upgrading, check how your Istio is installed** (`kubectl get daemonset -A | grep istio-cni-node`):

- **Istio without CNI (the previous `runMe.sh` default):** either keep it and set
  `global.istio.cni: false` in your values **before** upgrading — otherwise `helm upgrade` fails (with
  `helm template`, new pods in profile namespaces are rejected) — or switch Istio to CNI first:
  1. Upgrade Istio with the CNI values (same chart version and values as before, plus
     `-f istio-cni-values.yaml`; on K3s / Rancher Desktop also `--set global.platform=k3s`).
  2. Restart meshed workloads so they are re-injected without `istio-init`
     (`kubectl rollout restart deploy,statefulset -n <namespace>` for `kubeflow`, `knative-serving`
     and each profile namespace).
  3. Upgrade the Kubeflow chart.
- **Istio already with CNI:** no action.
- **`runMe.sh`:** re-running it switches Istio to CNI (unless `--no-istio-cni`); then do step 2 above.
- **Rendering with `helm template`:** set `global.istio.cni` explicitly (the chart cannot check the
  cluster), or enable `preflightChecks.enabled` if your tool runs Helm hooks.

Running pods are not evicted (Pod Security is checked at pod creation). If you later switch from
`true` to `false`, the chart removes the label from the namespaces it creates, but the profiles
controller does not remove labels it has set, so remove it from the other profile namespaces once
(this also removes a label you set yourself, e.g. `enforce: restricted`; re-apply those afterwards):

```bash
kubectl label namespace -l app.kubernetes.io/part-of=kubeflow-profile pod-security.kubernetes.io/enforce-
```

### KServe models called from outside the cluster

<a id="kserve-external-calls-060"></a>

Because profile namespaces are now Istio-injected, predictors get a sidecar the next time they
restart, and requests through the gateway return `403 RBAC: access denied` until the
InferenceService has its own ALLOW AuthorizationPolicy, as in upstream Kubeflow. See [Calling an
InferenceService from outside the
cluster](access-and-tls.md#calling-an-inferenceservice-from-outside-the-cluster). Calls from inside
the same profile are unaffected.

### Profile gateway access

The profiles controller now admits the gateway principal from
`global.istio.ingressGateway.principal` (Rancher Istio's `istio` ServiceAccount) in each profile's
`ns-owner-access-istio` policy, as upstream's controller supports. The chart's
`rancher-ingressgateway-access` AuthorizationPolicy is therefore removed, and profiles created with
`kubectl` or the dashboard are reachable through the gateway too. The profiles controller restarts
during the upgrade and updates every profile's policy; if a user gets `RBAC: access denied` right
after the upgrade, see
[Troubleshooting](troubleshooting.md#rbac-access-denied-for-user-namespace-traffic).

### KFP per-profile resources move to the KFP profile controller

<a id="kfp-profile-controller"></a>

To match upstream Kubeflow, the chart no longer renders Kubeflow Pipelines' per-profile objects into
profile namespaces. The KFP profile controller (part of the `pipelines` sub-chart) creates them in
every namespace labelled `pipelines.kubeflow.org/enabled=true`, and runs upstream KFP 2.17's logic.
What changes:

- **Each profile gets its own artifact-store credentials.** The `mlpipeline-minio-artifact` Secret in
  a profile namespace now holds a SeaweedFS access key for that profile only, limited to
  `private-artifacts/<profile>/`, `private/<profile>/`, `artifacts/` and `shared/` in the
  `mlpipeline` bucket. Previously every profile received the same full-access credentials, so any
  profile could read every other profile's artifacts.
- **New pipeline runs store artifacts under `private-artifacts/<profile>/`** (the per-profile
  `kfp-launcher` and `artifact-repositories` ConfigMaps).
- **No per-profile visualization server.** The single `ml-pipeline-visualizationserver` in `kubeflow`
  remains, as upstream.
- **The per-profile artifact proxy (`ml-pipeline-ui-artifact`) is off by default**, as upstream; the
  KFP UI reads artifacts directly. Set `pipelines.artifacts.proxyEnabled: true` to keep it.
- **New optional setting:** `pipelines.artifacts.retentionDays` deletes objects under
  `private-artifacts/` older than N days (`-1`, the default, keeps them; see the
  [Values Reference](values-reference.md#optional-features) for when it applies).
- **The controller keeps its per-profile Deployments, Services, DestinationRules and
  AuthorizationPolicies as it defines them** (in practice the optional artifact proxy), as upstream:
  manual edits to them are reverted. Secrets and ConfigMaps are created once and left alone.
- **Profiles created with `kubectl`** now get their KFP resources automatically (see
  [Production Hardening & Multi-tenancy](production-and-tenancy.md#adding-users-after-install)).
- **Removed values:** `user-namespace.pipelines.*` — see
  [Removed and stricter values](#removed-and-stricter-values-060).
- **Controller image:** the controller runs on the Application Collection image
  `dp.apps.rancher.io/containers/aws-cli` (`pipelines.profileController.image.*`, pulled with the
  `application-collection` secret); mirror it like the other Application Collection images.

**After the upgrade (required):**

1. **Resync the controller (pause pipeline runs first).** The upgrade removes the Helm-managed KFP
   objects from chart-created profiles; the controller recreates them only on its next sync,
   otherwise up to an hour later:

   ```bash
   kubectl rollout restart statefulset/metacontroller -n kubeflow
   ```

2. **Check that every profile got its own credentials.** Profiles that existed before the upgrade
   can still hold the shared admin key (also chart-created ones, recreated during the upgrade). On
   the sync from step 1 the controller deletes such a `mlpipeline-minio-artifact` Secret and creates
   a per-profile key in its place, usually within a minute. Resume pipeline runs once this lists no
   profile (it compares with the current admin key, so finish this before rotating the admin
   credentials):

   ```bash
   ADMIN=$(kubectl get secret mlpipeline-minio-artifact -n kubeflow -o jsonpath='{.data.accesskey}')
   for ns in $(kubectl get profiles.kubeflow.org -o jsonpath='{.items[*].metadata.name}'); do
     [ "$(kubectl get secret mlpipeline-minio-artifact -n "$ns" -o jsonpath='{.data.accesskey}')" = "$ADMIN" ] \
       && echo "$ns still has the admin key"
   done
   ```

   If a profile stays listed, delete its Secret (`kubectl delete secret mlpipeline-minio-artifact -n
   <profile>`); the controller then creates its key. Profiles created after the upgrade get their
   own key automatically.

**Existing artifacts:** artifacts from earlier runs stay in place and remain visible in the KFP UI.
KFP v2 outputs written before the upgrade (under `v2/artifacts/`) are outside the new per-profile
keys, so a new run that reuses a cached step from before the upgrade may fail to read that step's
outputs. Re-run such pipelines with caching disabled once.

### Removed and stricter values

<a id="removed-and-stricter-values-060"></a>

- `user-namespace.pipelines.*` is removed (the KFP profile controller creates the per-profile KFP
  objects). A leftover override fails the install with a "REMOVED VALUE KEY" message; set the
  SeaweedFS credentials only in `pipelines.seaweedfs.*`.
- `global.istio.ingressGateway.principal` must not be empty; the render fails if it is.
- **Model Registry controller (`hub.controller.enabled: true`):** in per-profile mode the
  InferenceService reconciler now defaults to `managed` (upstream default; earlier releases rendered
  `"false"`), so the controller starts recording InferenceServices in the registry, and the render
  fails unless `hub.controller.env.registriesNamespace` names a profile namespace. Set it, or set
  `hub.controller.env.inferenceServiceController: "false"` to keep the previous behaviour. See
  [Optional Features](optional-features.md#model-registry-kserve-integration). Shared mode is unchanged.

### Optional infrastructure sub-charts and trainer-only installs

Four sub-charts that always rendered can now be turned off. They default to `true`, so rendering with
your existing values is unchanged:

| New key | Sub-chart | Needs |
|---------|-----------|-------|
| `istioResources.enabled` | kubeflow-istio-resources | Istio CRDs |
| `admissionWebhook.enabled` | admission-webhook (PodDefaults) | cert-manager CRDs |
| `userNamespace.enabled` | user-namespace (default Profile + `additionalUsers`) | `profiles.enabled=true` |
| `kubeflowRoles.enabled` | kubeflow-roles (aggregated ClusterRoles) | - |

Together they allow a Trainer V2-only install without Istio or cert-manager, using the new
`trainer-only-overrides.yaml` preset; see [Trainer-only Install](use-cases/trainer-only-install.md).

Check your values file for these combinations, which now **fail at render time** instead of failing
(or half-working) during the install:

- **`profiles.enabled=false`** now also needs `userNamespace.enabled=false` (the default Profile needs
  the Profile CRD).
- **`profiles.enabled=true` with `kubeflowRoles.enabled=false`** is refused: Profiles and KFAM bind
  the `kubeflow-admin` / `kubeflow-edit` / `kubeflow-view` ClusterRoles that `kubeflowRoles` creates.
- **`externalSecrets.enabled=true`** (the default) now fails at install time if the External Secrets
  Operator API (`external-secrets.io/v1`) isn't on the cluster. Before, the install failed anyway,
  with `no matches for kind "ClusterExternalSecret"`.
  `helm template` doesn't run this check.
- **`networkPolicies.enabled=true` with `knativeServing.enabled=false`** now needs
  `network-policies.knativeServingPolicies.enabled=false` (the policies target the `knative-serving`
  namespace).
- **`istioResources.enabled=false`** requires every component that needs Istio to be disabled; the
  error lists the ones that are still on.

Other behaviour changes:

- The Trainer runtimes are applied by a Job using `dp.apps.rancher.io/containers/kubectl`, so every
  install needs the `application-collection` pull secret, and air-gapped clusters must mirror that
  image. The kserve-config helm test's kubectl moves from 1.34.5 to 1.36.2 to match.
- The demo-credential checks run only for components that use the credentials: `auth.oidc.*` when Dex
  or oauth2-proxy is enabled, `pipelines.seaweedfs.*` when pipelines are enabled. The inference-domain
  check only looks at the domain of whichever of Knative Serving / KServe is enabled.
- `helm test` Pods are rendered only for enabled components and now set `imagePullSecrets` from
  `global.imagePullSecrets`.
- The JobSet CRD now carries `helm.sh/resource-policy: keep`, so JobSets survive `helm uninstall`.
  It keeps the old release's ownership annotations, so **reinstall with the same release name and
  namespace**, or re-annotate the CRD (`meta.helm.sh/release-name`/`-namespace`) or set
  `trainer.jobset.installCRDs=false`.
- **The bundled ClusterTrainingRuntimes are no longer Helm hooks.** Recreating them on every upgrade
  hung on Trainer's `resource-in-use` finalizer whenever a TrainJob used one (`post-upgrade hooks
  failed: ClusterTrainingRuntime//torch-distributed still exists`). A post-install/post-upgrade Job
  (`kubeflow-trainer-runtimes-applier`) now server-side-applies them in place, takes over runtimes from
  older chart versions, and deletes bundled runtimes no longer in the chart (they are labelled
  `app.kubernetes.io/managed-by: kubeflow-trainer-runtimes-applier`). Upgrades work with TrainJobs
  present. `trainer.runtimes.enabled=false` removes them (not with tools that render the chart
  offline, where the Job can't see them); `helm uninstall` leaves them in place.
  Runtimes created by older chart versions (as hooks) aren't labelled yet: if you disable them in
  the same upgrade, delete them once yourself (`kubectl delete clustertrainingruntime
  torch-distributed deepspeed-distributed mlx-distributed`, plus the torchtune ones if enabled).
- **`trainer.runtimes.enabled=false` now also turns off the TorchTune runtimes.** Before,
  `trainer.runtimes.torchtune.enabled=true` applied them regardless.
- **New `trainer.runtimes.istioSidecar` for the bundled runtimes' pod templates.** In an
  Istio-injected namespace a regular sidecar outlives the training container, so pods never complete.
  `disabled` (default) sets `sidecar.istio.io/inject: "false"` (pods leave the mesh); `native` sets
  `sidecar.istio.io/nativeSidecar: "true"` (pods complete inside the mesh); `default` sets nothing.
  `trainer.runtimes.podAnnotations` adds more. Your own runtimes are not changed.

## Upgrading to 0.5.0

### Kubernetes ≥ 1.35 required (Knative Serving/Eventing v1.24.0)

The Knative Serving and Eventing images moved to **v1.24.0**, whose controllers hard-gate on the
cluster Kubernetes version and refuse to start on anything older than **1.35.0** (the binary logs
`kubernetes version "<v>" is not compatible, need at least "1.35.0-0"` and crash-loops). The umbrella
chart's `kubeVersion` floor has therefore been raised **`>=1.31.0-0` → `>=1.35.0-0`**, so
`helm install`/`upgrade` now fails fast on older clusters instead of letting Knative crash-loop
post-install. (The previous `1.31` floor came from the Training Operator DRA requirement and is still
satisfied.) Upgrade the cluster to Kubernetes ≥ 1.35 before installing this release. As an escape
hatch Knative honours the `KUBERNETES_MIN_VERSION` env var, but running v1.24.0 below its supported
floor is unsupported.

### Native Istio ext_authz is now the default ingress-auth mode

<a id="behaviour-change--native-istio-ext_authz-is-now-the-default-ingress-auth-mode"></a> <!-- legacy anchor -->

The ingress gateway now enforces OIDC login with **upstream-parity native Istio ext_authz** by default
(`global.oauth2Proxy.gatewayAuthMode: native`) instead of the legacy self-contained `EnvoyFilter`. The
native mode adds a `RequestAuthentication` (Dex JWT) plus a `CUSTOM` ext_authz and a `DENY` require-jwt
`AuthorizationPolicy` on the shared ingress gateway, and requires istiod's MeshConfig to register the
`oauth2-proxy` extension provider (`runMe.sh` wires this in; manual installs pass
`-f istio-native-authz-values.yaml` to the Istio install). See
[Ingress gateway authentication mode](../README.md#ingress-gateway-authentication-mode).

> **⚠ BREAKING for external, cookie-less KServe inference over the shared gateway.** The native
> `require-jwt` `DENY` policy denies any request without a verified JWT request-principal on all paths
> except `/dex/*` and `/oauth2/*`. A cookie-less external inference `POST` to a KServe
> `InferenceService` served on the **shared** ingress gateway now returns `403` — a change from the
> legacy EnvoyFilter mode. **KServe in-cluster traffic is unaffected** (it uses the dedicated
> `kserve-ingress-gateway` cluster-local gateway). If you depend on unauthenticated external inference
> over the shared gateway, either serve it via the dedicated KServe gateway / wildcard-TLS opt-in (see
> [External HTTPS for KServe inference](access-and-tls.md#external-https-for-kserve-inference-opt-in)) or
> keep the legacy EnvoyFilter mode by installing with `--legacy-authz` (`runMe.sh`) or
> `-f values-envoyfilter-authz.yaml`. The two modes are mutually exclusive. Combining native authz with
> the KServe wildcard-TLS opt-in must be scoped and verified before enabling both together.

**No action required** for installs that do not expose unauthenticated external inference on the shared
gateway. To stay on the previous behaviour, select the legacy EnvoyFilter mode as above.

### OIDC credentials in one Secret; mismatched credential copies fail the render

<a id="behaviour-change--oidc-credentials-in-one-secret-mismatched-credential-copies-fail-the-render"></a> <!-- legacy anchor -->

`auth.oidc.clientSecret` and `auth.oidc.cookieSecret` previously reached Dex and oauth2-proxy through
YAML anchors in `values.yaml`, which `-f`/`--set` overrides do not follow, so an override changed only
`auth.oidc.*` and both components kept the demo values. The chart now writes them to a
`kubeflow-oidc-client` Secret (keys `client-id`, `client-secret`, `cookie-secret`) that Dex and
oauth2-proxy both read, so overrides reach both. This Secret replaces the `kubeflow-oauth2-proxy` Secret
that the oauth2-proxy sub-chart used to create; set `auth.oidc.existingSecret: true` to supply
`kubeflow-oidc-client` yourself.

The render now also fails, instead of deploying a broken login or pipeline storage, when:
- a component-level copy set directly (`oauth2-proxy.config.clientSecret` / `cookieSecret`,
  `dex.oidcClientSecret`, a Dex static-client `secret`) differs from `auth.oidc.*`;
- `pipelines.seaweedfs.accessKey` / `secretKey` is overridden without the matching
  `user-namespace.pipelines.seaweedfs.*` value (previously the user-namespace copy silently kept the
  demo credentials; this copy is removed in 0.6.0);
- `auth.oidc.cookieSecret` is not 16, 24 or 32 bytes (raw or URL-safe base64), which oauth2-proxy
  rejects at start-up.

**Action:** if you override these credentials, set them in `auth.oidc.*` (and both SeaweedFS keys), and
remove any direct `oauth2-proxy.config.clientSecret` / `cookieSecret` overrides. After an upgrade that
changes the OIDC secrets, restart Dex and oauth2-proxy so they pick up the new Secret.

### SeaweedFS now runs as non-root (uid/gid 1000)

The SeaweedFS pod now runs with an explicit restricted security context —
`runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`,
`fsGroupChangePolicy: OnRootMismatch`, `seccompProfile: RuntimeDefault`, `privileged: false`
— matching the upstream community-distribution manifest. The repackaged `4.51` image previously
relied on a root entrypoint (`chown`/`su-exec`) that crash-looped once capabilities were dropped;
running as `1000` up front skips that privileged step, and `fsGroup: 1000` makes the `/data` PVC
group-writable so the non-root process can still write.

**Action required only if you override `pipelines.seaweedfs.image` with a custom image:** it must be
able to run as uid/gid **1000** with all capabilities dropped — i.e. it must **not** depend on
starting as root to `chown` the data directory or to drop privileges itself. (The root filesystem
stays writable; `readOnlyRootFilesystem` is intentionally not set, matching upstream.) Stock `chrislusf/seaweedfs`
and the SUSE-repackaged image both satisfy this. On upgrade of an existing install, `fsGroup` relabels
the PVC on first start where the top-level ownership does not already match 1000 (`OnRootMismatch`), so
expect a one-time startup delay proportional to the data size; no manual `chown` is needed.

---

## Upgrading to 0.4.x

Covers `0.4.0-alpha.2`, `0.4.0` and `0.4.1`. The changes below arrived in `0.4.0-alpha.2` unless
stated otherwise.

### Security — client identity-header spoofing fixed (upgrade recommended)

This release closes an identity-spoofing gap in the gateway auth filter that affects **all** installs
(not just the KServe external-HTTPS opt-in). Previously a client could send Kubeflow identity headers
(`kubeflow-userid` and the `x-auth-request-email` / `-user` / `-groups` / `-preferred-username` family)
directly to the gateway; on request paths where ext_authz did not overwrite them, a downstream app
could trust the client-supplied value. The gateway now strips the entire client-supplied
identity-header family at ingress and re-derives `kubeflow-userid` from the authenticated
`x-auth-request-email` (using `replace()`, not `add()`), so identity is always gateway-authoritative.
**Operators running any prior release should upgrade.** No configuration change is required.

### Model Registry consolidated into Kubeflow Hub

<a id="migration--model-registry-consolidated-into-kubeflow-hub"></a> <!-- legacy anchor -->

The separate `model-registry` and `kubeflow-hub` subcharts have been merged into a single
**`kubeflow-hub`** chart, where "Hub" (formerly Model Registry) is the umbrella component bundling the
Model Registry and the Model Catalog. The `kubeflow-hub` subchart deploys **one shared** Model Registry
in the `kubeflow` namespace serving all profiles.

**Action required:** rename any `modelRegistry.*` values to `hub.*` in your overrides.

```yaml
# before
modelRegistry:
  enabled: true
  catalog:
    enabled: false

# after
hub:
  enabled: true
  catalog:
    enabled: false
```

Notes:
- `hub.enabled` defaults to `true`, so default installs are unaffected.
- Kubernetes resource names (`model-registry-*`) and routes (`/api/model_registry/`,
  `/model-registry/`) are unchanged — no dashboard or client changes needed.
- All Hub component **images** are aligned to community-distribution **release-26.03.1** and pinned to
  **v0.3.10** under the renamed `hub/*` path: `hub/server` (also reused by the Model Catalog),
  `hub/ui`, `hub/controller`, and `hub/storage-initializer` (previously the UI/controller/storage-initializer
  used `model-registry/*` at v0.3.7).
- The registry server liveness/startup probes now use `/readyz/isDirty` (readiness stays
  `/readyz/health`), matching release-26.03.1.
- Catalog PostgreSQL dependency bumped `0.5.5` → `0.6.0` (PostgreSQL 18.3 → 18.4, same major version —
  no data migration).
- `hub.enabled=true` still requires `pipelines.enabled=true` (shares KFP's MariaDB).

### KServe inference domain moved to `global.*`

<a id="migration--kserve-inference-domain-moved-to-global"></a> <!-- legacy anchor -->

The KServe/Knative inference domain now has one home under **`global.kserveDomain`** — the enforced
single source of truth. External HTTPS for inference is an opt-in flag **`global.kserveExternalHttps`**.
The old knobs — `_kserveAccess.domain` and hand-set `kserve.urlScheme` / `kserve.ingressDomain` /
`knativeServing.domain` / `knativeServing.domainTemplate` — are gone or auto-derived.

**Non-breaking by default.** `global.kserveDomain` defaults to `""`, and the subchart-local
`knativeServing.domain` / `kserve.ingressDomain` default to `example.com`, so an install that
customized none of them is unchanged: plain-HTTP inference keeps KServe's default
`{name}-{namespace}.{domain}` `status.url` host, served over HTTP.

> **⚠ BREAKING for installs that set `knativeServing.domain` or `kserve.ingressDomain`.** If you
> previously set either subchart key (or `_kserveAccess.domain`) to a custom value **without**
> `global.kserveDomain`, `helm upgrade` now **hard-fails** at render time with a `DIVERGENCE:` error
> naming the fix. The old keys reach the Knative/KServe configs but not the dedicated
> `kserve-ingress-gateway`'s hosts, so the previous behaviour silently stranded inference at
> `READY=Unknown`. **Before upgrading**, add `global.kserveDomain: <your-domain>` set to the same
> value. A bare `domain:` / `ingressDomain:` (empty or null) is also rejected, since it renders an
> empty Knative domain.

**Action required only if you customized the domain or use the old knobs:**

```yaml
# before
_kserveAccess:
  domain: mycompany.com
knativeServing:
  domain: mycompany.com
kserve:
  ingressDomain: mycompany.com

# after
global:
  kserveDomain: mycompany.com
```

Notes:
- A leftover `_kserveAccess.domain` key is **silently ignored** (the schema does not reject unknown
  keys), so a typo or a stale key produces no error — it just has no effect.
- **Enabling `global.kserveExternalHttps: true` is a scoped breaking change.** It flattens the Knative
  route host from `{name}.{namespace}.{domain}` to `{name}-{namespace}.{domain}` and switches inference
  URLs to `https` on `global.kserveDomain`; the InferenceService `status.url` keeps KServe's
  `{name}-{namespace}.{domain}` host in both modes. Requires `global.kserveDomain` plus a DNS-01
  solver. Update DNS records, client URLs (scheme/domain), and BYO-cert SANs accordingly. See
  [External HTTPS for KServe inference](access-and-tls.md#external-https-for-kserve-inference-opt-in)
  for the single-label naming caveat.

### KServe inference moved to a dedicated gateway

<a id="migration--kserve-inference-moved-to-a-dedicated-gateway"></a> <!-- legacy anchor -->

KServe/Knative inference no longer shares the dashboard's `kubeflow-gateway`. The chart now renders a
**dedicated `kserve-ingress-gateway`** (in the `kubeflow` namespace) and points net-istio at it via
`config-istio`, so the readiness prober only probes that gateway's ports. This fixes the net-istio
`EOF` / `Ready=Unknown` stall that occurred when inference and a TLS-terminating dashboard shared one
gateway (the prober tried the dashboard's `:443` on inference hosts). The dashboard's
`kubeflow-gateway` is now dashboard-only.

The gateway reference is a single value, **`global.kserveGateway.name`** (default
`kubeflow/kserve-ingress-gateway`), which threads through three places that must stay in sync: the
Gateway CR rendered by `kubeflow-istio-resources`, the `config-istio` `gateway.<namespace>.<name>` key,
and kserve's `inferenceservice-config` `ingressGateway`.

**Non-breaking by default.** Fresh installs get the dedicated gateway automatically; inference serves
on plain `:80` (or `:443` with `global.kserveExternalHttps: true`) exactly as before, just on its own
gateway. Override `global.kserveGateway.name` only if you need a different namespace/name (e.g.
`infra/my-kserve-gw`).

> **Upgrading a live release that previously shared the gateway:** the pre-existing `kubeflow-gateway`
> may still carry a leftover `http-kserve` `*:80` server and any Knative ingress VirtualServices may
> still bind it. After `helm upgrade`, confirm inference VirtualServices bind `kserve-ingress-gateway`
> (`kubectl get virtualservice -A -o yaml | grep gateways -A2`) and that `kubeflow-gateway` no longer
> lists a KServe `:80` server. A pre-existing gateway created outside Helm must be adopted or removed
> so Helm can own the new one.

### KServe inference hostname format (wildcard-TLS opt-in only)

**Scoped to the wildcard-TLS opt-in — default and plain-HTTP installs are unaffected.** The full
naming/collision caveat, the 63-char label limit, and the required DNS/client/SAN updates are covered
under [External HTTPS for KServe inference](access-and-tls.md#external-https-for-kserve-inference-opt-in).
In short: the opt-in flattens the Knative route host to `{name}-{namespace}.{domain}` (so one
`*.{domain}` wildcard cert covers it) and switches inference to `https` on `global.kserveDomain`; the
InferenceService `status.url` you call is unchanged (`{name}-{namespace}.{domain}`) in both modes. When
you enable it — or upgrade from a release that flattened the host unconditionally — update DNS records /
`/etc/hosts`, client URLs (switch `http`→`https` and to `global.kserveDomain`), and BYO-cert SANs (must
cover `*.<kserveDomain>`).

### `letsEncrypt` ClusterIssuer is now DNS-zone scoped

<a id="behaviour-change--letsencrypt-clusterissuer-is-now-dns-zone-scoped"></a> <!-- legacy anchor -->

_Applies to chart version `0.4.0-alpha.2` and later. Affects `tls.source: letsEncrypt` installs._

The chart-managed `kubeflow-letsencrypt` ClusterIssuer previously emitted a **selector-less
(catch-all) solver** — it would solve ACME challenges for *any* DNS name, including out-of-chart
`Certificate` resources that referenced it. It is now scoped with a `dnsZones` **selector** seeded with
the dashboard host (`kubeflow-istio-resources.hostname`, falling back to `kubeflow.local`) plus
`global.kserveDomain` when the wildcard opt-in is on.

This is a **silent behaviour change**: after upgrading, an out-of-chart `Certificate` that pointed at
`kubeflow-letsencrypt` for a name **outside** those zones will no longer be solved by this issuer and
its order will stall (no matching solver) — with no chart-level error. If you rely on
`kubeflow-letsencrypt` for other names, either add those zones by setting
`kubeflow-istio-resources.hostname` / `global.kserveDomain` to cover them, or (recommended) create your
own dedicated ClusterIssuer for out-of-chart certificates. Note the `dnsZones` selector is a solver
*selector*, not an authorization control — gate `Certificate` creation with RBAC.

### Trainer CRDs realigned to v2.2.1 (manual `kubectl apply` required)

_Applies to `trainer` sub-chart `0.2.0` and later. Affects any install with `trainer.enabled: true`._

The three `trainer.kubeflow.org` CRDs (`trainjobs`, `clustertrainingruntimes`, `trainingruntimes`) were
**out of sync with the deployed Trainer controller** (`appVersion v2.2.1`, image
`trainer-controller-manager:v2.2.1`) and are now regenerated from a single upstream **v2.2.1**
controller-gen run. This is a schema realignment, not a controller change — the image stays `v2.2.1`.
Concretely:

- **`TrainJob`**: `spec.podTemplateOverrides`, `spec.labels`, and `spec.annotations` are **removed**;
  `spec.runtimePatches` and `spec.activeDeadlineSeconds` are the v2.2.1 replacements. The old fields
  were already **inert** under the v2.2.1 controller (it has honored `runtimePatches` since v2.2.1),
  but the previously-shipped CRD still *advertised* them. **The API server prunes unknown fields**, so
  any stored `TrainJob` that still carries `podTemplateOverrides` / `spec.labels` / `spec.annotations`
  will lose those values on its next write. They had no effect under v2.2.1 regardless; migrate any
  pod-level customization to `spec.runtimePatches`.
- **`ClusterTrainingRuntime` / `TrainingRuntime`**: the ML-policy schema is realigned to v2.2.1 — adds
  the `flux` and `jax` runtime policies and replaces the old Torch `elasticPolicy` (HPA-metrics) shape.
  The previously-shipped runtime CRDs were stale here.

On an existing install the *old* stored CRDs persist after `helm upgrade`, so a manifest using
`spec.runtimePatches` (or the new runtime policies) is **rejected by the API server** until you apply
the new CRDs — see [Applying CRDs on upgrade](#applying-crds). Do this **before** creating any
`runtimePatches` TrainJob or the updated runtimes (the e2e suite's `runtimePatches` manifest depends
on it).

### Training Operator (V1) CRDs regenerated for DRA (manual `kubectl apply` required)

_Applies to chart version `0.4.0-alpha.2` and later (`training-operator` sub-chart `0.3.0` and later,
via [PR #35](https://github.com/SUSE/suse-ai-charts/pull/35)). Affects any install with
`trainingOperator.enabled: true`._

> **This is the Training Operator V1** (`kubeflow.org` API — TFJob, PyTorchJob, etc.), a **different**
> component from the Trainer V2 (`trainer.kubeflow.org`) covered in the section above. Both ship CRDs
> that Helm will not upgrade for you, so both need a manual apply.

The six `kubeflow.org` job CRDs (`tfjobs`, `pytorchjobs`, `xgboostjobs`, `paddlejobs`, `mpijobs`,
`jaxjobs`) were **regenerated from upstream kubeflow/trainer v1.9.4** (controller-gen `v0.10.0` →
`v0.16.5`), and the operator image / `appVersion` moved `v1.9.2` → `v1.9.4` so the running binary
matches the schema. Concretely:

- **Dynamic Resource Allocation (DRA) for GPU workloads.** The regenerated CRDs add
  `spec.*.template.spec.resourceClaims` and `resources.claims`, enabling DRA. **DRA structured
  parameters require Kubernetes ≥ 1.31**, and the sub-chart now carries a `kubeVersion: >=1.31.0-0`
  guard — `helm install`/`upgrade` will refuse to render on older clusters.
- **MXJob is removed.** The `mxjobs.kubeflow.org` CRD and its `mxjobs` / `mxjobs/status` RBAC rules
  (in the `kubeflow-training-edit` / `kubeflow-training-view` ClusterRoles) are dropped — upstream
  removed MXNet support. Migrate any remaining MXJob workloads off before upgrading; the CRD removal
  does not delete stored `MXJob` objects, but nothing will reconcile them.

On an existing install the *old* CRDs persist after `helm upgrade`, so the new fields (e.g.
`resourceClaims`) are silently pruned by the API server until you apply the new CRDs — see
[Applying CRDs on upgrade](#applying-crds).

---

## Procedures for any upgrade

### Applying CRDs on upgrade (all sub-charts)

<a id="applying-crds"></a>

**Helm installs CRDs from `crds/` only on _first install_ — it never upgrades them.** After any chart
version bump that regenerates or adds CRDs (see the per-release notes above), apply every sub-chart's
CRDs **before** running `helm upgrade`. Run this in the chart directory of the version you upgrade to
(`helm pull oci://registry.suse.com/ai/charts/kubeflow --version <version> --untar`). A packaged chart
holds its sub-charts as `.tgz` files, so they are unpacked first; third-party dependencies (cert-manager,
Dex, external-dns, External Secrets Operator, oauth2-proxy) manage their own CRDs and are skipped:

```bash
d=$(mktemp -d)
for t in charts/*.tgz; do
  case "$t" in */cert-manager-*|*/dex-idp-*|*/external-dns-*|*/external-secrets-operator-*|*/oauth2-proxy-*) continue ;; esac
  tar -xzf "$t" -C "$d"
done
find charts "$d" -path '*/crds/*.yaml' | xargs -I{} kubectl apply --server-side -f {}
```

Use `--server-side` — several regenerated CRDs exceed the client-side apply
`metadata.annotations` size limit and fail a plain `kubectl apply -f`. Add `--force-conflicts` if the
apply reports a field-ownership conflict.

If you skip this step the old CRD schema persists, and any manifest using a newly added field is either
**rejected** by the API server or has that field **silently pruned** on write — see the per-release
notes above for the specific fields affected.

### Training operator webhook secret migration (automatic)

<a id="training-operator-webhook-secret-migration-auto"></a> <!-- legacy anchor -->

A pre-upgrade hook runs on every upgrade and migrates the `training-operator-webhook-cert` Secret from
type `kubernetes.io/tls` to `Opaque` when needed. It only changes anything on installs that predate
chart `0.3.0`; for every published release (`0.3.1` and later) it is a no-op. No manual action is
required. If the hook fails (visible via `kubectl get jobs -n kubeflow`), delete the secret manually
and re-run `helm upgrade`:

```bash
kubectl delete secret training-operator-webhook-cert -n kubeflow --ignore-not-found
helm upgrade kubeflow charts/kubeflow -n kubeflow --force-conflicts --wait --timeout 15m
```

### Switching database engines or changing StorageClass

PVCs with `helm.sh/resource-policy: keep` are not deleted by Helm. When switching database images or
StorageClasses, delete the PVC manually first:

```bash
kubectl delete pvc -n kubeflow data-mysql-0   # KFP MariaDB (Rancher MariaDB StatefulSet)
kubectl delete pvc -n kubeflow katib-mysql    # Katib MariaDB (standalone Deployment)
```

From `0.6.0`, each profile namespace also has a kept Model Registry database PVC (embedded Postgres).
Deleting it **deletes that profile's registered models**:

```bash
kubectl delete pvc -n <profile> metadata-postgres   # per-profile Model Registry (0.6.0+)
```

### Postgres major versions

A Postgres major version cannot read the data directory of an older one, and the embedded Postgres
keeps its data on PVCs: each profile's Model Registry database (`metadata-postgres`) and, with
`hub.catalog.enabled`, the Model Catalog's. The chart therefore pins the major version (currently
18; CI fails if it changes by accident). A release that moves to a new major says so in its notes;
then dump each profile's database with the old version and restore it after the upgrade:

```bash
# 1. Before the upgrade (old version), for each profile with a registry:
kubectl exec -n <profile> deploy/model-registry-db -- \
  sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > <profile>.dump
# 2. Remove the old data (Helm keeps the PVC), then run helm upgrade, which recreates both:
kubectl delete deployment -n <profile> model-registry-db
kubectl delete pvc -n <profile> metadata-postgres
# 3. After the upgrade, once model-registry-db is Ready:
kubectl exec -i -n <profile> deploy/model-registry-db -- \
  sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner' < <profile>.dump
```

### Credential rotation (SeaweedFS)

**Admin credentials (`pipelines.seaweedfs.accessKey` / `secretKey`).** Changing them requires
restarting the Deployments that read them — pods do not automatically restart when a Secret changes:

```bash
kubectl rollout restart deployment -n kubeflow \
  ml-pipeline ml-pipeline-ui ml-pipeline-persistenceagent ml-pipeline-scheduledworkflow
# 0.6.0 and later: the KFP profile controller uses the admin identity to create per-profile keys
kubectl rollout restart deployment -n kubeflow kubeflow-pipelines-profile-controller
# 0.5.0 and earlier only: the per-profile artifact proxy also read the shared credentials
kubectl rollout restart deployment -n kubeflow-user-example-com ml-pipeline-ui-artifact
```

**Per-profile keys (0.6.0 and later).** Each profile's `mlpipeline-minio-artifact` Secret holds its own
SeaweedFS key, created by the KFP profile controller for an IAM user named after the profile. Rotating
the admin credentials does **not** change these keys. To rotate a profile's key, delete its Secret
(when no pipeline runs are in progress); the controller creates a new key within about a minute:

```bash
kubectl delete secret mlpipeline-minio-artifact -n <profile>
```

The controller revokes the profile's previous key once the new Secret exists (on its next sync,
usually within seconds). It also replaces a Secret whose key SeaweedFS no longer has.

**Removing stale admin credentials.** SeaweedFS IAM keeps every admin credential the `postStart` hook
has added (it adds, never removes). To remove an old one:

```bash
kubectl exec -n kubeflow deploy/seaweedfs -- \
  sh -c "printf 's3.configure -user <old-user> -access_key <old-key> -delete -apply\n' \
    | weed shell -master 127.0.0.1:9333" >/dev/null
```

`s3.configure` prints the **whole** identity configuration after applying, including every user's
secret key, which is why the output is discarded above — do not drop the redirect or paste that
output into tickets or logs. To check the result, test the old key instead (an S3 request with it
returns `InvalidAccessKeyId` once it is removed).

> **`--reuse-values` gotcha (0.5.0 and earlier):** `helm upgrade --reuse-values` does not update the
> `user-namespace` copy of the SeaweedFS credentials. Always supply the full values file on upgrade, or
> patch the per-profile Secret manually afterward. From `0.6.0` there is no such copy: the credentials
> are set only in `pipelines.seaweedfs.*`.

### SeaweedFS upgrade downtime

SeaweedFS uses a `Recreate` deployment strategy (single-node S3 store backed by a PVC). During
`helm upgrade`, the old pod is terminated before the new pod starts. Expect a brief window (10–60s)
where S3 artifact uploads and downloads are unavailable and in-flight pipeline runs may stall.
Recommended: quiesce active pipeline runs before upgrading.
