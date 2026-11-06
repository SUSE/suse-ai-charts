# Trainer-only Install

[← Back to README](../../README.md) · Related: [Values Reference](../values-reference.md#component-toggles) · [Troubleshooting](../troubleshooting.md)

This guide installs **only Kubeflow Trainer V2** (`TrainJob`, `TrainingRuntime`,
`ClusterTrainingRuntime`) and **JobSet** from the Kubeflow umbrella chart, without the rest of the
Kubeflow platform.

---

## What gets installed

The Trainer and JobSet controllers, CRDs and webhooks in the `kubeflow` namespace, the bundled
ClusterTrainingRuntimes (`torch-distributed`, `deepspeed-distributed`, `mlx-distributed`), the
`kubeflow-trainer-{admin,edit,view}` ClusterRoles and a `helm test` Pod. Nothing else from Kubeflow
is rendered: no Istio or cert-manager resources, no Dex/oauth2-proxy, no Profiles, no dashboard or
other components. **You don't need cert-manager, Istio or the External Secrets Operator.**

> **Don't use `runMe.sh` for this install.** It always installs Istio and the External Secrets Operator.
> Follow the steps below, or use `installTrainerOnly.sh`.

**Shortcut for dev/test clusters:** `installTrainerOnly.sh`, in the chart root (also included in the
packaged chart), runs Steps 1–6 for you, and Step 7 with `--sample`. It requires Helm 4 and refuses to
convert an existing `kubeflow` release that isn't trainer-only unless you pass `--force`.

```bash
export APPCO_REGISTRY_USER=<appco-registry-username> APPCO_REGISTRY_TOKEN=<appco-registry-token>
export SUSE_AI_REGISTRY_USER=regcode SUSE_AI_REGISTRY_TOKEN=<suse-ai-registry-token>
./installTrainerOnly.sh --sample                       # from a chart checkout
./installTrainerOnly.sh --chart-version <chart-version> # or install the released OCI chart
./installTrainerOnly.sh --help                         # all options
```

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Kubernetes | >= 1.35 | The chart's `kubeVersion` gate applies to every install, trainer-only included. Trainer itself would run on >= 1.32. |
| Helm | >= 4.0.1 | Needed for OCI chart support and `--server-side` |
| SUSE Application Collection credentials | - | Username and token for `dp.apps.rancher.io`. The Job that applies the bundled runtimes pulls `containers/kubectl` from there. Not needed with `trainer.runtimes.enabled=false` on a fresh install. |
| SUSE Registry credentials | - | Registration code for `registry.suse.com` (the Trainer, JobSet and runtime images) |

Note: The bundled runtimes don't create PVCs.

---

## Step 1: Log in to the Helm registries

```bash
# SUSE Application Collection
helm registry login dp.apps.rancher.io \
  --username=<appco-registry-username> \
  --password=<appco-registry-token>

# SUSE Registry (hosts the kubeflow chart)
helm registry login registry.suse.com \
  --username=regcode \
  --password=<suse-ai-registry-token>
```

---

## Step 2: Create and label the kubeflow namespace

The chart must be installed into the **`kubeflow`** namespace (the trainer templates hardcode it), and
it manages the Namespace object itself. Create the namespace up front with Helm ownership metadata so
Helm can adopt it. **Don't use `--create-namespace`**: the install then fails with *"Namespace kubeflow
exists and cannot be imported into the current release"*.

```bash
RELEASE=kubeflow   # must match the release name used in Step 5

kubectl create namespace kubeflow --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace kubeflow app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate namespace kubeflow \
  meta.helm.sh/release-name="$RELEASE" \
  meta.helm.sh/release-namespace=kubeflow \
  --overwrite
```

The chart labels the namespace `istio-injection: enabled`, which has no effect without Istio. If Istio
is installed anyway, the bundled runtimes opt out of sidecar injection
(`trainer.runtimes.istioSidecar`, default `disabled`). Add `sidecar.istio.io/inject: "false"` to any
runtime you write yourself.

---

## Step 3: Create image pull secrets

The chart references the secrets `application-collection` and `suse-ai-registry` in the `kubeflow`
namespace by default (`global.imagePullSecrets`).

```bash
kubectl create secret docker-registry application-collection \
  --docker-server=dp.apps.rancher.io \
  --docker-username=<appco-registry-username> \
  --docker-password=<appco-registry-token> \
  -n kubeflow --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry suse-ai-registry \
  --docker-server=registry.suse.com \
  --docker-username=regcode \
  --docker-password=<suse-ai-registry-token> \
  -n kubeflow --dry-run=client -o yaml | kubectl apply -f -
```

These secrets cover only pods in `kubeflow`. Training pods run in the TrainJob's own namespace and need
their own pull secret. See [Step 7](#step-7-run-a-sample-trainjob).

---

## Step 4: Get the values file

The chart ships the preset **`trainer-only-overrides.yaml`** in its root. It keeps Trainer and turns
everything else off; its comments explain each switch. Take it from a chart checkout, or from the
released chart:

```bash
helm pull oci://registry.suse.com/ai/charts/kubeflow --version <chart-version> --untar
cp kubeflow/trainer-only-overrides.yaml .
```

Put your own settings in a second values file (`-f trainer-only-overrides.yaml -f my-values.yaml`)
rather than editing the preset, so you can take a newer copy on upgrade. You don't need
`global.demoMode` or demo-credential overrides.

---

## Step 5: Install the chart

```bash
helm upgrade --install "$RELEASE" \
  oci://registry.suse.com/ai/charts/kubeflow \
  --version <chart-version> \
  -n kubeflow \
  -f trainer-only-overrides.yaml \
  --force-conflicts \
  --server-side=true \
  --wait --timeout 10m
```

Use a chart version `0.6.0 or above` that includes the trainer-only switches. On older versions Helm silently ignores
them, and the install fails on missing Istio or cert-manager CRDs.

`--force-conflicts --server-side=true` lets Helm take back fields that the Trainer and JobSet
controllers write at runtime, such as the webhook `caBundle`. Pass them on every install and upgrade
(see [Why `--force-conflicts`?](../../README.md#force-conflicts)).

From a source checkout, run `helm dependency build ./kubeflow` and install `./kubeflow` instead of the
OCI reference.

---

## Step 6: Verify the installation

```bash
# Both controllers Ready
kubectl get deploy -n kubeflow
# NAME                                  READY
# jobset-controller-manager             1/1
# kubeflow-trainer-controller-manager   1/1

# Bundled runtimes (empty if trainer.runtimes.enabled=false)
kubectl get clustertrainingruntimes

# Chart test: checks the trainer controller's metrics and health endpoints
helm test "$RELEASE" -n kubeflow
```

---

## Step 7: Run a sample TrainJob

TrainJobs run in any namespace. This example uses `team-a`.

**1. Create the namespace and let its pods pull SUSE images.** The runtime pod templates don't set
`imagePullSecrets`, so attach the secret to the namespace's `default` ServiceAccount, which the
training pods use:

```bash
kubectl create namespace team-a
kubectl create secret docker-registry suse-ai-registry \
  --docker-server=registry.suse.com \
  --docker-username=regcode \
  --docker-password=<suse-ai-registry-token> \
  -n team-a
kubectl patch serviceaccount default -n team-a \
  -p '{"imagePullSecrets":[{"name":"suse-ai-registry"}]}'
```

If the External Secrets Operator is installed, the chart can copy the pull secrets into labelled
namespaces instead (you still attach them to the ServiceAccount):

```yaml
# my-values.yaml
externalSecrets:
  enabled: true
  imagePullSecrets:
    secrets:
      - name: suse-ai-registry           # training pods need only this one
  namespaceSelector:
    matchLabels:
      app.kubernetes.io/part-of: null    # keep: drops the default Profile-namespace label
      suse.com/trainjob-pull-secrets: "true"
```

Helm merges your `matchLabels` with the chart default, so without the `null` line a namespace would
need both labels. Anyone who can set the label receives the registry credentials, so choose a label
only admins can set (in Rancher, project owners can edit their namespaces' labels).

**2. Give users access** (skip this if you run as cluster-admin). There are no Profiles, so bind the
trainer ClusterRoles directly:

```bash
kubectl create rolebinding alice-trainer-edit -n team-a \
  --clusterrole=kubeflow-trainer-edit --user=alice@example.com
```

**3. Submit a TrainJob** on the bundled `torch-distributed` runtime (CPU is enough), using the minimal
example the chart ships:

```bash
kubectl apply -n team-a -f kubeflow/tutorial/trainer/trainjob_torch_hello.yaml
kubectl get trainjob torch-hello -n team-a -w
kubectl logs -n team-a -l jobset.sigs.k8s.io/jobset-name=torch-hello --tail=20
```

The TrainJob reaches `Complete`, and the logs show the PyTorch version and `sum 9.0`. For your own
jobs, start from that file and change `spec.trainer.command` (plus `image` and `resourcesPerNode`).

---

## Optional configuration

Set these in your own values file (passed after `-f trainer-only-overrides.yaml`) or with `--set`.

| Key | Default | Use it when |
|-----|---------|-------------|
| `trainer.runtimes.enabled` | `true` | Set `false` if you ship your own ClusterTrainingRuntimes, for example when an admission policy only allows your runtimes: the bundled ones would still show up in `list_runtimes()`, but TrainJobs using them would be refused. On an existing install, the next upgrade removes the bundled runtimes; with tools that render the chart offline, delete them yourself (see [Upgrade and uninstall](#upgrade-and-uninstall)). |
| `trainer.runtimes.torchtune.enabled` | `false` | Adds the TorchTune LLM fine-tuning runtimes (Llama 3, Qwen 2.5). These need GPUs and a HuggingFace token, and `trainer.runtimes.enabled=true`. |
| `trainer.jobset.installCRDs` | `true` | Set `false` if the JobSet CRD is already installed by another release. |
| `trainer.jobset.controller.enabled` | `true` | Set `false` if a JobSet controller (>= v0.11) already runs on the cluster. |
| `global.imagePullSecrets` | `[application-collection, suse-ai-registry]` | Change this if your pull secrets in `kubeflow` have different names. |
| `global.suseRegistry` / `global.suseApplicationCollectionRegistry` | `""` | Mirror or air-gapped registries. Besides the `registry.suse.com` images, mirror `dp.apps.rancher.io/containers/kubectl` (runtimes applier Job) and `containers/bci-busybox` (`helm test`). See [Registry Overrides](../values-reference.md#registry-overrides). |
| `networkPolicies.enabled` | `false` | Deny-all ingress NetworkPolicies for `kubeflow`. Also set `network-policies.knativeServingPolicies.enabled=false`, since `knative-serving` doesn't exist here. |

**Scheduler:** the bundled runtimes use the default kube-scheduler. To use another scheduler (for
example KAI Scheduler), ship your own ClusterTrainingRuntimes that set `schedulerName` and set
`trainer.runtimes.enabled=false`.

---

## Adding other Kubeflow components later

The trainer-only switches are ordinary values. To grow the install into the full platform, install
cert-manager and Istio first (see [Installation](../../README.md#installation)), remove the
corresponding `false` entries from your values file and upgrade. The chart refuses combinations that
would install half-working, and its error says what to enable or disable. The notebook controller is
the one component allowed without Istio, with `notebook-controller.configMapData.USE_ISTIO="false"`.

---

## Upgrade and uninstall

**Upgrade:** rerun the Step 5 command with the new `--version` and the same values files. TrainJobs
can keep running: a post-upgrade Job (`kubeflow-trainer-runtimes-applier`) updates the bundled
runtimes in place and deletes bundled runtimes that are no longer enabled (for example after
`trainer.runtimes.torchtune.enabled=false`, or all of them after `trainer.runtimes.enabled=false`).

Helm **never updates the Trainer CRDs on upgrade**. When a release notes a Trainer CRD change, apply
them before upgrading:

```bash
helm pull oci://registry.suse.com/ai/charts/kubeflow --version <chart-version> --untar
kubectl apply --server-side -f kubeflow/charts/trainer/crds/
```

**Uninstall:** `helm uninstall "$RELEASE" -n kubeflow` keeps the Trainer and JobSet CRDs, so TrainJobs
and JobSets survive; reinstall with the same release name to adopt the kept JobSet CRD. The bundled
runtimes also stay. Delete them with
`kubectl delete clustertrainingruntime -l app.kubernetes.io/managed-by=kubeflow-trainer-runtimes-applier`;
a runtime still used by a TrainJob stays `Terminating` until that TrainJob is deleted. To remove
everything, delete your TrainJobs, then the CRDs (`trainjobs`, `trainingruntimes` and
`clustertrainingruntimes.trainer.kubeflow.org`, `jobsets.jobset.x-k8s.io`).

---

## Limitations

- **Namespace:** the release namespace must be `kubeflow`.
- **Kubernetes version:** the chart requires >= 1.35 even for trainer-only installs.
- **Training pod pull secrets** aren't propagated by default; see Step 7.
- **Multi-tenancy:** there are no Profiles, so namespaces and RoleBindings are managed by you or by
  your platform.
- **Gang scheduling** of multi-node TrainJobs depends on your scheduler. The bundled runtimes don't
  configure `podGroupPolicy`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Namespace "kubeflow" ... exists and cannot be imported into the current release` | The namespace was created without Helm ownership metadata (for example with `--create-namespace`). | Run the commands from [Step 2](#step-2-create-and-label-the-kubeflow-namespace), with the same release name. |
| `no matches for kind "Gateway"` / `"Certificate"` / `"Profile"` | The chart version predates the trainer-only switches. | Use a newer chart version. |
| `helm install` fails with `failed post-install: ... timed out waiting for the condition` | The `kubeflow-trainer-runtimes-applier` Job can't pull `kubectl` from `dp.apps.rancher.io`: `application-collection` is missing or wrong in `kubeflow`. | Recreate it (Step 3) and rerun `helm upgrade --install`. |
| Controller or `helm test` pods stay in `ImagePullBackOff` | `suse-ai-registry` (controllers) or `application-collection` (`helm test`) is missing or wrong in `kubeflow`. | Recreate it (Step 3), then delete the pods or rerun `helm test`. |
| Training pods stay in `ImagePullBackOff` | The TrainJob namespace has no pull secret for `registry.suse.com`. | See [Step 7](#step-7-run-a-sample-trainjob). |
| TrainJob is refused by an admission webhook or policy | Your platform's policy only allows its own runtimes. | Use an allowed runtime, and set `trainer.runtimes.enabled=false` to hide the bundled ones. |
| TrainJob stays `Created` with no pods | The JobSet controller isn't running, or a different JobSet controller owns the CRD. | `kubectl get deploy jobset-controller-manager -n kubeflow` and check the trainer controller logs. |
