# Optional Features

[← Back to README](../README.md) · Related: [Values Reference](values-reference.md#optional-features) · [Upgrade Notes](upgrade-notes.md)

How-tos for off-by-default features that are not covered elsewhere. All optional values are listed
in the [Values Reference](values-reference.md#optional-features).

---

<a id="model-registry-kserve-integration"></a>

## Model Registry: KServe integration (storage initializer and controller)

Both are off by default and not needed to use the Model Registry. Enable them only to let KServe load
models by registry name, or to record deployments in the registry (keys: [Values
Reference](values-reference.md#optional-features)).

**Storage initializer (only if you enable `hub.kserve.storageContainer.enabled`).** In `perProfile`
mode, add the profile to the URI so the initializer reaches that profile's registry:
`storageUri: model-registry://<model>/<version>?namespace=<profile>`.

The predictor pod must be in the Istio mesh, because the initializer sends no credentials of its
own. Profile namespaces are labelled `istio-injection: enabled` (by the chart for the profiles it
creates, by the profile controller for the others), so predictors get a sidecar automatically, and
the profile's `ns-owner-access-istio` policy admits in-mesh workloads from the same namespace — no
extra AuthorizationPolicy and no per-InferenceService label is needed:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-model
  namespace: <profile>
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: model-registry://<model>/<version>?namespace=<profile>
```

If a namespace is not Istio-injected, model loading fails with `403 Forbidden`; add the label
`sidecar.istio.io/inject: "true"` to the InferenceService (the annotation form is ignored when the
namespace is not injected).

The initializer runs as an init container, so the sidecar must start before it. Istio does this
by default with native sidecars; if your Istio has them disabled, also add the annotation
`sidecar.istio.io/nativeSidecar: "true"`.

If the registered artifact is on an S3-compatible store that needs path-style addressing (such as
the bundled SeaweedFS or MinIO), add `serving.kserve.io/s3-usevirtualbucket: "false"` to the S3
credentials Secret. Without it, the initializer requests `<bucket>.<endpoint>` and fails with
`no such host`.

**Controller (only if you enable `hub.controller.enabled`).** In `perProfile` mode it runs in
`managed` mode and needs `hub.controller.env.registriesNamespace` set to a profile namespace.
InferenceServices in other profiles select their registry with the label
`modelregistry.kubeflow.org/namespace: <profile>`. Each profile's registry admits the controller
by its mesh identity (`user-namespace.modelRegistry.authorizationPolicy.controllerPrincipal`, default
`cluster.local/ns/kubeflow/sa/model-registry-controller`); no extra AuthorizationPolicy is needed.
