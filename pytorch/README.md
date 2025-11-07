# Pytorch Helm Chart
PyTorch is a Python package that provides two high-level features:

Tensor computation (like NumPy) with strong GPU acceleration
Deep neural networks built on a tape-based autograd system


This Chart is for deploying [Pytorch](https://github.com/pytorch/pytorch). 


## Requirements

- Kubernetes: `>= 1.16.0-0` for **CPU only**

- Kubernetes: `>= 1.26.0-0` for **GPU** stable support (NVIDIA and AMD)

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| SUSE LLC |  | <https://www.suse.com> |


## Deploying Pytorch chart

To install the `pytorch` chart:

Assume the release name is `my-release`:

```console
helm install my-release \
    --set 'global.imagePullSecrets[0].name'=my-pull-secrets \
    oci://dp.apps.rancher.io/charts/pytorch
```

## Uninstalling Pytorch chart

To uninstall/delete the `pytorch` deployment:

```console
helm uninstall my-release
```

Substitute your values if they differ from the examples. See `helm delete --help` for a full reference on `delete` parameters and flags.


## Interact with Pytorch

- **Pytorch documentation can be found [HERE](https://github.com/pytorch/pytorch/tree/main/docs)**

To inject the files into the container, there are 3 options. In order of priority, they are:

- Existing Kubernetes configmap that contains the folder or files you want to load in PyTorch 
- Files under the scripts folder which is part of helm chart
- Cloning a git repository

To use exiting config map, set configMapExtFiles=<config-map> in values.yaml

To load files from scripts folder you don't have to set any option. Just create scripts folder and add files in there at the same level as values.yaml in pytorch helm chart. Don't set option for configMapExtFiles in values.yaml

To clone a git repository make sure that there are no files in scripts folder and configMapExtFiles option is not set in values file. Also the gitClone.repository link shouldn't have https:// in front of it

# Examples

### Basic values.yaml example with GPU and Existing configmap
```
gpu:
  # -- Enable GPU integration
  enabled: true
  
  # -- GPU type: 'nvidia' or 'amd'
  type: 'nvidia'
  
  # -- Specify the number of GPU to 1
  number: 1

# Specify runtime class
runtimeClassName: "nvidia"
   
# -- Existing Kubernetes Config map that contains the folder or files you want to load in PyTorch
configMapExtFiles: <Existing configmap> 
```
---
### Basic values.yaml example which downloads files from git repsitory
```
  
gitClone:
  # -- Enable in order to download files from git repository
  enabled: true

  # -- Repository that holds the files
  # -- Note: Don't provide https
  repository: "github.com/<Name of repository>"

  # Branch from repository to clone
  revision: "<Branch from which to download files>"

  # Existing Kubernetes secret which holds the authentication username and password fot the github repository. If repo doesn't need authentication leave this blank  
  secretName: "<Kubernetes secret Name>"

# -- Existing Kubernetes Config map that contains the folder or files you want to load in PyTorch
configMapExtFiles: ""
```

## Helm Values

- See [values.yaml](values.yaml) to see the Chart's default values.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity for pod assignment |
| fullnameOverride | string | `""` | String to fully override template |
| global.imagePullSecrets | list | `[]` | Global override for container image registry pull secrets |
| global.imageRegistry | string | `""` | Global override for container image registry |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy to use for the container |
| image.registry | string | `"dp.apps.rancher.io"` | Image registry to use for the container |
| image.repository | string | `"containers/pytorch"` | Image repository to use for the pytorch container |
| image.tag | string | `"0.3.6"` | Image tag to use for the container |
| imagePullSecrets | list | `[]` | Docker registry secret names as an array |
| ingress.annotations | object | `{}` | Additional annotations for the Ingress resource. |
| livenessProbe.enabled | bool | `true` | Enable livenessProbe |
| livenessProbe.failureThreshold | int | `6` | Failure threshold for livenessProbe |
| livenessProbe.initialDelaySeconds | int | `60` | Initial delay seconds for livenessProbe |
| livenessProbe.path | string | `"/"` | Request path for livenessProbe |
| livenessProbe.periodSeconds | int | `10` | Period seconds for livenessProbe |
| livenessProbe.successThreshold | int | `1` | Success threshold for livenessProbe |
| livenessProbe.timeoutSeconds | int | `5` | Timeout seconds for livenessProbe |
| nameOverride | string | `""` | String to partially override template  (will maintain the release name) |
| nodeSelector | object | `{}` | Node labels for pod assignment. |
| gpu.enabled | bool | `false` | Enable GPU integration |
| gpu.mig.devices | object | `{}` | Specify the mig devices and the corresponding number |
| gpu.mig.enabled | bool | `false` | Enable multiple mig devices If enabled you will have to specify the mig devices If enabled is set to false this section is ignored |
| gpu.number | int | `1` | Specify the number of GPU If you use MIG section below then this parameter is ignored |
| gpu.nvidiaResource | string | `"nvidia.com/gpu"` | only for nvidia cards; change to (example) 'nvidia.com/mig-1g.10gb' to use MIG slice |
| gpu.type | string | `"nvidia"` | GPU type: 'nvidia' or 'amd' If 'gpu.enabled', default value is nvidia If set to 'amd', this will add 'rocm' suffix to image tag if 'image.tag' is not override This is due cause AMD and CPU/CUDA are different images |
| service.enabled | bool | false | Enable option to create a service |
| service.annotations | object | `{}` | Annotations to add to the service |
| service.annotations | object | `{}` | Annotations to add to the service |
| service.nodePort | int | `31434` | Service node port when service type is 'NodePort' |
| service.port | int | `11434` | Service port |
| service.type | string | `"ClusterIP"` | Service type |
| service.loadBalancerIP | string | `""` | Loadbalancer IP address |
| serviceAccount.annotations | object | `{}` | Annotations to add to the service account |
| serviceAccount.automount | bool | `true` | Automatically mount a ServiceAccount's API credentials? |
| serviceAccount.create | bool | `true` | Specifies whether a service account should be created |
| serviceAccount.name | string | `""` | The name of the service account to use. If not set and create is true, a name is generated using the fullname template |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Persistent Volume access modes Must match those of existing PV or dynamic provisioner Ref: http://kubernetes.io/docs/user-guide/persistent-volumes/ |
| persistence.annotations | object | `{}` | Persistent Volume annotations |
| persistence.enabled | bool | `false` | Enable persistence using PVC |
| persistence.existingClaim | string | `""` | If you'd like to bring your own PVC , pass the name of the created + ready PVC here. If set, this Chart will not create the default PVC. Requires persistence.enabled: true |
| persistence.size | string | `"30Gi"` | Persistent Volume size |
| persistentVolume.storageClass | string | `""` | Persistent Volume Storage Class If defined, storageClassName: <storageClass> If set to "-", storageClassName: "", which disables dynamic provisioning If undefined (the default) or set to null, no storageClassName spec is set, choosing the default provisioner.  (gp2 on AWS, standard on GKE, AWS & OpenStack) |
| persistence.volumeMode | string | `""` | Persistent Volume Binding Mode If defined, volumeMode: <volumeMode> If empty (the default) or set to null, no volumeBindingMode spec is set, choosing the default mode. |
PV. |
| persistence.volumeName | string | `""` | Pre-existing PV to attach this claim to Useful if a CSI auto-provisions a PV for you and you want to always reference the PV moving forward |
| podAnnotations | object | `{}` | Map of annotations to add to the pods |
| podLabels | object | `{}` | Map of labels to add to the pods |
| podSecurityContext | object | `{}` | Pod Security Context |
| readinessProbe.enabled | bool | `true` | Enable readinessProbe |
| readinessProbe.failureThreshold | int | `6` | Failure threshold for readinessProbe |
| readinessProbe.initialDelaySeconds | int | `30` | Initial delay seconds for readinessProbe |
| readinessProbe.path | string | `"/"` | Request path for readinessProbe |
| readinessProbe.periodSeconds | int | `5` | Period seconds for readinessProbe |
| readinessProbe.successThreshold | int | `1` | Success threshold for readinessProbe |
| readinessProbe.timeoutSeconds | int | `3` | Timeout seconds for readinessProbe |
| resources.limits | object | `{}` | Pod limit |
| resources.requests | object | `{}` | Pod requests |
| runtimeClassName | string | `""` | Specify runtime class |
| securityContext | object | `{}` | Container Security Context |
| tolerations | list | `[]` | Tolerations for pod assignment |
| topologySpreadConstraints | object | `{}` | Topology Spread Constraints for pod assignment |
| volumeMounts | list | `[]` | Additional volumeMounts on the output Deployment definition. |
| volumes | list | `[]` | Additional volumes on the output Deployment definition. |
| entrypointscript.filename | sting | `""` | Main entrypoint to your application |
| entrypointscipt.arguments | list | `[]` | Args required by your entrypoint |
| gitClone.enabled | bool | `false` | Enable in order to download files from git repository |
| gitClone.repository | string | `""` | Repository that holds the files |
| gitClone.revision | sting | `""` | Revision from the repository to checkout |
| gitClone.secretname | sting | `""` | Existing Kubernetes secret which holds the authentication username and password |
| configMapExtFiles | sting | `""` | Existing Kubernetes Config map that specifies the folder or files you want to load in PyTorch |
----------------------------------------------
