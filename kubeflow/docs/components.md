# Components

[← Back to README](../README.md) · Related: [Installation](../README.md#installation) · [Values Reference](values-reference.md)

---

Every component has a switch (its toggle) and installs into the namespace shown. An install preset
(`presets/*.yaml`) turns a supported set on; each preset's `# components:` header lists them.
`components.yaml` records what each component needs (Istio, cert-manager, other components), and the
chart refuses combinations that would not work.

Chart sources: **local** = a sub-chart in this repository; **AppCo** = SUSE Application Collection
(`oci://dp.apps.rancher.io/charts`).

| Component | Toggle (default) | Chart | Namespace | Purpose |
|-----------|------------------|-------|-----------|---------|
| **Platform** | | | | |
| Istio resources | `istioResources.enabled` (on) | local `kubeflow-istio-resources` | kubeflow, istio-system | Gateways, VirtualServices and gateway authentication policies |
| Dex | `dex.enabled` (on) | AppCo `dex-idp` 0.24.1 | kubeflow | OIDC identity provider |
| oauth2-proxy | `global.oauth2Proxy.enabled` (on) | AppCo `oauth2-proxy` 10.7.0 | kubeflow | Login broker and session cookie for the gateway |
| Profiles & KFAM | `profiles.enabled` (on) | local `profiles-and-kfam` | kubeflow | Multi-tenancy: Profile namespaces and access management |
| Kubeflow roles | `kubeflowRoles.enabled` (on) | local `kubeflow-roles` | cluster-scoped | `kubeflow-admin`/`-edit`/`-view` ClusterRoles used by Profiles |
| User namespace | `userNamespace.enabled` (on) | local `user-namespace` | kubeflow-user-example-com, `additionalUsers` | Example profile, extra profiles, per-profile Model Registry servers |
| Central Dashboard | `centralDashboard.enabled` (on) | local `central-dashboard` | kubeflow | Web UI shell |
| Admission Webhook | `admissionWebhook.enabled` (on) | local `admission-webhook` | kubeflow | PodDefault mutating webhook |
| **Notebooks** | | | | |
| Notebook Controller | `notebooks.controller.enabled` (on) | local `notebook-controller` | kubeflow | Notebook CRD controller |
| Jupyter Web App | `notebooks.webApp.enabled` (on) | local `jupyter-web-app` | kubeflow | Notebook creation UI |
| **Training** | | | | |
| Trainer V2 | `trainer.enabled` (on) | local `trainer` | kubeflow | TrainJob / TrainingRuntime / ClusterTrainingRuntime (`trainer.kubeflow.org`), with JobSet |
| Training Operator V1 | `trainingOperator.enabled` (on) | local `training-operator` | kubeflow | TFJob / PyTorchJob / etc. (`kubeflow.org`) |
| Katib | `katib.enabled` (on) | local `katib` (MariaDB inline) | kubeflow | Hyperparameter tuning |
| **Pipelines** | | | | |
| Kubeflow Pipelines | `pipelines.enabled` (on) | local `kubeflow-pipelines` | kubeflow | ML workflow engine (KFP v2), with MariaDB (AppCo `mariadb` 0.1.7) and SeaweedFS (S3-compatible artifact store) |
| **Serving** | | | | |
| KServe | `kserve.enabled` (on) | local `kserve`, `models-web-app` | kubeflow | Model serving and its UI |
| Knative Serving | `knativeServing.enabled` (on) | local `knative-serving` | knative-serving | Serverless layer for KServe's Knative mode |
| Knative Eventing | `knativeEventing.enabled` (off) | local `knative-eventing` | knative-eventing | Event-driven pipeline triggers |
| **Model Registry, TensorBoard, Volumes** | | | | |
| Model Registry | `hub.enabled` (on) | local `kubeflow-hub` | kubeflow (UI), each profile namespace (server + DB) | Model versioning and metadata, one registry per profile |
| TensorBoard Controller | `tensorboard.controller.enabled` (on) | local `tensorboard-controller` | kubeflow | TensorBoard CRD controller |
| TensorBoards Web App | `tensorboard.webApp.enabled` (on) | local `tensorboards-web-app` | kubeflow | TensorBoard UI |
| Volumes Web App + PVCViewer | `volumesWebApp.enabled` (on) | local `volumes-web-app`, `pvcviewer-controller` | kubeflow | PVC management UI and file browser |

**Add-ons** (off by default; not Kubeflow components, so presets leave them as they are):

| Add-on | Toggle | Chart | Purpose |
|--------|--------|-------|---------|
| NetworkPolicies | `networkPolicies.enabled` | local `network-policies` | Deny-by-default ingress NetworkPolicies (kubeflow, knative-serving) |
| Monitoring | `monitoring.enabled` | local `monitoring` | ServiceMonitors and PrometheusRules for Rancher Monitoring |
| external-dns | `externaldns.enabled` | AppCo `external-dns` 1.21.1 | DNS records for the gateway hostname (Cloudflare) |
| cert-manager | `certManager.install` | AppCo `cert-manager` 1.20.2 | Installs cert-manager with the chart; not recommended (install it separately) |
| External Secrets Operator | `externalSecretsOperator.enabled` | AppCo `external-secrets-operator` 2.6.0 | Installs ESO with the chart when the cluster has none |

The `kubeflow` Namespace itself always comes from the local `kubeflow-namespace` sub-chart.
