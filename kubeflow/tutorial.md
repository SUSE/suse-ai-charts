# Kubeflow End-to-End Tutorial

This tutorial walks you through every major feature of this Kubeflow deployment from first login to querying a live inference endpoint.

**What you will cover**

| # | Feature | What you learn |
|---|---------|----------------|
| 1 | Jupyter Notebooks | Spin up an interactive notebook server |
| 2 | Kubeflow Pipelines | Build and run ML workflows as DAGs |
| 3 | Persistent Volumes | Create and browse PVCs via the UI |
| 4 | Tensorboard | Visualise training curves from a PVC |
| 5 | Katib | Automated hyperparameter search |
| 6 | Distributed Training | PyTorchJob and TFJob (Training Operator V1) |
| 6b | Trainer V2 | TrainJob + ClusterTrainingRuntime (higher-level API) |
| 7 | Model Registry | Version, approve, and track trained model artifacts |
| 8 | KServe | Deploy a REST inference endpoint |
| 9 | LLM Serving | Serve a language model with an OpenAI-compatible API |

---

## Prerequisites

| Tool | Purpose | Notes |
|------|---------|-------|
| `kubectl` | Apply YAMLs, check pod logs | Must point to the cluster |
| Python 3.8+ | Compile KFP pipelines | Only needed for Part 2 |
| Web browser | Kubeflow UI | All other parts |

**Verify the cluster is healthy**

```bash
kubectl get pods -n kubeflow --field-selector=status.phase=Running | wc -l
# Expect 20+ Running pods

kubectl get pods -n istio-system --field-selector=status.phase=Running | wc -l
# Expect 5+ Running pods
```

---

## 0. Accessing Kubeflow

**Discover the ingress IP / hostname**

```bash
# If using a cloud LoadBalancer:
kubectl get svc -n istio-system -o wide | grep LoadBalancer

# If using a NodePort or bare-metal:
kubectl get nodes -o wide       # pick an EXTERNAL-IP or INTERNAL-IP
kubectl get svc -n istio-system # look for the NodePort on port 80
```

Open `http://<KUBEFLOW_HOST>` in your browser.

**Login credentials (defaults)**

| Field    | Value              |
|----------|--------------------|
| Email    | `user@example.com` |
| Password | `12341234`         |

After login you land on the **Central Dashboard**.  All features are accessible from the left-hand navigation menu.

> **Namespace selector**
> The top of the page shows a namespace dropdown.  Make sure
> `kubeflow-user-example-com` is selected before creating any resource.

---

## Part 1 — Jupyter Notebooks

### 1.1 Create a Notebook Server

1. In the left menu click **Notebooks**.
2. Click **New Notebook**.
3. Fill in:

   | Field | Recommended value |
   |-------|-------------------|
   | Name | `my-notebook` |
   | Image | `jupyter-scipy:v1.10.0` (has numpy, pandas, sklearn, matplotlib) |
   | CPU | `1` |
   | RAM | `2 Gi` |
   | Workspace volume | *(auto-creates a 10 Gi PVC named* `my-notebook-workspace`*)* |

4. Click **Launch**.  Wait ~1 min for the pod to reach **Running**.

### 1.2 Connect and Run Code

5. Click **Connect** to open JupyterLab in a new browser tab.
6. Open a terminal (**File** → **New** → **Terminal**) or a new notebook.

**Quick sanity check — run in a notebook cell:**

```python
import sklearn, pandas, numpy
print(sklearn.__version__, pandas.__version__, numpy.__version__)

from sklearn.datasets import load_iris
iris = load_iris(as_frame=True)
iris.frame.describe()
```

### 1.3 Train a Model Interactively

Paste and run in a notebook:

```python
from sklearn.datasets import load_iris
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report

iris = load_iris()
X_tr, X_te, y_tr, y_te = train_test_split(
    iris.data, iris.target, test_size=0.2, random_state=42
)
model = LogisticRegression(max_iter=200)
model.fit(X_tr, y_tr)
print(classification_report(y_te, model.predict(X_te),
      target_names=iris.target_names))
```

### 1.4 Write Results to a PVC

The workspace PVC (`my-notebook-workspace`) is mounted at `/home/jovyan`.
Any file you save there persists across notebook restarts:

```python
import joblib, os
os.makedirs("/home/jovyan/models", exist_ok=True)
joblib.dump(model, "/home/jovyan/models/iris_lr.joblib")
print("Saved to /home/jovyan/models/iris_lr.joblib")
```

---

## Part 2 — Kubeflow Pipelines

Kubeflow Pipelines (KFP) lets you define ML workflows as Python DAGs, compile them to YAML, and run them with full lineage tracking, caching, and scheduling.

### 2.1 Install the KFP Python SDK

On your **local machine** (or inside a Kubeflow notebook):

```bash
pip install kfp>=2.0.0 scikit-learn pandas joblib
# Or: pip install -r tutorial/pipelines/requirements.txt
```

### 2.2 Hello World Pipeline

**Compile the pipeline**

```bash
cd tutorial/pipelines
python 01_hello_pipeline.py
# Output: compiled/01_hello_pipeline.yaml
```

**Upload and run via the UI**

1. In the Kubeflow UI go to **Pipelines** → **Upload Pipeline**.
2. Fill in:
   - Pipeline name: `Hello World`
   - Upload file: `tutorial/pipelines/compiled/01_hello_pipeline.yaml`
3. Click **Create**.
4. On the pipeline detail page click **Create Run**.
5. In the **name** parameter field type any name (e.g., `Alice`).
6. Click **Start**.

**Inspect the run**

- The run graph shows two nodes: **say_hello** → **log_message**.
- Click **say_hello** → **Logs** to see `Hello, Alice! Welcome to Kubeflow Pipelines.`
- Click **log_message** → **Logs** to see the word and character count.

### 2.3 Iris Classification Pipeline (with Metrics and Artifacts)

This pipeline produces logged metrics (accuracy, F1) visible in the KFP UI and passes CSV and model artifacts between steps.

Refer to https://www.kaggle.com/code/ash316/ml-from-scratch-with-iris to understand ML basics with IRIS dataset

**Compile**

```bash
python 02_iris_train_eval_pipeline.py
# Output: compiled/02_iris_train_eval_pipeline.yaml
```

**Upload and run**

1. **Pipelines** → **Upload Pipeline** → select `compiled/02_iris_train_eval_pipeline.yaml`.
2. Click **Create Run**.  Optionally tune:
   - `test_size` — fraction for test split (default `0.2`)
   - `max_iter`  — solver iterations (default `200`)
   - `C`         — regularisation strength (default `1.0`)
3. Click **Start**.

**Inspect results**

- After all three steps go green, click the **evaluate_model** node.
- In the **Input/Output** tab, you will find the pipeline artifacts listed.
- You will see "Error in retrieving artifact preview." under the metrics which is a known Kubeflow v2 behavior.
- Click the **Metrics** node and switch to  **Visualization** to see
  `accuracy`, `precision_macro`, `recall_macro`, `f1_macro`, `test_samples`.
- You can view all the runs tied to an experiment on the specific experiment page. You can also compare the metrics of different runs from the experiment page.

### 2.4 Recurring Runs

1. From any experiment click **Create Recurring Run**.
2. Set a trigger — for example **Periodic** every 1 hour.
3. The scheduled recurring run appears under **Recurring Runs** and spawns new runs automatically.

---

## Part 3 — Persistent Volume Management

### 3.1 Create a Standalone PVC

1. In the left menu click **Volumes**.
2. Click **New Volume**.
3. Fill in:

   | Field | Value |
   |-------|-------|
   | Name | `tutorial-data` |
   | Storage class | *(leave blank for cluster default)* |
   | Size | `5 Gi` |
   | Access mode | `ReadWriteOnce` |

4. Click **Create**.  The PVC appears with status **Unbound** until first mounted.

### 3.2 Mount the PVC in a Notebook

1. Go back to **Notebooks** → **New Notebook**.
2. Scroll down to **Data volumes** → **Attach existing volume**.
3. Select `tutorial-data`, mount path `/data`.
4. Create the notebook and connect.
5. In the terminal: `ls /data`  — empty initially.

### 3.3 Browse Files with PVCViewer

After writing some files to the PVC:

1. Go to **Volumes**.
2. Find `tutorial-data` → click the **folder icon** (Browse).
3. The filebrowser UI opens — you can upload, download, rename, and delete files.

> **Note:** The Browse button only appears while at least one pod has the PVC mounted.  Mount it in a notebook first, then open the browser.

---

## Part 4 — Tensorboard

### 4.1 Generate Training Logs

Create a new Notebook uisng the `jupyter-tensorflow-full:v1.7.0` image. From your notebook terminal, copy and run `write_tb_logs.py` (or upload it via JupyterLab):

```bash
# In the notebook terminal
python /path/to/tutorial/tensorboard/write_tb_logs.py \
    --log-dir /home/jovyan/logs/tb-demo/run1 \
    --epochs 30 \
    --seed 42
```

This writes `train/` and `validation/` event files under `/home/jovyan/logs/tb-demo/run1/` on the notebook's workspace PVC.
Each run needs its own subdirectory so that TensorBoard can overlay multiple runs on the same chart.

### 4.2 Create a Tensorboard Server

1. In the left menu click **Tensorboards**.
2. Click **New Tensorboard**.
3. Fill in:

   | Field | Value |
   |-------|-------|
   | Name | `tb-demo` |
   | **PVC** | `my-notebook-workspace` |
   | Mount path | `logs/tb-demo` |

> **Note:** The mount path is a **subPath within the PVC**, not an absolute
> container path.  The workspace PVC is mounted at `/home/jovyan` inside the
> notebook, so `/home/jovyan/logs/tb-demo/` lives at `logs/tb-demo` relative
> to the PVC root — that is the value to enter here.  TensorBoard is pointed
> at the `tb-demo` parent directory and will discover all `run1/`, `run2/`, …
> subdirectories automatically.
>
> Also enter the path **without** a leading slash.  This is a known bug in the
> tensorboard-controller
> ([kubeflow/kubeflow](https://github.com/kubeflow/kubeflow)): the mount path
> is used directly as a Kubernetes volume `subPath`, which must be a relative
> path. Entering a leading slash causes the Tensorboard to stay in "creating"
> indefinitely with no error shown in the UI.

4. Click **Create**.

### 4.3 Inspect the Dashboard

5. Wait for status **Ready** (green tick).
6. Click **Connect** — TensorBoard opens in a new tab.
7. Select the **SCALARS** tab to see `loss` and `accuracy` curves for both
   train and validation.
8. Hover over any point to read the exact epoch value.

> **Tip:** To compare two runs, write a second run to its own subdirectory,
> then click the ↺ reload button:
> ```bash
> python /path/to/tutorial/tensorboard/write_tb_logs.py \
>     --log-dir /home/jovyan/logs/tb-demo/run2 \
>     --epochs 15
> ```
> Using `--epochs 15` makes the comparison visually obvious: run2 stops at
> step 15 while run1 continues to 30, so you can clearly see both runs
> overlaid.  After clicking ↺, `run2/train` and `run2/validation` appear
> alongside `run1`.
>

---

## Part 5 — Hyperparameter Tuning with Katib

Katib automates the search for optimal hyperparameters.  It spawns parallel
trial jobs, collects their metrics, and uses a search algorithm to guide the
next set of trials.

### 5.1 Submit the Experiment

```bash
kubectl apply -f tutorial/katib/iris_hpo_experiment.yaml
```

This creates an `Experiment` that:
- Searches over `C` ∈ [0.01, 10.0] and `max_iter` ∈ [50, 300]
- Runs up to 8 trials (2 at a time) using random search
- Stops early if any trial reaches accuracy ≥ 0.97

**Watch progress via CLI**

```bash
kubectl get experiment iris-lr-search -n kubeflow-user-example-com -w
# Columns: NAME | STATUS | TRIALS | PENDING | RUNNING | SUCCEEDED | FAILED

kubectl get trials -n kubeflow-user-example-com \
    -l katib.kubeflow.org/experiment=iris-lr-search
```

### 5.2 Monitor via the UI

1. Left menu → **Experiments (AutoML)**.
2. Click `iris-lr-search`.
3. The parallel-coordinates graph at the top plots each trial's `C`,
   `max_iter`, and `accuracy` as connected lines — brighter lines are
   higher-scoring trials.
4. The **OVERVIEW** tab shows:
   - **Best trial** — the trial name with the highest accuracy
   - **Best trial's params** — the winning `C` and `max_iter` values
   - **Best trial performance** — the accuracy achieved
5. The **TRIALS** tab lists every trial with its sampled hyperparameters and
   metric value.

### 5.3 View Optimal Parameters

Once all trials complete (or the goal is reached) the experiment status changes
to `Succeeded`.  The UI shows the best `C` and `max_iter` values.

**Via CLI:**

```bash
kubectl get experiment iris-lr-search -n kubeflow-user-example-com \
    -o jsonpath='{.status.currentOptimalTrial.parameterAssignments}' | python3 -m json.tool
```

**Clean up**

```bash
kubectl delete experiment iris-lr-search -n kubeflow-user-example-com
```

---

## Part 6 — Distributed Training

The Training Operator manages distributed training jobs across multiple
pod replicas.  It supports PyTorch, TensorFlow, MPI, XGBoost, JAX, MXNet,
and PaddlePaddle jobs.

### 6.1 PyTorchJob (Data-parallel MNIST)

**Submit**

```bash
kubectl apply -f tutorial/training/pytorch_mnist_job.yaml
```

This starts 1 Master + 1 Worker.  The two pods form a `torch.distributed`
process group over Gloo (no GPU required).  Each pod trains for 3 epochs on
synthetic data then exits.  The script demonstrates the same distributed
mechanics as real MNIST — `DistributedDataParallel`, `DistributedSampler`,
gradient all-reduce — without requiring a dataset download.

> **Note:** The first run installs `torch` (CPU-only, ~130 MB) via pip.
> Allow ~90 seconds before logs appear.

**Monitor**

```bash
# Overall job status
kubectl get pytorchjob pytorch-mnist -n kubeflow-user-example-com

# Stream master logs
kubectl logs -n kubeflow-user-example-com -f \
    $(kubectl get pods -n kubeflow-user-example-com \
      -l training.kubeflow.org/job-name=pytorch-mnist,training.kubeflow.org/replica-type=master \
      -o name | head -1)
```

Expected output in master logs:
```
[Rank 0] initialised  world_size=2
[Rank 0] Epoch 1/3  loss=2.3021
[Rank 0] Epoch 2/3  loss=2.2748
[Rank 0] Epoch 3/3  loss=2.2401
[Rank 0] val accuracy=0.1340
[Rank 0] done.
```

**Clean up**

```bash
kubectl delete pytorchjob pytorch-mnist -n kubeflow-user-example-com
```

### 6.2 TFJob (Multi-Worker MNIST)

**Submit**

```bash
kubectl apply -f tutorial/training/tfjob_mnist.yaml
```

This starts 2 Workers using TensorFlow's `MultiWorkerMirroredStrategy`.
Each worker trains on its own shard of synthetic MNIST-shaped data; gradients
are synchronised across workers via all-reduce after every batch.  No GPU is
required — the job uses CPU-only TensorFlow.

> **Note:** The first run pulls `tensorflow/tensorflow:2.13.0` (~1.3 GB).
> Allow 3–5 minutes before logs appear.  Subsequent runs are faster because
> the image is cached on the node.

**Monitor**

```bash
kubectl get tfjob tfjob-mnist -n kubeflow-user-example-com

kubectl logs -n kubeflow-user-example-com -f \
    $(kubectl get pods -n kubeflow-user-example-com \
      -l training.kubeflow.org/job-name=tfjob-mnist,training.kubeflow.org/replica-type=worker \
      -o name | head -1)
```

Expected output in worker-0 logs:

```
2026-03-09 23:56:51.840167: I tensorflow/core/util/port.cc:110] oneDNN custom operations are on. You may see slightly different numerical results due to floating-point round-off errors from different computation orders. To turn them off, set the environment variable `TF_ENABLE_ONEDNN_OPTS=0`.
2026-03-09 23:56:51.868218: I tensorflow/core/platform/cpu_feature_guard.cc:182] This TensorFlow binary is optimized to use available CPU instructions in performance-critical operations.
To enable the following instructions: AVX2 AVX_VNNI FMA, in other operations, rebuild TensorFlow with the appropriate compiler flags.
[worker-0] TF_CONFIG={"cluster": {"worker": ["tfjob-mnist-worker-0.kubeflow-user-example-com.svc:2222", "tfjob-mnist-worker-1.kubeflow-user-example-com.svc:2222"]}, "task": {"type": "worker", "index": 0}, "environment": "cloud"}
2026-03-09 23:56:53.244421: I tensorflow/core/distributed_runtime/rpc/grpc_server_lib.cc:449] Started server with target: grpc://tfjob-mnist-worker-0.kubeflow-user-example-com.svc:2222
2026-03-09 23:56:53.249775: I tensorflow/tsl/distributed_runtime/coordination/coordination_service.cc:535] /job:worker/replica:0/task:0 has connected to coordination service. Incarnation: 13412633186268644260
2026-03-09 23:56:53.250089: I tensorflow/tsl/distributed_runtime/coordination/coordination_service_agent.cc:298] Coordination agent has successfully connected.
2026-03-09 23:56:54.015954: I tensorflow/tsl/distributed_runtime/coordination/coordination_service.cc:535] /job:worker/replica:0/task:1 has connected to coordination service. Incarnation: 4960846693716605248
[worker-0] num_replicas_in_sync=2
2026-03-09 23:56:54.315671: W tensorflow/core/framework/dataset.cc:956] Input of GeneratorDatasetOp::Dataset will not be optimized because the dataset does not implement the AsGraphDefInternal() method needed to apply optimizations.
Epoch 1/3
32/32 [==============================] - 1s 14ms/step - loss: 2.7640 - accuracy: 0.1005
Epoch 2/3
32/32 [==============================] - 1s 18ms/step - loss: 2.2005 - accuracy: 0.2595
Epoch 3/3
32/32 [==============================] - 1s 17ms/step - loss: 1.8610 - accuracy: 0.4110
[worker-0] done.

```

**Clean up**

```bash
kubectl delete tfjob tfjob-mnist -n kubeflow-user-example-com
```

### 6.3 All Supported Job Types

| CRD | Framework | Notes |
|-----|-----------|-------|
| `PyTorchJob` | PyTorch | Gloo / NCCL backends |
| `TFJob` | TensorFlow | MultiWorkerMirroredStrategy or PS-Worker |
| `MPIJob` | Any (MPI) | Horovod, OpenMPI |
| `XGBoostJob` | XGBoost | Distributed tree training |
| `JAXJob` | JAX | Multi-host JAX programs |
| `MXJob` | MXNet | Distributed MXNet |
| `PaddleJob` | PaddlePaddle | Baidu's DL framework |

---

## Part 6b — Trainer V2: Higher-Level Distributed Training

Trainer V2 (`trainer.kubeflow.org`) is a next-generation distributed training API that sits
above Training Operator V1. Instead of writing framework-specific CRDs (`PyTorchJob`, `TFJob`),
you submit a `TrainJob` that references a `ClusterTrainingRuntime` — a cluster-wide template
that encodes the framework, MPI topology, init-containers, and resource requirements. The
controller expands the TrainJob into a `JobSet` (Kubernetes SIG project), which manages the
underlying pod lifecycle.

**Trainer V2 vs Training Operator V1:**

| | Training Operator V1 | Trainer V2 |
|---|---|---|
| API group | `kubeflow.org` | `trainer.kubeflow.org` |
| User-facing CRD | `PyTorchJob`, `TFJob`, `MPIJob`, … | `TrainJob` |
| Runtime config | Inline in Job spec | `ClusterTrainingRuntime` (shared template) |
| Underlying engine | Pod groups | `JobSet` (SIG project) |
| Version | v1.6.0 | v2.1.0 |

### 6b.1 Available Runtimes

```bash
kubectl get clustertrainingruntime
# NAME                    AGE
# deepspeed-distributed   5m
# mlx-distributed         5m
# torch-distributed       5m
```

Runtimes define the full pod template (image, MPI settings, sshd for workers, etc.). Users
only need to set `numNodes`, the training image, and the command.

### 6b.2 Submit a TrainJob

```yaml
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: my-training-job
  namespace: kubeflow-user-example-com
spec:
  runtimeRef:
    name: torch-distributed
  trainer:
    numNodes: 2
    image: pytorch/pytorch:2.7.1-cuda12.8-cudnn9-runtime
    command: ["python", "train.py", "--epochs=10"]
    resourcesPerNode:
      requests: { cpu: "2", memory: "4Gi" }
      limits:   { cpu: "4", memory: "8Gi" }
```

```bash
kubectl apply -f trainjob.yaml -n kubeflow-user-example-com
```

### 6b.3 Check Status

```bash
kubectl get trainjob -n kubeflow-user-example-com
# NAME              PHASE     AGE
# my-training-job   Running   30s

kubectl get trainjob my-training-job -n kubeflow-user-example-com -o jsonpath='{.status.conditions}'
```

### 6b.4 View Pod Logs

```bash
# All trainer pods for this TrainJob
kubectl logs -n kubeflow-user-example-com \
  -l trainer.kubeflow.org/trainjob-ancestor-step=trainer \
  --prefix --follow
```

---

## Part 7 — Model Registry

Model Registry is the **model versioning and approval layer** between your training pipelines
and your serving infrastructure. It answers two questions that raw S3 storage cannot:
*"Which version of this model is approved for production?"* and
*"Which pipeline run produced it and what were its metrics?"*

**What users can do:**
- Register trained model artifacts with a name, description, and storage URI
- Create versions (v1, v2, …) and track their state: `LIVE`, `CANDIDATE`, `ARCHIVED`
- Record lineage — link a version back to the KFP run ID, dataset, and metrics that produced it
- Promote a `CANDIDATE` to `LIVE` after review, giving teams a controlled release workflow
- Deploy directly from the registry into KServe using `model-registry://` storage URIs
  (requires `kserve.storageContainer.enabled=true`)

**Relationship to the Models UI:** Model Registry is the catalog of *what exists and has been
vetted*. The Models UI (KServe) shows *what is currently running*. Nothing should reach the
Models UI without first passing through Model Registry.

---

### 7.1 Verify Model Registry Is Running

```bash
kubectl get pods -n kubeflow | grep model-registry
# Expected:
#   model-registry-deployment-xxxxx   2/2   Running
#   model-registry-ui-xxxxx           2/2   Running
```

Open the Kubeflow dashboard → click **"Model Registry"** in the left sidebar.
You should see an empty list — no models registered yet.

---

### 7.2 Train and Upload a Model

Train an Iris LogisticRegression classifier and upload it to SeaweedFS — this is the
artifact we'll register below and then serve with KServe in Part 8.

**From a Kubeflow Notebook terminal** (SeaweedFS is reachable in-cluster):

```bash
pip install boto3 scikit-learn joblib -q
python /path/to/tutorial/kserve/train_and_upload.py
```

**From your local machine** (requires port-forward):

```bash
kubectl port-forward svc/seaweedfs 9000:9000 -n kubeflow &
pip install boto3 scikit-learn joblib -q
python tutorial/kserve/train_and_upload.py --endpoint localhost:9000
```

Expected output:

```
Training Iris LogisticRegression …
  Test accuracy : 0.9667
  Classes       : [0, 1, 2]
  Created bucket : kserve-models
  Uploaded to    : s3://kserve-models/sklearn/iris

============================================================
Model uploaded successfully.

Use this storageUri in sklearn_iris_isvc.yaml:
  storageUri: "s3://kserve-models/sklearn/iris"
============================================================
```

You can also inspect buckets via the SeaweedFS master status endpoint:

```bash
kubectl port-forward svc/seaweedfs 9333:9333 -n kubeflow
# Open http://localhost:9333/cluster/status
```

---

### 7.3 Register the Model

Port-forward the registry API (run in a separate terminal):
```bash
kubectl port-forward svc/model-registry-service -n kubeflow 8080:8080
```

Register the model:
```bash
MODEL=$(curl -sf -X POST \
  http://localhost:8080/api/model_registry/v1alpha3/registered_models \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sklearn-iris",
    "description": "Iris LogisticRegression classifier",
    "customProperties": {
      "team": {"string_value": "ml-platform"},
      "framework": {"string_value": "scikit-learn"}
    }
  }')
echo $MODEL | python3 -m json.tool
MODEL_ID=$(echo $MODEL | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Registered model ID: $MODEL_ID"
```

---

### 7.4 Create a Model Version

A **RegisteredModel** is the logical name. A **ModelVersion** is a specific artifact — the
trained weights at a point in time. Create v1 pointing to the SeaweedFS URI:

```bash
VERSION=$(curl -sf -X POST \
  http://localhost:8080/api/model_registry/v1alpha3/model_versions \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"v1\",
    \"description\": \"Initial version — accuracy 0.9667\",
    \"registeredModelId\": \"$MODEL_ID\",
    \"customProperties\": {
      \"accuracy\": {\"double_value\": 0.9667},
      \"training_dataset\": {\"string_value\": \"iris-150-samples\"}
    }
  }")
echo $VERSION | python3 -m json.tool
VERSION_ID=$(echo $VERSION | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Model version ID: $VERSION_ID"
```

Register the artifact URI on the version:
```bash
curl -sf -X POST \
  http://localhost:8080/api/model_registry/v1alpha3/model_versions/$VERSION_ID/artifacts \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sklearn-iris-v1",
    "uri": "s3://kserve-models/sklearn/iris",
    "artifactType": "model-artifact"
  }' | python3 -m json.tool
```

---

### 7.5 Promote to LIVE

New versions start as `CANDIDATE`. After review, promote to `LIVE`:

```bash
curl -sf -X PATCH \
  http://localhost:8080/api/model_registry/v1alpha3/model_versions/$VERSION_ID \
  -H "Content-Type: application/json" \
  -d '{"state": "LIVE"}' | python3 -m json.tool
```

---

### 7.6 View in the UI

1. Refresh the **Model Registry** sidebar page in the Kubeflow dashboard.
2. You should see `sklearn-iris` listed with version `v1` in state `LIVE`.
3. Click the model → click the version → inspect the artifact URI, custom properties,
   and state history.

This is the view a team lead uses to approve or archive versions before they reach production.

---

### 7.7 Archive an Old Version

When a new version supersedes the old one, archive it rather than deleting it
(preserving the audit trail):

```bash
curl -sf -X PATCH \
  http://localhost:8080/api/model_registry/v1alpha3/model_versions/$VERSION_ID \
  -H "Content-Type: application/json" \
  -d '{"state": "ARCHIVED"}' | python3 -m json.tool
```

---

### 7.8 Helm Test

```bash
helm test kubeflow -n kubeflow --filter name=kubeflow-test-model-registry
helm test kubeflow -n kubeflow --filter name=kubeflow-test-model-registry-ui
```

---

## Part 8 — Model Serving with KServe

KServe deploys ML models as scalable REST endpoints backed by Knative
Serving.  The storage-initializer init-container downloads the model from
object storage (SeaweedFS in this deployment) before the predictor starts.

In Part 7 you trained the Iris classifier, uploaded it to SeaweedFS at
`s3://kserve-models/sklearn/iris`, and registered it in Model Registry.
This section deploys that approved version as a live serving endpoint.

### 8.1 Set Up Credentials

Apply the S3 secret and ServiceAccount (skip if already done):

```bash
kubectl apply -f tutorial/kserve/kserve-s3-secret.yaml
```

Verify:

```bash
kubectl get secret kserve-s3-secret -n kubeflow-user-example-com
kubectl get sa    kserve-sa          -n kubeflow-user-example-com
```

### 8.2 Create the InferenceService

```bash
kubectl apply -f tutorial/kserve/sklearn_iris_isvc.yaml
```

Watch the predictor pod initialise.  The storage-initializer init-container
downloads the model then exits; the main `kserve-container` starts serving.

```bash
kubectl get inferenceservice sklearn-iris -n kubeflow-user-example-com -w
# Wait for:   sklearn-iris   http://...   True   ...
```

Check the init container ran successfully:

```bash
kubectl describe pod -n kubeflow-user-example-com \
    -l serving.kserve.io/inferenceservice=sklearn-iris \
  | grep -A 6 "Init Containers:"
# storage-initializer should show: State: Terminated  Exit Code: 0
```

### 8.3 Query the Model

> **Note on in-cluster routing:** `sklearn-iris.kubeflow-user-example-com.svc.cluster.local`
> is a Knative ExternalName service that routes through the Istio ingress gateway,
> which has Kubeflow's oauth2 auth layer — causing a 302 redirect to Dex.
> Use the predictor's **private** revision service instead, which reaches the pod
> directly without going through the gateway.

**Discover the private service name** (revision number increments on each ISVC update):

```bash
kubectl get svc -n kubeflow-user-example-com | grep sklearn | grep private
# e.g.  sklearn-iris-predictor-00001-private
```

**From inside the cluster** (e.g., a notebook terminal):

```bash
curl -s -X POST \
  http://sklearn-iris-predictor-00001-private.kubeflow-user-example-com.svc.cluster.local/v1/models/sklearn-iris:predict \
  -H "Content-Type: application/json" \
  -d '{"instances": [[5.1, 3.5, 1.4, 0.2], [6.7, 3.1, 4.7, 1.5], [6.3, 2.7, 4.9, 1.8]]}'
```

Expected response:

```json
{"predictions": [0, 1, 2]}
```

**Class mapping:**
- `0` → Iris setosa
- `1` → Iris versicolor
- `2` → Iris virginica

**From your local machine** (port-forward — use a free local port, e.g. 8081 if 8080 is taken):

```bash
kubectl port-forward svc/sklearn-iris-predictor-00001-private \
    -n kubeflow-user-example-com 8081:80

curl -s -X POST http://localhost:8081/v1/models/sklearn-iris:predict \
  -H "Content-Type: application/json" \
  -d '{"instances": [[5.1, 3.5, 1.4, 0.2], [6.7, 3.1, 4.7, 1.5], [6.3, 2.7, 4.9, 1.8]]}'
```

**From Python** (in a notebook):

```python
import subprocess, requests

# Discover the private service name dynamically
svc = subprocess.check_output(
    "kubectl get svc -n kubeflow-user-example-com "
    "--no-headers -o custom-columns=NAME:.metadata.name "
    "| grep sklearn | grep private",
    shell=True, text=True
).strip()

url = f"http://{svc}.kubeflow-user-example-com.svc.cluster.local/v1/models/sklearn-iris:predict"
payload = {
    "instances": [
        [5.1, 3.5, 1.4, 0.2],   # setosa
        [6.7, 3.1, 4.7, 1.5],   # versicolor
        [6.3, 2.7, 4.9, 1.8],   # virginica
    ]
}
resp = requests.post(url, json=payload)
print(resp.json())   # {"predictions": [0, 1, 2]}
```

#### External Access (requires domain configuration)

Two external access modes are available. Both require setting a real domain first.

**Authenticated inference** (Kubeflow login required):

```bash
# One-time domain setup — use your node IP with nip.io
NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
[[ -z "$NODE_IP" ]] && { echo "ERROR: could not determine node IP"; exit 1; }

# Two sub-charts consume the domain; both must be set together.
# --force-conflicts: cert-manager-cainjector holds SSA field ownership on some ClusterRoles;
# this flag lets Helm win the conflict rather than failing the upgrade.
helm upgrade kubeflow charts/kubeflow --reuse-values \
  --set "knativeServing.domain=${NODE_IP}.nip.io" \
  --set "kserve.ingressDomain=${NODE_IP}.nip.io" \
  -n kubeflow \
  --force-conflicts

# Get the external URL
kubectl get inferenceservice sklearn-iris -n kubeflow-user-example-com
# URL column: http://sklearn-iris-kubeflow-user-example-com.<NODE_IP>.nip.io

# Extract your session cookie from browser DevTools
# (Application → Cookies → oauth2_proxy_kubeflow), then:
curl -s -X POST \
  "http://sklearn-iris-kubeflow-user-example-com.${NODE_IP}.nip.io/v1/models/sklearn-iris:predict" \
  -H "Content-Type: application/json" \
  -H "Cookie: oauth2_proxy_kubeflow=<paste-cookie-here>" \
  -d '{"instances": [[5.1, 3.5, 1.4, 0.2], [6.7, 3.1, 4.7, 1.5], [6.3, 2.7, 4.9, 1.8]]}'
```

#### Programmatic / External Access (Bearer Token)

For scripts and CI pipelines that run **outside the cluster** (no browser, no kubectl),
oauth2-proxy can validate a Dex-issued JWT directly — no cookie required.  This uses
the OAuth 2.0 Resource Owner Password Credentials (ROPC) grant, which is the only
grant type that works without a redirect-capable browser.

> **ROPC limitations:** ROPC is deprecated in OAuth 2.1 (RFC 9700) and is incompatible
> with MFA.  It requires `enablePasswordDB: true` in Dex (the chart default) and
> transmits the user password directly to the client application.  For fully automated
> service-to-service auth, prefer the client credentials grant or Kubernetes projected
> service account tokens when available.

```bash
# Read the OIDC client secret from the cluster (matches auth.oidc.clientSecret in values.yaml)
CLIENT_SECRET=$(kubectl -n kubeflow get secret kubeflow-dex \
  -o jsonpath='{.data.config\.yaml}' | base64 -d \
  | grep -A5 'kubeflow-oidc-authservice' | awk '/secret:/{print $2; exit}')

NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc istio -n istio-system \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

# Step 1: Obtain an OIDC id_token from Dex
TOKEN=$(curl -s -X POST \
  "http://${NODE_IP}:${NODE_PORT}/dex/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=kubeflow-oidc-authservice" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=user@example.com" \
  -d "password=12341234" \
  -d "scope=openid profile email" \
  | python3 -c "
import sys, json
r = json.load(sys.stdin)
if 'error' in r:
    sys.exit(f\"Dex error: {r['error']}: {r.get('error_description', '')}\")
print(r['id_token'])")

# Step 2: Use token for inference (no cookie needed)
curl -s -X POST \
  "http://sklearn-iris-kubeflow-user-example-com.${NODE_IP}.nip.io/v1/models/sklearn-iris:predict" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"instances": [[5.1, 3.5, 1.4, 0.2], [6.7, 3.1, 4.7, 1.5], [6.3, 2.7, 4.9, 1.8]]}'
```

> **Token TTL:** Dex ID tokens expire after 24 hours by default. For long-running
> scripts, add `offline_access` to the scope to receive a `refresh_token`, then
> re-exchange it for a new `id_token` when the current one expires.

> **Production Dex issuer URL:** In this tutorial, Dex is configured with an
> in-cluster issuer URL. In production, set `dex.config.issuer` to the
> externally-reachable URL so that tokens can be validated by external tooling
> (e.g. kubectl-less API clients). This requires Dex to be accessible at that URL.

### 8.4 Monitor via the Models UI

1. Left menu → **Models**.
2. The `sklearn-iris` endpoint appears with its URL, readiness, and traffic split.
3. Knative automatically scales the predictor down to 0 replicas after idle
   time and scales back up on the next request (scale-from-zero).

### 8.5 Clean Up

```bash
kubectl delete inferenceservice sklearn-iris -n kubeflow-user-example-com
```

---

## Part 9 — LLM Serving with KServe

KServe v0.16.0 ships a `huggingfaceserver` runtime that serves language models
behind an **OpenAI-compatible REST API** (`/openai/v1/completions`).  The same
`InferenceService` resource is used as for classical ML models; only the runtime
and model format differ.

> **Chat completions note:** `/openai/v1/chat/completions` requires the model to
> have a chat template defined in its tokenizer config.  GPT-2 predates chat
> templates and only supports raw text completion.  Use a model such as
> `mistralai/Mistral-7B-Instruct-v0.3` for chat endpoints.

> **GPU note:** GPT-2 (124M params) runs on CPU and fits in the 16 Gi cluster
> used by this tutorial.  For production LLMs (Llama 3, Mistral, Qwen, etc.)
> you need at least one GPU node and should set `--dtype=float16` or `bfloat16`.
> The `kserve-huggingfaceserver` runtime automatically uses **vLLM** when a GPU
> is detected and falls back to **Hugging Face Transformers** on CPU.

> **Internet access:** The predictor downloads the model from Hugging Face Hub
> at startup.  If the cluster has no outbound internet, upload the model to
> SeaweedFS first (see Part 7.2) and set `storageUri: "s3://kserve-models/gpt2"`.

### 9.1 Verify the HuggingFace Runtime Is Registered

The `kserve-huggingfaceserver` ClusterServingRuntime is included in this chart.
Confirm it is present after deployment:

```bash
kubectl get clusterservingruntimes
# Should include: kserve-huggingfaceserver
```

### 9.2 Deploy the InferenceService

```bash
kubectl apply -f tutorial/kserve/gpt2_isvc.yaml
```

The predictor pod starts a `storage-initializer` init container that is skipped
(no `storageUri` is set); the main container downloads GPT-2 from Hugging Face
Hub directly.  This takes 1-3 minutes on the first run depending on network
speed.

Watch until `READY = True`:

```bash
kubectl get inferenceservice gpt2 -n kubeflow-user-example-com -w
# Wait until:  READY   URL
#              True    http://gpt2.kubeflow-user-example-com.example.com
#
# This can take 3-5 min on first pull; the model is fully loaded only when
# "Application startup complete" appears in the kserve-container log.
```

Check the predictor pod is up:

```bash
kubectl get pods -n kubeflow-user-example-com -l serving.kserve.io/inferenceservice=gpt2
# 1/1 Running
```

Stream the startup log to confirm the model loaded:

```bash
kubectl logs -n kubeflow-user-example-com \
    -l serving.kserve.io/inferenceservice=gpt2 \
    -c kserve-container --tail=20
# Expected: "Model gpt2 loaded"  or  "Application startup complete"
```

### 9.3 Generate Text (curl)

> **Production access:** For external clients (scripts, CI pipelines) that cannot use
> a browser cookie, use the **Dex Bearer token** pattern described in [section 7.4
> Programmatic / External Access (Bearer Token)](#programmatic--external-access-bearer-token).
> Replace the sklearn-iris URL with the GPT-2 InferenceService URL and the predict
> path with `/openai/v1/completions`.  The `-private` service pattern below is
> convenient for development but is not suitable for production use (bypasses auth,
> revision name is unstable).

**From inside the cluster** (e.g., a Kubeflow Notebook terminal):

In-cluster requests to `gpt2.kubeflow-user-example-com.svc.cluster.local` flow
through the Knative local gateway, which shares the same Istio pod as the ingress
gateway — so the `authn-filter` applies and unauthenticated requests get a 302
redirect to Dex.  The workaround is to use the predictor's `-private` service,
which is a direct ClusterIP to the revision pod that bypasses the gateway entirely.

> **Note:** The `-private` service name includes the revision number (`00001`,
> `00002`, …) which increments on every InferenceService update.  Use the dynamic
> lookup below rather than hardcoding the name.

```bash
# Discover the current private service name (revision-stable)
PRIVATE_SVC=$(kubectl get svc -n kubeflow-user-example-com --no-headers \
  -o custom-columns=NAME:.metadata.name \
  | grep "^gpt2-predictor.*-private$" \
  | sort | tail -1)

[ -z "$PRIVATE_SVC" ] && {
  echo "ERROR: gpt2 private service not found."
  echo "Check: kubectl get inferenceservice gpt2 -n kubeflow-user-example-com"
  exit 1
}

echo "Using private service: $PRIVATE_SVC"

curl -s -X POST \
  "http://${PRIVATE_SVC}.kubeflow-user-example-com.svc.cluster.local/openai/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt2",
    "prompt": "Kubeflow is an open-source machine learning platform that",
    "max_tokens": 60,
    "temperature": 0.7
  }' | python3 -m json.tool
```

Example response:

```json
{
  "id": "cmpl-...",
  "object": "text_completion",
  "model": "gpt2",
  "choices": [
    {
      "text": " enables data scientists to build and deploy ML workflows on Kubernetes...",
      "index": 0,
      "finish_reason": "length"
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 60,
    "total_tokens": 72
  }
}
```

**Chat completions** (requires a model with a chat template — GPT-2 does not have one;
substitute the model name below with a chat-capable model such as
`mistralai/Mistral-7B-Instruct-v0.3`):

```bash
curl -s -X POST \
  "http://${PRIVATE_SVC}.kubeflow-user-example-com.svc.cluster.local/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt2",
    "messages": [{"role": "user", "content": "What is machine learning?"}],
    "max_tokens": 80
  }' | python3 -m json.tool
```

### 9.4 Query from Python (OpenAI SDK)

The endpoint is drop-in compatible with the `openai` Python library:

```python
# pip install openai -q
import subprocess
from openai import OpenAI

# Discover the current private service (bypasses Knative gateway + auth filter)
private_svc = subprocess.check_output(
    "kubectl get svc -n kubeflow-user-example-com --no-headers "
    "-o custom-columns=NAME:.metadata.name "
    "| grep '^gpt2-predictor.*-private$' | sort | tail -1",
    shell=True, text=True
).strip()
assert private_svc, "gpt2 private service not found — is the InferenceService ready?"

client = OpenAI(
    base_url=f"http://{private_svc}.kubeflow-user-example-com.svc.cluster.local/openai/v1",
    api_key="unused",   # KServe does not require an API key on the private service
)

# Text completion
response = client.completions.create(
    model="gpt2",
    prompt="The future of artificial intelligence is",
    max_tokens=80,
    temperature=0.8,
)
print(response.choices[0].text)

# Chat completion — requires a model with a chat template (GPT-2 does not have one).
# Substitute "gpt2" with e.g. "mistralai/Mistral-7B-Instruct-v0.3" for this to work.
chat = client.chat.completions.create(
    model="gpt2",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user",   "content": "Explain gradient descent in one sentence."},
    ],
    max_tokens=80,
)
print(chat.choices[0].message.content)
```

### 9.5 Serving a Larger Model (GPU nodes)

For a GPU-accelerated deployment, update `storageUri`, `--model_name`, `dtype`, and
resources — everything else stays the same:

```yaml
# excerpt — fields to change in gpt2_isvc.yaml
storageUri: hf://TinyLlama/TinyLlama-1.1B-Chat-v1.0  # replace the gpt2 storageUri
args:
  - --model_name=tinyllama  # name used in /openai/v1/… "model" field
  - --dtype=float16         # float16 on GPU
  - --max_length=2048
resources:
  requests:
    cpu: "2"
    memory: 8Gi
    nvidia.com/gpu: "1"
  limits:
    cpu: "4"
    memory: 16Gi
    nvidia.com/gpu: "1"
```

Other drop-in `storageUri` values (set `--model_name` to the short name you want to use in API calls):

| Model | Size | Min GPU VRAM |
|-------|------|--------------|
| `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | 1.1B | 4 GB |
| `mistralai/Mistral-7B-Instruct-v0.3` | 7B | 16 GB |
| `meta-llama/Llama-3.2-3B-Instruct` | 3B | 8 GB (needs HF token) |
| `Qwen/Qwen2.5-7B-Instruct` | 7B | 16 GB |

For gated models (e.g., Llama 3) add your Hugging Face token as a secret:

```bash
kubectl create secret generic hf-token \
  -n kubeflow-user-example-com \
  --from-literal=HF_TOKEN=<your_token>
```

Then reference it in the InferenceService:

```yaml
spec:
  predictor:
    model:
      env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-token
              key: HF_TOKEN
```

### 9.6 Monitor via the Models UI

1. Left menu → **Models**.
2. The `gpt2` endpoint appears with URL, readiness, and traffic split.
3. Knative scales the predictor to **0 replicas** after idle time (configurable
   via `minReplicas`) and back to 1 on the next request.

### 9.7 Clean Up

```bash
kubectl delete inferenceservice gpt2 -n kubeflow-user-example-com
```

---

## Part 10 — End-to-End ML Workflow (Putting It All Together)

The sections above cover each feature individually.  A production ML workflow typically chains them like this:

```
 Notebook (explore data)
        │
        ▼
 KFP Pipeline (reproducible preprocessing + training)
        │
        ├──▶  Katib (HPO) ──▶ feed best params back to pipeline
        │
        ├──▶  Training Operator (distributed training for large datasets)
        │
        ├──▶  Tensorboard (inspect training curves via PVC logs)
        │
        └──▶  Model Registry (version artifact, track metadata, approve)
                    │
                    └──▶  KServe (deploy approved version as REST endpoint)
                                │
                                └──▶ Monitor via Models UI
```

A concrete end-to-end example:

1. **Explore** data in a Jupyter notebook.
2. **Codify** the training steps as a KFP pipeline (`02_iris_train_eval_pipeline.py`).
3. **Tune** hyperparameters with Katib (`iris_hpo_experiment.yaml`).
4. **Train at scale** using the best params in a `PyTorchJob`.
5. **Inspect curves** with Tensorboard while training runs.
6. **Upload** the trained model to SeaweedFS with `train_and_upload.py`.
7. **Register** the model artifact in Model Registry — record its storage URI, version, and the pipeline run that produced it.
8. **Serve** the approved version with KServe and query it in production.
9. **Track** the live endpoint in the Models UI.

---

## Appendix A — Namespace & Multi-Tenancy

By default this deployment creates one user namespace: `kubeflow-user-example-com`.
To add a second user:

```yaml
# new-user-profile.yaml
apiVersion: kubeflow.org/v1
kind: Profile
metadata:
  name: another-user
spec:
  owner:
    kind: User
    name: another@example.com
  resourceQuotaSpec: {}
```

```bash
kubectl apply -f new-user-profile.yaml
```

The Profiles controller creates the namespace, RoleBindings, and per-namespace
KFP artifacts automatically.

---

## Appendix B — Troubleshooting

### Pipeline run stuck in "Pending Execution"

The persistence agent must watch all namespaces.  Check:

```bash
kubectl get deploy ml-pipeline-persistenceagent -n kubeflow \
    -o jsonpath='{.spec.template.spec.containers[0].env}'
# NAMESPACE must be "" (empty string) not "kubeflow"
```

If it is set to `"kubeflow"`, redeploy with the fix in the chart values.

### Artifact preview shows "Failed to initialize Minio Client"

The `ml-pipeline-ui-artifact` pod in the user namespace must read the S3
credentials secret from its own namespace:

```bash
kubectl get deploy ml-pipeline-ui-artifact -n kubeflow-user-example-com \
    -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -i NAMESPACE
# FRONTEND_SERVER_NAMESPACE must be set
```

### Tensorboard server stays "Unavailable"

Check the tensorboard-controller for panics:

```bash
kubectl logs -n kubeflow deployment/tensorboard-controller-deployment --tail=30
```

The `tensorboard-controller-config` ConfigMap must contain `ISTIO_HOST`.
See `charts/apps/tensorboard-controller/values.yaml`.

### KServe InferenceService stuck (not READY)

1. Check the controller log for errors:
   ```bash
   kubectl logs -n kubeflow deployment/kserve-controller-manager --tail=30
   ```
2. Ensure `clusterstoragecontainers.serving.kserve.io` CRD exists:
   ```bash
   kubectl get crd clusterstoragecontainers.serving.kserve.io
   ```
3. Ensure a `default` ClusterStorageContainer object exists:
   ```bash
   kubectl get clusterstoragecontainer default
   ```
4. Ensure `kserve-manager-role` ClusterRole includes `clusterstoragecontainers`:
   ```bash
   kubectl get clusterrole kserve-manager-role -o yaml | grep clusterstorage
   ```
5. Check predictor pod init-container logs:
   ```bash
   kubectl logs -n kubeflow-user-example-com \
       -l serving.kserve.io/inferenceservice=sklearn-iris \
       -c storage-initializer
   ```

---

## Appendix C — Cluster Resource Guide

| Component | CPU request | Memory request | PVC |
|-----------|------------|----------------|-----|
| KFP API server | 250m | 500Mi | — |
| KFP Argo controller | 100m | 500Mi | — |
| KFP SeaweedFS | 50m | 256Mi | 20 Gi |
| KFP MariaDB | 250m | 256Mi | 20 Gi |
| Katib controller | 100m | 256Mi | — |
| Katib MariaDB | 100m | 256Mi | 10 Gi |
| Notebook server (typical) | 500m | 1 Gi | 10 Gi (workspace) |
| Tensorboard server | 200m | 200Mi | — (reads PVC) |
| KServe predictor (sklearn) | 100m | 256Mi | — |
| KServe predictor (GPT-2 CPU) | 1000m | 4 Gi | — |
| KServe predictor (LLM GPU) | 2000m | 8 Gi | — | + 1 GPU |
| PyTorchJob (per replica, CPU) | 500m | 512Mi | — |
| PyTorchJob (per replica, GPU) | 1000m | 2 Gi | — | + 1 GPU |
| TFJob (per replica) | 500m | 512Mi | — |

**Minimum cluster for this tutorial (CPU only):** 8 vCPU, 16 Gi RAM, 100 Gi storage.
**With GPU workloads:** add ≥1 GPU node (NVIDIA A10 / T4 or better recommended).

---

## Appendix D — Using GPU Nodes

This appendix explains how to request GPU resources across every Kubeflow
component.  The only prerequisite is that at least one cluster node exposes
the `nvidia.com/gpu` resource (i.e., the NVIDIA device plugin is installed).

### D.1 Verify GPU Availability

```bash
# List GPU capacity on each node
kubectl get nodes \
  -o custom-columns="NODE:.metadata.name,GPUs:.status.allocatable.nvidia\.com/gpu"

# See full allocatable resources on a specific node
kubectl describe node <gpu-node-name> | grep -A10 "Allocatable:"

# Check how many GPUs are currently in use cluster-wide
kubectl get pods -A \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.limits.nvidia\.com/gpu}{"\n"}{end}{end}' \
  | grep -v '^$' | paste -sd+ | bc
```

If `nvidia.com/gpu` shows `<none>` for all nodes, the NVIDIA device plugin is
not installed.  Install it with:

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml
```

---

### D.2 GPU Notebook Servers

#### Create a GPU Notebook via the UI

1. Left menu → **Notebooks** → **New Notebook**.
2. Under **Image**, select a CUDA-enabled image:

   | Image | Framework | CUDA |
   |-------|-----------|------|
   | `jupyter-pytorch-cuda:v1.10.0` | PyTorch | 12.x |
   | `jupyter-pytorch-cuda-full:v1.10.0` | PyTorch + extras | 12.x |
   | `jupyter-tensorflow-cuda:v1.10.0` | TensorFlow | 11.x |

3. Under **GPUs**:
   - **Number of GPUs**: select `1` (or more if available)
   - **GPU Vendor**: `NVIDIA`

4. Click **Launch**.  The notebook pod is scheduled only on a node that has a
   free GPU; if none are available it stays `Pending`.

#### Verify GPU access inside the notebook

```python
import torch
print(torch.cuda.is_available())          # True
print(torch.cuda.get_device_name(0))      # e.g. "NVIDIA A100-SXM4-40GB"
print(torch.cuda.memory_allocated() / 1e9, "GB allocated")
```

```python
# TensorFlow
import tensorflow as tf
print(tf.config.list_physical_devices('GPU'))
```

#### Requesting GPU via raw YAML (kubectl)

```yaml
# Equivalent of the UI form for a GPU notebook
spec:
  template:
    spec:
      containers:
      - name: notebook
        resources:
          limits:
            nvidia.com/gpu: "1"
```

---

### D.3 GPU Steps in KFP Pipelines

Two things are needed for a GPU pipeline step:

1. A **CUDA-enabled base image** so PyTorch/TensorFlow can see the GPU.
2. `.set_accelerator_type("NVIDIA GPU").set_gpu_limit(1)` on the task, which
   sets `resources.limits["nvidia.com/gpu"] = "1"` on the generated pod.

**Compile and upload**

```bash
python tutorial/pipelines/03_gpu_pipeline.py
# → tutorial/pipelines/compiled/03_gpu_pipeline.yaml
```

Upload and run as usual via the KFP UI (Pipelines → Upload Pipeline).

**Key SDK calls** (from `03_gpu_pipeline.py`):

```python
@dsl.component(base_image="pytorch/pytorch:2.2.0-cuda12.1-cudnn8-runtime")
def train_on_gpu(...):
    import torch
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    ...

@dsl.pipeline
def gpu_pipeline():
    task = train_on_gpu()
    task.set_accelerator_type("nvidia.com/gpu").set_gpu_limit(1)
    task.set_memory_limit("8G")
```

**Requesting multiple GPUs** (e.g., for model parallelism):

```python
task.set_accelerator_type("nvidia.com/gpu").set_gpu_limit(2)
```

**Checking GPU usage mid-run**:

```bash
kubectl get pods -n kubeflow-user-example-com | grep -i pipeline
kubectl exec -n kubeflow-user-example-com <pod-name> -- nvidia-smi
```

---

### D.4 GPU Distributed Training (PyTorchJob / TFJob)

#### PyTorchJob with GPU (NCCL backend)

Apply the GPU variant of the MNIST job:

```bash
kubectl apply -f tutorial/training/pytorch_mnist_gpu_job.yaml
```

This starts 1 Master + 1 Worker, each requesting 1 GPU, using the NCCL
backend for GPU-to-GPU gradient synchronisation.

**Monitor**:

```bash
kubectl get pytorchjob pytorch-mnist-gpu -n kubeflow-user-example-com

# Stream master logs
kubectl logs -n kubeflow-user-example-com -f \
    $(kubectl get pods -n kubeflow-user-example-com \
      -l training.kubeflow.org/job-name=pytorch-mnist-gpu,training.kubeflow.org/replica-type=master \
      -o name | head -1)
```

**Clean up**:

```bash
kubectl delete pytorchjob pytorch-mnist-gpu -n kubeflow-user-example-com
```

#### Adding GPU to your own PyTorchJob

The only required change is the `resources` block in each replica's container:

```yaml
resources:
  requests:
    cpu: "2"
    memory: 4Gi
    nvidia.com/gpu: "1"    # request a GPU
  limits:
    cpu: "4"
    memory: 16Gi
    nvidia.com/gpu: "1"    # limit must equal request for GPUs
```

Switch the backend from `gloo` (CPU) to `nccl` (GPU) in your training code:

```python
dist.init_process_group(backend="nccl")   # was "gloo"
device = torch.device(f"cuda:{local_rank}")
model  = model.to(device)
model  = nn.parallel.DistributedDataParallel(model, device_ids=[local_rank])
```

#### TFJob with GPU

Same pattern — add GPU resources to each replica's container:

```yaml
spec:
  tfReplicaSpecs:
    Worker:
      replicas: 2
      template:
        spec:
          containers:
          - name: tensorflow
            image: tensorflow/tensorflow:2.15.0-gpu
            resources:
              limits:
                nvidia.com/gpu: "1"
```

TensorFlow automatically detects and uses all visible GPUs via
`MirroredStrategy` without any code changes:

```python
strategy = tf.distribute.MirroredStrategy()
with strategy.scope():
    model = build_model()
    model.compile(...)
model.fit(dataset, epochs=10)
```

---

### D.5 GPU Trials in Katib HPO

Add a `resources` block to the trial container in the `trialSpec`.  Katib
schedules each trial pod on a node that satisfies the resource request.

```yaml
# Excerpt from a Katib Experiment — trialSpec container section
containers:
- name: training-container
  image: pytorch/pytorch:2.2.0-cuda12.1-cudnn8-runtime
  resources:
    requests:
      cpu: "2"
      memory: 4Gi
      nvidia.com/gpu: "1"
    limits:
      cpu: "4"
      memory: 8Gi
      nvidia.com/gpu: "1"
  command:
  - python3
  - -c
  - |
    import torch
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    # ... your training + metric print ...
```

> **Parallelism and GPU count:** if `parallelTrialCount: 4` and each trial
> requests 1 GPU, at least 4 free GPUs are needed for all trials to run
> concurrently.  Trials queue otherwise.

---

### D.6 Tensorboard and GPU Training

The **Tensorboard server itself does not use GPU** — it is a read-only log
visualiser.  However, your GPU training code should write logs in the usual way:

```python
# PyTorch — works identically whether running on CPU or GPU
from torch.utils.tensorboard import SummaryWriter
writer = SummaryWriter("/home/jovyan/logs/run1")
writer.add_scalar("Loss/train", loss.item(), step)
writer.add_scalar("Accuracy/val", val_acc, epoch)
writer.close()
```

Once the training job (running on GPU) has written logs to the PVC, create a
Tensorboard server pointing at the same PVC as described in Part 4 — no GPU
selector needed.

---

### D.7 KServe LLM Inference on GPU

See **Part 9.5** for the complete GPU InferenceService spec.

Quick reference — the only changes from the CPU GPT-2 example:

| Field | CPU (tutorial default) | GPU |
|-------|------------------------|-----|
| `storageUri` | `hf://openai-community/gpt2` | `hf://<org>/<model>` |
| `--model_name` | `gpt2` | short name for API calls |
| `--dtype` | `float32` | `float16` or `bfloat16` |
| `--max_length` | `512` | `4096`+ |
| `resources.limits` | no `nvidia.com/gpu` | `nvidia.com/gpu: "1"` |
| vLLM backend | ✗ (Transformers) | ✓ (auto-selected) |

---

### D.8 Troubleshooting GPU Pods

**Pod stays `Pending` indefinitely**

```bash
kubectl describe pod <pod-name> -n kubeflow-user-example-com | grep -A5 "Events:"
# "0/N nodes are available: N Insufficient nvidia.com/gpu"
# → no node has a free GPU; scale up or wait for one to free
```

**`nvidia-smi` not found inside the container**

The base image does not include the CUDA toolkit.  Use an image from
`nvidia/cuda`, `pytorch/pytorch:*-cuda*`, or
`tensorflow/tensorflow:*-gpu` which include `nvidia-smi`.

**GPU visible but CUDA ops fail**

```bash
# Check driver / CUDA version compatibility
kubectl exec -n <ns> <pod> -- nvidia-smi
# Driver version must be >= the minimum for the CUDA version in the image
# CUDA 12.1 requires driver >= 525.60
```

**GPU not released after job completes**

Kubernetes releases the GPU allocation when the pod terminates.  If a pod
is stuck in `Terminating`, force-delete it:

```bash
kubectl delete pod <pod-name> -n <ns> --force --grace-period=0
```

---

## File Reference

```
tutorial/
├── pipelines/
│   ├── requirements.txt                  KFP SDK dependencies
│   ├── 01_hello_pipeline.py              Two-step hello-world pipeline
│   ├── 02_iris_train_eval_pipeline.py    Full ML pipeline with metrics
│   └── 03_gpu_pipeline.py               GPU step pipeline (Appendix D)
├── tensorboard/
│   └── write_tb_logs.py                  Generates TF event files for TB
├── training/
│   ├── pytorch_mnist_job.yaml            PyTorchJob (1 master + 1 worker, CPU)
│   ├── pytorch_mnist_gpu_job.yaml        PyTorchJob (1 master + 1 worker, GPU/NCCL)
│   └── tfjob_mnist.yaml                  TFJob (1 PS + 1 worker)
├── katib/
│   └── iris_hpo_experiment.yaml          Katib HPO experiment
└── kserve/
    ├── kserve-s3-secret.yaml             S3 Secret + ServiceAccount (SeaweedFS)
    ├── sklearn_iris_isvc.yaml            InferenceService definition
    ├── train_and_upload.py               Train sklearn model + upload to SeaweedFS
    └── gpt2_isvc.yaml                    LLM InferenceService (GPT-2 on CPU)
```
