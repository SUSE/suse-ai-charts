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

## Applying CRDs on upgrade (all sub-charts)

<a id="applying-crds"></a>

**Helm installs CRDs from `crds/` only on _first install_ — it never upgrades them.** After any chart
version bump that regenerates or adds CRDs (see the per-component notes below), apply every sub-chart's
CRDs **before** running `helm upgrade`:

```bash
find charts -path '*/crds/*.yaml' | xargs -I{} kubectl apply --server-side -f {}
```

Use `--server-side` — several regenerated CRDs exceed the client-side apply
`metadata.annotations` size limit and fail a plain `kubectl apply -f`. Add `--force-conflicts` if the
apply reports a field-ownership conflict.

If you skip this step the old CRD schema persists, and any manifest using a newly added field is either
**rejected** by the API server or has that field **silently pruned** on write — see the per-component
notes for the specific fields affected.

## Security — client identity-header spoofing fixed (upgrade recommended)

_Applies to chart version `0.4.0-alpha.2` and later._

This release closes an identity-spoofing gap in the gateway auth filter that affects **all** installs
(not just the KServe external-HTTPS opt-in). Previously a client could send Kubeflow identity headers
(`kubeflow-userid` and the `x-auth-request-email` / `-user` / `-groups` / `-preferred-username` family)
directly to the gateway; on request paths where ext_authz did not overwrite them, a downstream app
could trust the client-supplied value. The gateway now strips the entire client-supplied
identity-header family at ingress and re-derives `kubeflow-userid` from the authenticated
`x-auth-request-email` (using `replace()`, not `add()`), so identity is always gateway-authoritative.
**Operators running any prior release should upgrade.** No configuration change is required.

## Migration — Model Registry consolidated into Kubeflow Hub

_Applies to chart version `0.4.0-alpha.2` and later._

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

## Migration — KServe inference domain moved to `global.*`

_Applies to chart version `0.4.0-alpha.2` and later._

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

## Migration — KServe inference moved to a dedicated gateway

_Applies to chart version `0.4.0-alpha.2` and later._

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

## Behaviour change — `letsEncrypt` ClusterIssuer is now DNS-zone scoped

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

## Trainer CRDs realigned to v2.2.1 (manual `kubectl apply` required)

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

## Training Operator (V1) CRDs regenerated for DRA (manual `kubectl apply` required)

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

## Training operator webhook secret migration (auto)

On upgrade from chart versions prior to 0.3.0, a pre-upgrade hook automatically migrates the
`training-operator-webhook-cert` Secret from type `kubernetes.io/tls` to `Opaque`. No manual action is
required. If the hook fails (visible via `kubectl get jobs -n kubeflow`), delete the secret manually
and re-run `helm upgrade`:

```bash
kubectl delete secret training-operator-webhook-cert -n kubeflow --ignore-not-found
helm upgrade kubeflow charts/kubeflow -n kubeflow --force-conflicts --wait --timeout 15m
```

## Switching database engines or changing StorageClass

PVCs with `helm.sh/resource-policy: keep` are not deleted by Helm. When switching database images or
StorageClasses, delete the PVC manually first:

```bash
kubectl delete pvc -n kubeflow data-mysql-0   # KFP MariaDB (Rancher MariaDB StatefulSet)
kubectl delete pvc -n kubeflow katib-mysql    # Katib MariaDB (standalone Deployment)
```

## Credential rotation (SeaweedFS)

Changing `pipelines.seaweedfs.accessKey`/`secretKey` requires restarting all KFP Deployments that read
those credentials — pods do not automatically restart when a Secret changes:

```bash
kubectl rollout restart deployment -n kubeflow \
  ml-pipeline ml-pipeline-ui ml-pipeline-persistenceagent ml-pipeline-scheduledworkflow
kubectl rollout restart deployment -n kubeflow-user-example-com \
  ml-pipeline-ui-artifact
```

SeaweedFS IAM accumulates credentials across restarts (the `postStart` hook adds, never removes). To
clean stale entries after a rotation:

```bash
kubectl exec -n kubeflow deploy/seaweedfs -- \
  sh -c "printf 's3.configure -user <old-user> -access_key <old-key> -delete -apply\n' \
    | weed shell -master 127.0.0.1:9333"
```

> **`--reuse-values` gotcha:** `helm upgrade --reuse-values` does not update the `user-namespace` Secret
> with new SeaweedFS credentials. Always supply the full values file on upgrade, or patch the Secret
> manually afterward.

## SeaweedFS upgrade downtime

SeaweedFS uses a `Recreate` deployment strategy (single-node S3 store backed by a PVC). During
`helm upgrade`, the old pod is terminated before the new pod starts. Expect a brief window (10–60s)
where S3 artifact uploads and downloads are unavailable and in-flight pipeline runs may stall.
Recommended: quiesce active pipeline runs before upgrading.

## KServe inference hostname format (wildcard-TLS opt-in only)

**Scoped to the wildcard-TLS opt-in — default and plain-HTTP installs are unaffected.** The full
naming/collision caveat, the 63-char label limit, and the required DNS/client/SAN updates are covered
under [External HTTPS for KServe inference](access-and-tls.md#external-https-for-kserve-inference-opt-in).
In short: the opt-in flattens the Knative route host to `{name}-{namespace}.{domain}` (so one
`*.{domain}` wildcard cert covers it) and switches inference to `https` on `global.kserveDomain`; the
InferenceService `status.url` you call is unchanged (`{name}-{namespace}.{domain}`) in both modes. When
you enable it — or upgrade from a release that flattened the host unconditionally — update DNS records /
`/etc/hosts`, client URLs (switch `http`→`https` and to `global.kserveDomain`), and BYO-cert SANs (must
cover `*.<kserveDomain>`).
