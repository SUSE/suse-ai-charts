# Kubeflow Helm Chart

End-to-end Machine Learning platform on Kubernetes, packaged as a single Helm umbrella chart.
Targets **Rancher / RKE2** clusters using images from the SUSE AI Library.

> **Note:** This chart requires an active [SUSE AI](https://www.suse.com/products/ai/) subscription
> to pull images from `dp.apps.rancher.io` and `registry.suse.com`. The chart source code itself is Apache 2.0.

---

## Components

The chart installs the Kubeflow platform — Central Dashboard, Notebooks, Pipelines, Katib, KServe with
Knative Serving, Model Registry, Trainer V2, Training Operator V1, TensorBoard and Volumes — behind an
Istio gateway with Dex and oauth2-proxy login. See [Components](docs/components.md) for every component,
its switch, chart and namespace.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Kubernetes | >= 1.35 | Required by Knative Serving/Eventing v1.24.0; tested on RKE2 / K3s |
| Helm | >= 4.0.1 | The install uses server-side apply (`--server-side`, `--force-conflicts`) |
| cert-manager | 1.20.2 | Installed by `runMe.sh`; or pre-install manually |
| Istio | mesh ≥ 1.27 (chart 1.3.0) | `1.3.0` is the SUSE AppCo **chart** version installed by `runMe.sh`. The mesh must be Istio ≥ 1.27 (native sidecars, so Jobs and pipeline steps with a sidecar complete). |
| Istio CNI plugin | recommended (default) | `runMe.sh` installs Istio with istio-cni; without it set `global.istio.cni: false` (`runMe.sh --no-istio-cni`). See [Istio CNI and Pod Security](docs/production-and-tenancy.md#9-pod-security-standards-on-profile-namespaces) |
| Load balancer (e.g. MetalLB) | — | For LoadBalancer access to the Istio gateway and for a hostname with external-dns. Tested with MetalLB v0.15.3 |
| Default StorageClass | — | Local Path Provisioner (dev) or Longhorn (prod) |
| SUSE Application Collection credentials | — | Username + token for `dp.apps.rancher.io` (application-collection secret) |
| SUSE Registry credentials | — | Username + token for `registry.suse.com` (suse-ai-registry secret) |

**Storage class:** All PVCs use the cluster default StorageClass unless `global.storageClass` is set.
For single-node clusters the Local Path Provisioner is sufficient for development; for production,
Longhorn is recommended.

> **Note:** make sure a default StorageClass is set for the cluster before installing. Run
> `kubectl get storageclass` and confirm one has the `(default)` designation next to its name.
> Otherwise designate one, e.g.:
> ```bash
> kubectl patch storageclass local-path \
>   -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
> ```

**Cloudflare API token:** Only required for automatic DNS record management via `external-dns`.
When using Let's Encrypt as the issuer for the Gateway TLS certificate, `external-dns` is required
for DNS-01 challenges.

---

## Installation

There are two installation modes; both end up running the same `helm upgrade --install`, so `runMe.sh`
simply automates the steps before it.

| Mode | When to use |
|------|------------|
| [`runMe.sh`](#mode-1--automated-via-runmesh) | Fastest path — automates all prerequisite steps. Good for dev, demos, and CI. |
| [Manual Helm (OCI)](#mode-2--manual-helm-install-oci-recommended-for-production) | **Recommended for production.** Install directly from the OCI registry — no source checkout or `helm dependency update` required. |

Prerequisite for either mode: a RKE2 cluster with a default StorageClass configured (see
[Prerequisites](#prerequisites)).

### Mode 1 — Automated via `runMe.sh`

`runMe.sh` runs the prerequisite steps and then installs the Kubeflow chart:

1. Checks that the cluster is reachable and runs Kubernetes ≥ 1.35, and that Helm ≥ 4 is installed
2. Performs Helm registry logins for `dp.apps.rancher.io` and `registry.suse.com`, and packages sub-charts
   via `helm dependency build` (the versions `Chart.lock` pins)
3. Stops if an existing release would lose components (and their data), e.g. when a values file used
   before is left out
4. Creates namespaces: `cert-manager`, `istio-system`, `kubeflow`, `knative-serving`
5. Creates `application-collection` and `suse-ai-registry` image pull secrets in `istio-system`, `kubeflow`, `knative-serving`, and `cert-manager`. Profile namespaces (`kubeflow-user-example-com` and others) receive these secrets automatically through the External Secrets Operator (ESO), which step 9 installs.
6. Labels the `kubeflow` and `knative-serving` namespaces for Helm ownership
7. Installs cert-manager from `oci://dp.apps.rancher.io/charts/cert-manager`
8. Installs Istio from `oci://dp.apps.rancher.io/charts/istio` with the gateway and the istio-cni plugin enabled (`--no-istio-cni` skips the plugin)
9. Installs External Secrets Operator and waits for CRDs to be established
10. Installs the Kubeflow umbrella chart

Fastest path for dev/demo — install with NodePort access and the demo credentials from
`demo-overrides.yaml` (**never use it in production**):

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> -f demo-overrides.yaml
```

The script prints the access URL when it finishes. Log in with the demo credentials:

```
Email:    user@example.com
Password: 12341234
```

> **These are demo defaults — change them before any production or networked use.** See
> [Production Hardening](docs/production-and-tenancy.md#production-hardening).

Without `demo-overrides.yaml` the install generates the credentials (the login password, the OIDC
client and cookie secrets and the SeaweedFS keys) and prints how to read the password. Pass your own
values file for anything else; see [Configuration Scenarios](docs/access-and-tls.md#configuration-scenarios):

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> -f my-values.yaml
```

`runMe.sh` installs the `full` preset. To install a subset of the components, run `install.sh` with a
preset from `presets/`, e.g. notebooks, Central Dashboard and Trainer. It takes the credentials from
the environment variables below and the same options as `runMe.sh`, and installs only the
prerequisites the chosen components need (Istio, cert-manager, ESO); `./install.sh --help` lists the
presets and options:

```bash
./install.sh --preset notebooks-trainer -f my-values.yaml
```

<details>
<summary><strong>Full argument reference</strong></summary>

```bash
./runMe.sh <appco-registry-username> <appco-registry-token> regcode <suse-ai-registry-token> \
  [--kubeconfig <path-to-kubeconfig>] \
  [--cloudflare-api-key <CF-API-KEY>] \
  [-f <path-to-values-override.yaml>]
```

| Argument | Env var alternative | Description |
|----------|---------------------|-------------|
| `<appco-registry-username>` | `APPCO_REGISTRY_USER` | SUSE Application Collection username (for `dp.apps.rancher.io`) |
| `<appco-registry-token>` | `APPCO_REGISTRY_TOKEN` | SUSE Application Collection token / password (for `dp.apps.rancher.io`) |
| `<suse-ai-registry-username>` | `SUSE_AI_REGISTRY_USER` | SUSE Registry username (default: `regcode`) |
| `<suse-ai-registry-token>` | `SUSE_AI_REGISTRY_TOKEN` | SUSE Registry token / password (for `registry.suse.com`) SCC_REG_CODE for AI |
| `--kubeconfig <path>` | `KUBECONFIG` | Path to kubeconfig (defaults to `~/.kube/config`, or KUBECONFIG environment variable if set) |
| `--cloudflare-api-key <key>` | `CLOUDFLARE_API_KEY` | Creates `cloudflare-api-key` Secret in `kubeflow` and `cert-manager` namespaces |
| `-f <file>` / `--values-file <file>` | — | Path to a values override YAML file passed to `helm upgrade` |
| `--disable-cert-manager` | — | Do not upgrade/install cert-manager, use an existing one instead |
| `--no-istio-cni` | — | Install Istio **without** the istio-cni plugin (classic `istio-init` sidecars) and set `global.istio.cni=false`, so profile namespaces get no Pod Security Standards label. For clusters that cannot run istio-cni. (`runMe.sh` sets `global.istio.cni` itself, overriding your `-f` files.) |
| `--legacy-authz` | — | Use the legacy self-contained EnvoyFilter ingress-auth mode instead of the default Istio-native ext_authz. See [Ingress gateway authentication mode](docs/access-and-tls.md#ingress-gateway-authentication-mode). |
| `--suse-registry=<mirror>` | — | SUSE AI registry mirror (default: `registry.suse.com`); redirects all `registry.suse.com/*` image pulls and the registry login |
| `--oci`, `--chart-version <v>`, `--chart-ref <ref>` | — | Install the released chart (default `oci://registry.suse.com/ai/charts/kubeflow`) instead of this checkout, with the install script that chart ships |
| `--suse-app-collection=<mirror>` | — | Application Collection mirror (default: `dp.apps.rancher.io`); redirects all `dp.apps.rancher.io/*` image pulls, the registry login, and the cert-manager / Istio / ESO OCI chart URLs |

</details>

<details>
<summary><strong>Mirror / air-gapped registry usage</strong></summary>

To redirect images through an internal mirror registry, pass both flags:

```bash
./runMe.sh <appco-username> <appco-token> regcode <suse-ai-token> \
  --suse-registry=<mirror> \
  --suse-app-collection=<mirror>
```

`--suse-app-collection` redirects: the `dp.apps.rancher.io` registry login, the `application-collection`
pull secret, the cert-manager / Istio / ESO OCI chart installs, and sets
`global.suseApplicationCollectionRegistry` on the Kubeflow helm install so all pod images resolve from
the mirror.
`--suse-registry` redirects: the `registry.suse.com` registry login, the `suse-ai-registry` pull secret,
and sets `global.suseRegistry` on the Kubeflow helm install.
Mirror `dp.apps.rancher.io/containers/kubectl` even for trainer-only installs: the Job that applies the
Trainer runtimes uses it.

See [Registry Overrides](docs/values-reference.md#registry-overrides) for the full precedence model.

</details>

### Mode 2 — Manual Helm install (OCI, recommended for production)

The chart is published to the SUSE Registry OCI endpoint — no source checkout or `helm dependency
update` required.

> **Note:** using the latest versions of the helm charts is recommended.

#### Step 1 — Helm registry login and chart files

Helm reads the tokens on stdin rather than as arguments, so they don't show in the process list:

```bash
export APPCO_REGISTRY_USER=<appco-registry-username> APPCO_REGISTRY_TOKEN=<appco-registry-token>
export SUSE_AI_REGISTRY_USER=regcode SUSE_AI_REGISTRY_TOKEN=<suse-ai-registry-token>

# SUSE Application Collection registry
printf '%s' "$APPCO_REGISTRY_TOKEN" | helm registry login dp.apps.rancher.io \
  --username "$APPCO_REGISTRY_USER" --password-stdin

# SUSE Registry
printf '%s' "$SUSE_AI_REGISTRY_TOKEN" | helm registry login registry.suse.com \
  --username "$SUSE_AI_REGISTRY_USER" --password-stdin
```

Pull the chart once for the files the later steps use (the Istio values, the presets and the
`values-envoyfilter-authz.yaml` overlay); this creates `./kubeflow`:

```bash
helm pull oci://registry.suse.com/ai/charts/kubeflow --version 0.7.0 --untar
```

#### Step 2 — Create namespaces

```bash
for ns in cert-manager istio-system kubeflow knative-serving; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

> **Required:** release name `kubeflow` in namespace `kubeflow`. The login flow (Dex, oauth2-proxy, the
> gateway auth policies and the istiod provider) refers to `kubeflow-dex` and `kubeflow-oauth2-proxy` there.

> **Note:** `kubeflow-user-example-com` and all other user namespaces are created by the Kubeflow chart
> and receive registry pull secrets automatically via ESO — no manual creation needed.

#### Step 3 — Create image pull secrets

Create secrets only in the static system namespaces, with the variables from Step 1. ESO propagates them to user namespaces
automatically — it copies `suse-ai-registry` and `application-collection` from the `kubeflow`
namespace into every user namespace labelled `app.kubernetes.io/part-of: kubeflow-profile`, including
namespaces created dynamically by the profiles controller at runtime.

```bash
# application-collection pull secret (SUSE Application Collection — dp.apps.rancher.io)
for ns in cert-manager istio-system kubeflow knative-serving; do
  kubectl create secret docker-registry application-collection \
    --docker-server=dp.apps.rancher.io \
    --docker-username="$APPCO_REGISTRY_USER" \
    --docker-password="$APPCO_REGISTRY_TOKEN" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# suse-ai-registry pull secret (SUSE Registry — registry.suse.com)
for ns in cert-manager istio-system kubeflow knative-serving; do
  kubectl create secret docker-registry suse-ai-registry \
    --docker-server=registry.suse.com \
    --docker-username="$SUSE_AI_REGISTRY_USER" \
    --docker-password="$SUSE_AI_REGISTRY_TOKEN" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

#### Step 4 — Label namespaces for Helm

The release adopts the namespaces created in Step 2 that it also defines (`kubeflow`, `knative-serving`);
it creates the profile namespaces itself.

```bash
for ns in kubeflow knative-serving; do
  kubectl label namespace "$ns" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl annotate namespace "$ns" \
    meta.helm.sh/release-name=kubeflow \
    meta.helm.sh/release-namespace=kubeflow \
    --overwrite
done
```

#### Step 5 — Install cert-manager

```bash
helm upgrade --install cert-manager oci://dp.apps.rancher.io/charts/cert-manager \
  --version 1.20.2 \
  --namespace cert-manager \
  --set crds.enabled=true \
  --set crds.keep=true \
  --set global.imagePullSecrets[0].name=application-collection \
  --wait --timeout 5m
```

#### Step 6 — Install Istio

```bash
# istio-native-authz-values.yaml: native ingress auth mode (default) — see "Ingress auth mode" below
# istio-cni-values.yaml:          istio-cni plugin (default) — see "Istio CNI" below
helm upgrade --install istio oci://dp.apps.rancher.io/charts/istio \
  --version 1.3.0 \
  --namespace istio-system \
  --set global.imagePullSecrets[0].name=application-collection \
  --set gateway.enabled=true \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 5m \
  -f kubeflow/istio-native-authz-values.yaml \
  -f kubeflow/istio-cni-values.yaml
```

> **Istio CNI:** with CNI on K3s / Rancher Desktop, add `--set global.platform=k3s` to the Istio command
> above. Omit `-f kubeflow/istio-cni-values.yaml` only for classic `istio-init`, and then install Kubeflow with
> `--set global.istio.cni=false`. See
> [Pod Security Standards on profile namespaces](docs/production-and-tenancy.md#9-pod-security-standards-on-profile-namespaces).

> **Ingress auth mode:** the chart defaults to Istio-native ext_authz
> (`global.oauth2Proxy.gatewayAuthMode: native`), which requires istiod's MeshConfig
> to register the `oauth2-proxy` extension provider — that is exactly what
> `-f kubeflow/istio-native-authz-values.yaml` adds here. Omit that `-f` **only** if you also
> install Kubeflow with `-f kubeflow/values-envoyfilter-authz.yaml` (legacy EnvoyFilter mode).
> See [Ingress gateway authentication mode](docs/access-and-tls.md#ingress-gateway-authentication-mode).

#### Step 7 — Install External Secrets Operator

ESO must be installed before the Kubeflow chart so its CRDs are present when Helm applies the
`ClusterSecretStore` and `ClusterExternalSecret` resources.

```bash
helm upgrade --install external-secrets-operator oci://dp.apps.rancher.io/charts/external-secrets-operator \
  --version 2.6.0 \
  --namespace kubeflow \
  --set installCRDs=true \
  --set global.imagePullSecrets[0].name=application-collection \
  --wait --timeout 5m
```

#### Step 8 — Install Kubeflow

Install directly from the OCI registry. Add `-f <values>.yaml` for your own values, and, to install a
subset of the components, a preset from the pulled chart first (for example
`-f kubeflow/presets/notebooks-trainer.yaml`; see [Components](docs/components.md)):

> **Ingress auth:** the default native mode needs **nothing extra here** — its only prerequisite is the istiod extension provider added in Step 6 (`-f kubeflow/istio-native-authz-values.yaml`). Add `-f kubeflow/values-envoyfilter-authz.yaml` only if you opted into the legacy EnvoyFilter mode (Step 6 without that `-f`). See [Ingress gateway authentication mode](docs/access-and-tls.md#ingress-gateway-authentication-mode).

```bash
helm upgrade --install kubeflow \
  oci://registry.suse.com/ai/charts/kubeflow \
  --version 0.7.0 \
  -n kubeflow \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 15m
```

The chart generates the login password and the other credentials on first install (see
[Values Reference](docs/values-reference.md#credentials)). Log in as `user@example.com` with:

```bash
kubectl -n kubeflow get secret kubeflow-initial-user -o jsonpath='{.data.password}' | base64 -d
```

> <a id="force-conflicts"></a>**Why `--force-conflicts`?** cert-manager-cainjector, istiod
> (pilot-discovery), and the clusterrole-aggregation-controller modify fields (caBundle, webhook
> failurePolicy, aggregated RBAC rules) that Helm tracks. This flag lets Helm reclaim ownership of
> those fields on each install/upgrade, so **always pass it** (and `--server-side=true`) for both
> install and upgrade.

<details>
<summary><strong>Using a mirror / air-gapped registry (Mode 2)</strong></summary>

Substitute the mirror hostname in each `oci://` URL, update the `--docker-server` in the pull secrets,
and pass the `global.suseApplicationCollectionRegistry` / `global.suseRegistry` values to the Kubeflow
chart (see [Registry Overrides](docs/values-reference.md#registry-overrides)):

```bash
MIRROR=mirror.corp.example.com MIRROR_USER=<username> MIRROR_TOKEN=<token>

printf '%s' "$MIRROR_TOKEN" | helm registry login "${MIRROR}" --username "$MIRROR_USER" --password-stdin

# cert-manager, Istio, ESO from mirror
helm upgrade --install cert-manager oci://${MIRROR}/charts/cert-manager ...
helm upgrade --install istio oci://${MIRROR}/charts/istio ...
helm upgrade --install external-secrets-operator oci://${MIRROR}/charts/external-secrets-operator ...

# Pull secrets pointing at mirror
kubectl create secret docker-registry application-collection --docker-server="${MIRROR}" ...
kubectl create secret docker-registry suse-ai-registry       --docker-server="${MIRROR}" ...

# Kubeflow chart + images from mirror
helm upgrade --install kubeflow oci://${MIRROR}/ai/charts/kubeflow \
  --version 0.7.0 -n kubeflow \
  --set global.suseApplicationCollectionRegistry="${MIRROR}" \
  --set global.suseRegistry="${MIRROR}" \
  --force-conflicts --server-side=true --wait --timeout 15m
```

</details>

<details>
<summary><strong>Installing from source (development / contributing only)</strong></summary>

From the root of a checkout of this repository, after Steps 2–7: build the sub-chart dependencies
(the versions `Chart.lock` pins), then install from the local path. `./kubeflow/install.sh --preset
full` does all of Steps 1–8 from a checkout.

```bash
helm dependency build kubeflow
helm upgrade --install kubeflow ./kubeflow \
  -n kubeflow \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 15m
```

</details>

After installing, work through
[Production Hardening](docs/production-and-tenancy.md#production-hardening) before any production or
networked use.

---

## Uninstall

`helm uninstall` deletes the `kubeflow` and `knative-serving` namespaces with everything in them —
including PVCs marked `keep` (pipeline data, artifacts, backups) and any other release installed
there (e.g. External Secrets Operator) — and the profile namespaces the chart created. Back up what
you need first. A pre-delete hook deletes the Profiles the chart created (the example profile and
`additionalUsers`) while the profiles controller still runs, so their finalizers don't block the
uninstall; deleting a Profile deletes its namespace.

```bash
helm uninstall kubeflow -n kubeflow
```

With `--no-hooks`, or if the hook reports Profiles still terminating, delete them yourself while the
profiles controller runs: `kubectl delete profiles.kubeflow.org kubeflow-user-example-com <additionalUsers namespaces>`.

CRDs are left in place.

---

## Trainer-only install

To deploy only Kubeflow Trainer V2 (TrainJob / TrainingRuntime / ClusterTrainingRuntime) with JobSet,
without Istio, cert-manager, Dex/oauth2-proxy, Profiles or KFP, follow
[Trainer-only Install](docs/use-cases/trainer-only-install.md). It uses the `presets/trainer-only.yaml`
preset and walks through the install, verification with a sample TrainJob, and upgrade/uninstall caveats.

---

## Additional documentation

| Guide | Contents |
|-------|----------|
| [Components](docs/components.md) | Every component: its switch, chart, namespace and purpose; the add-ons |
| [Accessing & TLS / Configuration Scenarios](docs/access-and-tls.md) | Port-forward / NodePort / LoadBalancer access, hostname + TLS scenarios (self-signed, Let's Encrypt, BYO cert, existing external-dns/cert-manager), external HTTPS for KServe inference, ingress gateway authentication mode (native / EnvoyFilter) |
| [Trainer-only Install](docs/use-cases/trainer-only-install.md) | Installing only Trainer V2 + JobSet (no Istio, cert-manager, Profiles or KFP): values, install, sample TrainJob, upgrade/uninstall |
| [Values Reference](docs/values-reference.md) | Every configurable value — globals, credentials, component toggles, storage, networking, registry overrides |
| [Optional Features](docs/optional-features.md) | Model Registry KServe integration (storage initializer, InferenceService controller) |
| [Production Hardening & Multi-tenancy](docs/production-and-tenancy.md) | Credential rotation, external IdP, NetworkPolicies, backups, HA, resource quotas, adding users / profiles |
| [Upgrade Notes](docs/upgrade-notes.md) | Version migrations, breaking changes, and required manual steps per release |
| [Testing, Troubleshooting & Known Limitations](docs/troubleshooting.md) | Smoke / e2e / helm tests, common failure fixes, and known constraints |

