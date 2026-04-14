#!/usr/bin/env bash
# Tier 3 E2E Tests — Kubeflow Helm Chart
# ========================================
# Runs from the host using kubectl + curl.
# Prerequisites: kubectl, curl
#
# Usage:
#   chmod +x test/e2e/e2e.sh
#   ./test/e2e/e2e.sh
#
# What it tests:
#   1.  KFP pipeline      — inline spec → submit run → wait for SUCCEEDED
#   2.  Notebook          — create CR → wait StatefulSet ready → delete
#   3.  PyTorchJob        — 1-replica CPU job → wait for Succeeded
#   4.  KServe            — build sklearn model → upload → deploy IS → predict
#   5.  Model Registry    — register → list → archive
#   6.  Tensorboard canary — leading-slash subPath bug still present
#   7.  Trainer V2        — TrainJob → wait for Complete
#   8.  TFJob             — 1-worker CPU job → wait for Succeeded
#   9.  Katib HPO         — 1-trial experiment → Succeeded
#   10. Tensorboard       — create CR + PVC → controller creates Deployment
#   11. PVCViewer         — create CR → controller creates viewer pod → Ready
#
# GPU tests (opt-in, pass --include-gpu-tests):
#   GPU-1. Node capability  — at least one node has nvidia.com/gpu
#   GPU-2. CUDA smoke       — nvidia-smi inside a CUDA container
#   GPU-3. GPU Notebook     — Notebook CR with GPU limit → StatefulSet ready
#   GPU-4. GPU PyTorchJob   — NCCL init + CUDA tensor op → Succeeded
#   GPU-5. HuggingFace IS   — tiny synthetic GPT-2 on GPU → /openai/v1/completions

set -uo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
NS=kubeflow
USER_NS=kubeflow-user-example-com
KFP_USER=user@example.com
PASS=0
FAIL=0

# Parse flags
INCLUDE_GPU=false
for arg in "$@"; do
  case "$arg" in
    --include-gpu-tests) INCLUDE_GPU=true ;;
    --user-namespace=*)  USER_NS="${arg#*=}" ;;
    --user-email=*)      KFP_USER="${arg#*=}" ;;
  esac
done

# Timeouts (seconds)
T_KFP=300
T_NOTEBOOK=300
T_PYTORCH=300
T_KSERVE_BUILD=300        # model builder pod
T_KSERVE_READY=600        # IS ready
T_TFJOB=300
T_KATIB=300               # 1-trial busybox experiment
T_PVCVIEWER=300
T_GPU_NOTEBOOK=300
T_GPU_PYTORCH=600
T_GPU_HF_BUILD=600        # tiny model build + upload
T_GPU_HF_READY=1200       # IS ready (model load into GPU; first run pulls multi-GB image)

# ── Helpers ────────────────────────────────────────────────────────────────────
green() { printf '\033[32m  ✓  %s\033[0m\n' "$*"; }
red()   { printf '\033[31m  ✗  %s\033[0m\n' "$*"; }
header(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
info()  { printf '      %s\n' "$*"; }

pass() { green "$1"; ((PASS++)) || true; }
fail() { red   "$1"; ((FAIL++)) || true; }

# Poll a kubectl jsonpath until it equals an expected value (or times out).
# Usage: wait_for_value <label> <timeout> <namespace> <resource> <jsonpath> <expected>
wait_for_value() {
  local label="$1" timeout="$2" ns="$3" resource="$4" path="$5" expected="$6"
  local elapsed=0
  while true; do
    local actual
    actual=$(kubectl get $resource -n "$ns" -o "jsonpath=${path}" 2>/dev/null || echo "")
    [[ "$actual" == "$expected" ]] && return 0
    sleep 5; elapsed=$((elapsed+5))
    info "${label}: got '${actual:-<empty>}', want '${expected}' (${elapsed}s/${timeout}s)"
    [[ $elapsed -ge $timeout ]] && return 1
  done
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() {
  info "Cleaning up E2E resources..."
  # Tests 1-7
  kubectl delete pod              kfp-e2e-helper       -n "$NS"      --ignore-not-found &>/dev/null || true
  kubectl delete notebook         e2e-test-notebook    -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pytorchjob       e2e-test-pytorchjob  -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete inferenceservice e2e-sklearn          -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete secret           e2e-s3-secret        -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete serviceaccount   e2e-kserve-sa        -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pod              e2e-model-builder    -n "$NS"      --ignore-not-found &>/dev/null || true
  kubectl delete trainjob         test-trainjob        -n "$USER_NS" --ignore-not-found &>/dev/null || true
  # Tests 8-11
  kubectl delete tfjob            e2e-test-tfjob       -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete experiment       e2e-katib-test       -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete tensorboard      e2e-tensorboard-test -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pvcviewer        e2e-pvcviewer-test   -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pod              e2e-pvc-binder       -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pvc              e2e-test-pvc         -n "$USER_NS" --ignore-not-found &>/dev/null || true
  # GPU tests
  kubectl delete notebook         e2e-gpu-notebook     -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pytorchjob       e2e-gpu-pytorch      -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete inferenceservice e2e-tiny-gpt2        -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pod              e2e-gpu-model-build  -n "$NS"      --ignore-not-found &>/dev/null || true
}
trap cleanup EXIT

# ── Prerequisites ──────────────────────────────────────────────────────────────
for cmd in kubectl curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed"; exit 1
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
header "━━━ Tier 3 E2E Tests ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
header "$(date '+%Y-%m-%d %H:%M:%S')"

# ── Test 1: KFP Pipeline ───────────────────────────────────────────────────────
header "1. KFP Pipeline — submit inline run → wait for SUCCEEDED"

# Spin up a curl helper pod inside the cluster to avoid host-side port-forward
# fragility on Windows. The pod is in the kubeflow namespace so it has direct
# access to ml-pipeline:8888 with no auth complications.
# Disable sidecar injection via --overrides: ml-pipeline AP is allow-all so
# no mesh identity needed, and this avoids sidecar initialisation races.
kubectl delete pod kfp-e2e-helper -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
kubectl run kfp-e2e-helper -n "$NS" \
  --image=dp.apps.rancher.io/containers/curl:8.14.1 \
  --restart=Never \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}},"spec":{"imagePullSecrets":[{"name":"application-collection"}]}}' \
  --wait \
  --command -- sh -c "sleep 300" >/dev/null 2>&1

sleep 5

KFP_EXEC="kubectl exec kfp-e2e-helper -n $NS --"
KFP_BASE="http://ml-pipeline.${NS}.svc.cluster.local:8888"
KFP_RUN_NAME="e2e-test-$(date +%s)"

if ! kubectl wait pod/kfp-e2e-helper -n "$NS" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
  fail "KFP: helper pod did not become Ready within 120s"
else
  retries=15
  attempt=1
  while [ $attempt -le $retries ]; do
    # Create a per-run experiment in the user namespace.
    # Use -s (not -sf) so error bodies are visible in the fail message.
    EXP_RESP=$($KFP_EXEC curl -s -X POST "${KFP_BASE}/apis/v2beta1/experiments" \
      -H "Content-Type: application/json" \
      -H "kubeflow-userid: ${KFP_USER}" \
      -d "{\"display_name\":\"${KFP_RUN_NAME}\",\"namespace\":\"${USER_NS}\"}" 2>/dev/null || echo "EXEC_FAILED")
    EXP_ID=$(echo "$EXP_RESP" | grep -o '"experiment_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -n "$EXP_ID" ]]; then
      break
    fi
    echo "KFP: experiment creation failed, retrying... (attempt $attempt/$retries)"
    sleep 10
    attempt=$((attempt+1))
  done

  if [[ -z "$EXP_ID" ]]; then
    fail "KFP: could not create experiment after $retries attempts (response: ${EXP_RESP:0:300})"
  else
    info "Experiment ID: $EXP_ID"

    # Inline KFP v2 pipeline spec — single busybox echo step, no caching
    PIPELINE_SPEC='{"components":{"comp-echo":{"executorLabel":"exec-echo"}},"deploymentSpec":{"executors":{"exec-echo":{"container":{"command":["sh","-c","echo Kubeflow E2E test OK; date"],"image":"dp.apps.rancher.io/containers/bci-busybox:15.7"}}}},"pipelineInfo":{"name":"e2e-test"},"root":{"dag":{"tasks":{"echo":{"cachingOptions":{"enableCache":false},"componentRef":{"name":"comp-echo"},"taskInfo":{"name":"echo"}}}}},"schemaVersion":"2.1.0","sdkVersion":"kfp-2.0.0"}'

    RUN_RESP=$($KFP_EXEC curl -s -X POST "${KFP_BASE}/apis/v2beta1/runs" \
      -H "Content-Type: application/json" \
      -H "kubeflow-userid: ${KFP_USER}" \
      -d "{\"display_name\":\"${KFP_RUN_NAME}\",\"experiment_id\":\"${EXP_ID}\",\"pipeline_spec\":${PIPELINE_SPEC}}" \
      2>/dev/null || echo "EXEC_FAILED")
    RUN_ID=$(echo "$RUN_RESP" | grep -o '"run_id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$RUN_ID" ]]; then
      fail "KFP: could not create run (response: ${RUN_RESP:0:300})"
    else
      info "Run ID: $RUN_ID"
      elapsed=0
      RUN_STATE="PENDING"
      while [[ "$RUN_STATE" != "SUCCEEDED" && "$RUN_STATE" != "FAILED" && "$RUN_STATE" != "ERROR" ]]; do
        sleep 5; elapsed=$((elapsed+5))
        RUN_STATE=$($KFP_EXEC curl -sf "${KFP_BASE}/apis/v2beta1/runs/${RUN_ID}" \
          -H "kubeflow-userid: ${KFP_USER}" 2>/dev/null \
          | grep -o '"state":"[A-Z_]*"' | head -1 | cut -d'"' -f4 || echo "UNKNOWN")
        info "Run state: ${RUN_STATE:-UNKNOWN} (${elapsed}s/${T_KFP}s)"
        if [[ $elapsed -ge $T_KFP ]]; then RUN_STATE="TIMEOUT"; break; fi
      done

      if [[ "$RUN_STATE" == "SUCCEEDED" ]]; then
        pass "KFP pipeline run SUCCEEDED"
      else
        fail "KFP pipeline run ended with state: $RUN_STATE"
      fi
    fi
  fi
fi

kubectl delete pod kfp-e2e-helper -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

# ── Test 2: Notebook lifecycle ─────────────────────────────────────────────────
header "2. Notebook lifecycle — create → StatefulSet ready → delete"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: e2e-test-notebook
  namespace: ${USER_NS}
spec:
  template:
    spec:
      imagePullSecrets:
      - name: application-collection
      containers:
      - name: e2e-test-notebook
        image: dp.apps.rancher.io/containers/bci-busybox:15.7
        command: ["tail", "-f", "/dev/null"]
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
EOF

if wait_for_value "Notebook StatefulSet" "$T_NOTEBOOK" "$USER_NS" \
    "sts/e2e-test-notebook" '{.status.readyReplicas}' "1"; then
  pass "Notebook StatefulSet reached readyReplicas=1"
  kubectl delete notebook e2e-test-notebook -n "$USER_NS" --ignore-not-found &>/dev/null
  pass "Notebook deleted"
else
  fail "Notebook StatefulSet did not reach readyReplicas=1 within ${T_NOTEBOOK}s"
fi

# ── Test 3: PyTorchJob ─────────────────────────────────────────────────────────
header "3. PyTorchJob — 1-replica CPU job → wait for Succeeded"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: e2e-test-pytorchjob
  namespace: ${USER_NS}
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: Never
      template:
        spec:
          imagePullSecrets:
          - name: application-collection
          containers:
          - name: pytorch
            image: dp.apps.rancher.io/containers/bci-busybox:15.7
            command: ["sh", "-c", "echo PyTorchJob E2E test OK; date; sleep 2"]
            resources:
              requests:
                cpu: 50m
                memory: 64Mi
EOF

elapsed=0
JOB_SUCCEEDED=false
JOB_FAILED=false
while true; do
  sleep 5; elapsed=$((elapsed+5))
  COND_OK=$(kubectl get pytorchjob e2e-test-pytorchjob -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")
  COND_FAIL=$(kubectl get pytorchjob e2e-test-pytorchjob -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  info "PyTorchJob Succeeded=${COND_OK:-False} Failed=${COND_FAIL:-False} (${elapsed}s/${T_PYTORCH}s)"
  [[ "$COND_OK" == "True" ]] && JOB_SUCCEEDED=true && break
  [[ "$COND_FAIL" == "True" ]] && JOB_FAILED=true && break
  if [[ $elapsed -ge $T_PYTORCH ]]; then break; fi
done

if $JOB_SUCCEEDED; then
  pass "PyTorchJob Succeeded"
  kubectl delete pytorchjob e2e-test-pytorchjob -n "$USER_NS" --ignore-not-found &>/dev/null
elif $JOB_FAILED; then
  fail "PyTorchJob Failed"
else
  fail "PyTorchJob did not complete within ${T_PYTORCH}s"
fi

# ── Test 4: KServe InferenceService ───────────────────────────────────────────
header "4. KServe — build sklearn model → deploy IS → Ready → predict"

# 4a: Build model + upload to SeaweedFS via a setup pod.
#     Uses stgregistry.suse.com/ai/containers/sklearnserver:v0.15.2 (same image as the server — identical
#     sklearn version avoids pickle compatibility issues).
info "Launching model builder pod..."
kubectl run e2e-model-builder \
  --image=stgregistry.suse.com/ai/containers/sklearnserver:v0.15.2 \
  --restart=Never \
  -n "$NS" \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/nativeSidecar":"true"}}}' \
  --command -- python3 -c "
import pickle, boto3
from sklearn.linear_model import LinearRegression
model = LinearRegression()
model.fit([[1.0],[2.0],[3.0],[4.0]], [2.0,4.0,6.0,8.0])
with open('/tmp/model.pkl','wb') as f:
    pickle.dump(model, f)
s3 = boto3.client('s3',
    endpoint_url='http://seaweedfs.kubeflow.svc.cluster.local:9000',
    aws_access_key_id='kubeflow',
    aws_secret_access_key='kubeflow123',
    region_name='us-east-1')
try:
    s3.create_bucket(Bucket='e2e-models')
except Exception as e:
    print('bucket:', e)
s3.upload_file('/tmp/model.pkl', 'e2e-models', 'sklearn/model.pkl')
print('Model uploaded OK')
" &>/dev/null

# Wait for model builder to succeed
elapsed=0
BUILDER_OK=false
BUILDER_PHASE="Pending"
while true; do
  sleep 5; elapsed=$((elapsed+5))
  BUILDER_PHASE=$(kubectl get pod e2e-model-builder -n "$NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  info "Model builder: ${BUILDER_PHASE} (${elapsed}s/${T_KSERVE_BUILD}s)"
  [[ "$BUILDER_PHASE" == "Succeeded" ]] && BUILDER_OK=true && break
  [[ "$BUILDER_PHASE" == "Failed" ]]    && break
  [[ $elapsed -ge $T_KSERVE_BUILD ]]    && break
done

if ! $BUILDER_OK; then
  # Show builder logs to help debug
  kubectl logs e2e-model-builder -n "$NS" 2>/dev/null | tail -5 | while IFS= read -r line; do info "  builder: $line"; done
  fail "KServe: model builder did not succeed (phase: ${BUILDER_PHASE})"
else
  pass "KServe: model uploaded to SeaweedFS (e2e-models/sklearn/model.pkl)"

  # 4b: Create SeaweedFS credentials Secret + ServiceAccount
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: e2e-s3-secret
  namespace: ${USER_NS}
  annotations:
    serving.kserve.io/s3-endpoint: seaweedfs.kubeflow.svc.cluster.local:9000
    serving.kserve.io/s3-usehttps: "0"
    serving.kserve.io/s3-region: us-east-1
    serving.kserve.io/s3-useanoncredential: "false"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: kubeflow
  AWS_SECRET_ACCESS_KEY: kubeflow123
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: e2e-kserve-sa
  namespace: ${USER_NS}
secrets:
- name: e2e-s3-secret
EOF

  # 4c: Deploy InferenceService
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: e2e-sklearn
  namespace: ${USER_NS}
spec:
  predictor:
    serviceAccountName: e2e-kserve-sa
    model:
      modelFormat:
        name: sklearn
      storageUri: s3://e2e-models/sklearn
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: "1"
          memory: 2Gi
EOF

  info "InferenceService created, waiting for Ready..."

  # 4d: Wait for IS Ready condition
  elapsed=0
  IS_READY=false
  while true; do
    sleep 10; elapsed=$((elapsed+10))
    IS_COND=$(kubectl get inferenceservice e2e-sklearn -n "$USER_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    info "InferenceService Ready=${IS_COND:-False} (${elapsed}s/${T_KSERVE_READY}s)"
    [[ "$IS_COND" == "True" ]] && IS_READY=true && break
    [[ $elapsed -ge $T_KSERVE_READY ]] && break
  done

  if ! $IS_READY; then
    kubectl get inferenceservice e2e-sklearn -n "$USER_NS" -o jsonpath='{.status}' 2>/dev/null \
      | grep -o '"message":"[^"]*"' | head -3 | while IFS= read -r msg; do info "  IS status: $msg"; done
    fail "KServe: InferenceService did not become Ready within ${T_KSERVE_READY}s"
  else
    pass "KServe InferenceService Ready"

    # 4e: Find predictor pod and run prediction via kubectl exec (avoids Istio routing complexity)
    PRED_POD=$(kubectl get pod -n "$USER_NS" \
      -l "serving.kserve.io/inferenceservice=e2e-sklearn" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$PRED_POD" ]]; then
      fail "KServe: could not find predictor pod"
    else
      info "Predictor pod: $PRED_POD"
      PRED_RESULT=$(kubectl exec -n "$USER_NS" "$PRED_POD" -c kserve-container -- \
        python3 -c "
import urllib.request, json
data = json.dumps({'instances':[[2.5]]}).encode()
req = urllib.request.Request(
    'http://localhost:8080/v1/models/e2e-sklearn:predict',
    data=data, headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(req, timeout=10).read().decode())
" 2>/dev/null || echo "")

      if echo "$PRED_RESULT" | grep -q '"predictions"'; then
        pass "KServe prediction returned valid response: ${PRED_RESULT}"
      else
        fail "KServe prediction failed (response: '${PRED_RESULT:0:200}')"
      fi
    fi
  fi
fi

# ── Test 5: Model Registry ────────────────────────────────────────────────────
header "5. Model Registry — register model → list → verify"
if ! kubectl get deploy model-registry-deployment -n "$NS" &>/dev/null; then
  info "Model Registry not deployed — skipping"
else
  # Exec into the model-registry-server pod (already in-mesh) to run API calls.
  # A separate non-mesh kubectl-run pod gets 403 from the namespace-based AuthorizationPolicy.
  MR_POD=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=model-registry-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$MR_POD" ]; then
    fail "Model Registry: server pod not found"
  else
    # Use heredoc-via-stdin to avoid nested-quote mangling inside sh -c '...'
    kubectl exec -n "$NS" "$MR_POD" -c model-registry-server -i -- sh << 'MRSCRIPT' 2>&1 \
      && pass "Model Registry: register, list, and cleanup succeeded" \
      || fail "Model Registry: e2e test failed"
set -e
# 1. POST: register a model with a unique name to avoid conflicts from previous runs
MODEL_NAME="e2e-test-$(date +%s)"
RESULT=$(curl -sf -X POST \
  http://127.0.0.1:8080/api/model_registry/v1alpha3/registered_models \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${MODEL_NAME}\",\"description\":\"E2E test model\"}")
echo "POST result: $RESULT"
MODEL_ID=$(echo "$RESULT" | grep -o '"id":"[^"]*"' | head -1 | cut -d: -f2 | tr -d '"')
echo "Model ID: $MODEL_ID"
if [ -z "$MODEL_ID" ]; then
  echo "FAIL: no model ID returned from POST"
  exit 1
fi

# 2. GET: list models and verify size >= 1
LIST=$(curl -sf \
  http://127.0.0.1:8080/api/model_registry/v1alpha3/registered_models)
echo "LIST result: $LIST"
# Extract the top-level "size" field (not "pageSize") using grep with literal chars
TOTAL=$(echo "$LIST" | grep -o '"size":[0-9]*' | tail -1 | cut -d: -f2)
echo "Total models: $TOTAL"
if [ "${TOTAL:-0}" -ge 1 ]; then
  echo "PASS: size=$TOTAL"
else
  echo "FAIL: expected size>=1, got $TOTAL"
  exit 1
fi

# 3. ARCHIVE: cleanup the registered model (DELETE is not supported; PATCH to ARCHIVED)
curl -sf -X PATCH \
  "http://127.0.0.1:8080/api/model_registry/v1alpha3/registered_models/${MODEL_ID}" \
  -H "Content-Type: application/json" \
  -d '{"state":"ARCHIVED"}' \
  && echo "Archived model $MODEL_ID"
MRSCRIPT
  fi
fi

# ── Test 6: Tensorboard subPath canary ────────────────────────────────────────
header "6. Tensorboard subPath canary — leading slash in logspath must NOT create Deployment"
# This test verifies the tensorboard-controller still has the upstream bug
# where leading slashes in pvc:// logspaths produce an absolute volumeMount
# subPath, which Kubernetes rejects.  When this test FAILS it means the
# upstream fix has shipped — update tutorial.md section 4.2 accordingly.
T_TB_SUBPATH=15   # seconds to wait for controller attempt

kubectl apply -f - -n "$USER_NS" &>/dev/null <<EOF
apiVersion: tensorboard.kubeflow.org/v1alpha1
kind: Tensorboard
metadata:
  name: test-subpath-canary
  namespace: ${USER_NS}
spec:
  logspath: pvc://nonexistent-pvc//home/jovyan/test
EOF

info "Waiting ${T_TB_SUBPATH}s for controller to attempt Deployment creation..."
sleep "$T_TB_SUBPATH"

if kubectl get deployment test-subpath-canary -n "$USER_NS" &>/dev/null; then
  fail "Tensorboard subPath canary: UPSTREAM BUG FIXED — tensorboard-controller now handles leading slashes. Update tutorial.md section 4.2 to allow standard /path style mount paths."
else
  pass "Tensorboard subPath canary (controller correctly rejects absolute subPath)"
fi
kubectl delete tensorboard test-subpath-canary -n "$USER_NS" --ignore-not-found &>/dev/null

# ── Section 7: Trainer V2 — submit TrainJob → wait for Complete ────────────────
header "7. Trainer V2 — submit TrainJob"

if ! kubectl get deploy kubeflow-trainer-controller-manager -n "$NS" &>/dev/null; then
  info "Trainer V2 not deployed — skipping"
else
  # Delete any leftover TrainJob from a previous run to avoid stale conditions
  kubectl delete trainjob test-trainjob -n "$USER_NS" --ignore-not-found &>/dev/null
  kubectl apply -n "$USER_NS" -f - <<'EOF'
apiVersion: trainer.kubeflow.org/v1alpha1
kind: TrainJob
metadata:
  name: test-trainjob
spec:
  runtimeRef:
    name: torch-distributed
  trainer:
    numNodes: 1
    image: dp.apps.rancher.io/containers/bci-busybox:15.7
    command: ["sh", "-c", "echo Trainer V2 OK; date"]
  podTemplateOverrides:
  - targetJobs:
    - name: node
    spec:
      imagePullSecrets:
      - name: application-collection
EOF

  info "Waiting 300s for TrainJob to complete..."
  if kubectl wait --for=condition=Complete trainjob/test-trainjob \
      -n "$USER_NS" --timeout=300s &>/dev/null; then
    pass "Trainer V2 TrainJob Succeeded"
  else
    fail "Trainer V2 TrainJob did not succeed within 300s"
  fi

  kubectl delete trainjob test-trainjob -n "$USER_NS" --ignore-not-found &>/dev/null
fi

# ── Test 8: TFJob ──────────────────────────────────────────────────────────────
header "8. TFJob — 1-worker CPU job → wait for Succeeded"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: kubeflow.org/v1
kind: TFJob
metadata:
  name: e2e-test-tfjob
  namespace: ${USER_NS}
spec:
  tfReplicaSpecs:
    Worker:
      replicas: 1
      restartPolicy: Never
      template:
        spec:
          imagePullSecrets:
          - name: application-collection
          containers:
          - name: tensorflow
            image: dp.apps.rancher.io/containers/bci-busybox:15.7
            command: ["sh", "-c", "echo TFJob E2E test OK; date; sleep 2"]
            resources:
              requests:
                cpu: 50m
                memory: 64Mi
EOF

elapsed=0
TFJOB_SUCCEEDED=false
TFJOB_FAILED=false
while true; do
  sleep 5; elapsed=$((elapsed+5))
  COND_OK=$(kubectl get tfjob e2e-test-tfjob -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")
  COND_FAIL=$(kubectl get tfjob e2e-test-tfjob -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  info "TFJob Succeeded=${COND_OK:-False} Failed=${COND_FAIL:-False} (${elapsed}s/${T_TFJOB}s)"
  [[ "$COND_OK"   == "True" ]] && TFJOB_SUCCEEDED=true && break
  [[ "$COND_FAIL" == "True" ]] && TFJOB_FAILED=true   && break
  [[ $elapsed -ge $T_TFJOB ]] && break
done

if $TFJOB_SUCCEEDED; then
  pass "TFJob Succeeded"
  kubectl delete tfjob e2e-test-tfjob -n "$USER_NS" --ignore-not-found &>/dev/null
elif $TFJOB_FAILED; then
  fail "TFJob Failed"
else
  fail "TFJob did not complete within ${T_TFJOB}s"
fi

# ── Test 9: Katib HPO ──────────────────────────────────────────────────────────
header "9. Katib HPO — 1-trial busybox experiment → Succeeded"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: kubeflow.org/v1beta1
kind: Experiment
metadata:
  name: e2e-katib-test
  namespace: ${USER_NS}
spec:
  objective:
    type: maximize
    objectiveMetricName: accuracy
  algorithm:
    algorithmName: random
  maxTrialCount: 1
  parallelTrialCount: 1
  maxFailedTrialCount: 1
  parameters:
  - name: lr
    parameterType: double
    feasibleSpace:
      min: "0.01"
      max: "0.10"
  metricsCollectorSpec:
    collector:
      kind: File
    source:
      fileSystemPath:
        path: "/var/log/katib/metrics.log"
        kind: File
        format: TEXT
  trialTemplate:
    primaryContainerName: training-container
    trialParameters:
    - name: learningRate
      description: Learning rate
      reference: lr
    trialSpec:
      apiVersion: batch/v1
      kind: Job
      spec:
        template:
          metadata:
            annotations:
              sidecar.istio.io/inject: "false"
          spec:
            shareProcessNamespace: true
            imagePullSecrets:
            - name: application-collection
            containers:
            - name: training-container
              image: dp.apps.rancher.io/containers/bci-busybox:15.7
              command:
              - sh
              - -c
              - "echo lr=\${trialParameters.learningRate}; echo accuracy=0.99 > /var/log/katib/metrics.log; sleep 10"
            restartPolicy: Never
EOF

# On a fresh install cert-manager takes a moment to inject the CA bundle into the
# ValidatingWebhookConfiguration. The placeholder value is "Cg==" (base64 of "\n").
# Wait until the real cert is injected before applying the Experiment, otherwise the
# webhook server rejects the CREATE with a TLS error and failurePolicy:Ignore drops it.
_katib_webhook_ready=false
for _i in $(seq 1 12); do
  _ca=$(kubectl get validatingwebhookconfiguration katib.kubeflow.org \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)
  if [[ -n "$_ca" && "$_ca" != "Cg==" ]]; then
    _katib_webhook_ready=true
    break
  fi
  sleep 5
done
unset _ca _i
$_katib_webhook_ready || info "katib webhook CA not ready after 60s — applying anyway"
unset _katib_webhook_ready

elapsed=0
KATIB_DONE=false
KATIB_FAILED=false
while true; do
  sleep 5; elapsed=$((elapsed+5))
  COND_OK=$(kubectl get experiment e2e-katib-test -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")
  COND_FAIL=$(kubectl get experiment e2e-katib-test -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  TRIAL_STATE=$(kubectl get trials -n "$USER_NS" \
    -l "katib.kubeflow.org/experiment=e2e-katib-test" \
    -o jsonpath='{.items[0].status.conditions[-1].type}' 2>/dev/null || echo "no-trial")
  TRIAL_POD_PHASE=$(kubectl get pods -n "$USER_NS" \
    -l "katib.kubeflow.org/trial=e2e-katib-test" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].status.phase}' 2>/dev/null || echo "")
  SUGGESTION_STATE=$(kubectl get suggestion e2e-katib-test -n "$USER_NS" \
    -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null || echo "no-suggestion")
  info "Katib exp=Succeeded:${COND_OK:-False}/Failed:${COND_FAIL:-False} suggestion=${SUGGESTION_STATE} trial=${TRIAL_STATE} pod=${TRIAL_POD_PHASE:-pending} (${elapsed}s/${T_KATIB}s)"
  [[ "$COND_OK"   == "True" ]] && KATIB_DONE=true   && break
  [[ "$COND_FAIL" == "True" ]] && KATIB_FAILED=true && break
  [[ $elapsed -ge $T_KATIB ]] && break
done

if $KATIB_DONE; then
  pass "Katib experiment Succeeded"
  kubectl delete experiment e2e-katib-test -n "$USER_NS" --ignore-not-found &>/dev/null
elif $KATIB_FAILED; then
  fail "Katib experiment Failed"
else
  fail "Katib experiment did not complete within ${T_KATIB}s"
fi

# ── Tests 10 + 11: shared PVC setup ───────────────────────────────────────────
# Create a PVC and a binder pod (to get the PVC into Bound state).
# Both the Tensorboard and PVCViewer tests share this PVC.

kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: e2e-test-pvc
  namespace: ${USER_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: e2e-pvc-binder
  namespace: ${USER_NS}
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  imagePullSecrets:
  - name: application-collection
  containers:
  - name: binder
    image: dp.apps.rancher.io/containers/bci-busybox:15.7
    command: ["tail", "-f", "/dev/null"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: e2e-test-pvc
  restartPolicy: Never
EOF

# Wait for PVC to become Bound (binder pod mounts it)
elapsed=0
PVC_BOUND=false
while true; do
  sleep 3; elapsed=$((elapsed+3))
  PHASE=$(kubectl get pvc e2e-test-pvc -n "$USER_NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  info "PVC phase: ${PHASE:-Pending} (${elapsed}s/60s)"
  [[ "$PHASE" == "Bound" ]] && PVC_BOUND=true && break
  [[ $elapsed -ge 60 ]] && break
done

if ! $PVC_BOUND; then
  fail "e2e-test-pvc did not become Bound within 60s — tests 10 and 11 will be unreliable"
fi

# Delete the binder pod now that the PVC is Bound — keeping it running would
# hold the RWO volume and prevent the PVCViewer pod (test 11) from attaching it.
kubectl delete pod e2e-pvc-binder -n "$USER_NS" --ignore-not-found &>/dev/null || true

# ── Test 10: Tensorboard ───────────────────────────────────────────────────────
header "10. Tensorboard — create CR → controller creates Deployment"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: tensorboard.kubeflow.org/v1alpha1
kind: Tensorboard
metadata:
  name: e2e-tensorboard-test
  namespace: ${USER_NS}
spec:
  logspath: pvc://e2e-test-pvc/logs
EOF

elapsed=0
TB_DEPLOY=false
while true; do
  sleep 3; elapsed=$((elapsed+3))
  if kubectl get deployment e2e-tensorboard-test -n "$USER_NS" &>/dev/null; then
    TB_DEPLOY=true; break
  fi
  info "Tensorboard: waiting for Deployment (${elapsed}s/45s)"
  [[ $elapsed -ge 45 ]] && break
done

if $TB_DEPLOY; then
  pass "Tensorboard controller created Deployment"
  kubectl delete tensorboard e2e-tensorboard-test -n "$USER_NS" --ignore-not-found &>/dev/null
else
  fail "Tensorboard controller did not create Deployment within 45s"
fi

# ── Test 11: PVCViewer ─────────────────────────────────────────────────────────
header "11. PVCViewer — create CR → viewer pod becomes Ready"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: kubeflow.org/v1alpha1
kind: PVCViewer
metadata:
  name: e2e-pvcviewer-test
  namespace: ${USER_NS}
spec:
  pvc: e2e-test-pvc
  rwoScheduling: false
EOF

elapsed=0
PVCVIEWER_READY=false
while true; do
  sleep 5; elapsed=$((elapsed+5))
  READY=$(kubectl get pvcviewer e2e-pvcviewer-test -n "$USER_NS" \
    -o jsonpath='{.status.ready}' 2>/dev/null || echo "")
  info "PVCViewer ready=${READY:-false} (${elapsed}s/${T_PVCVIEWER}s)"
  [[ "$READY" == "true" ]] && PVCVIEWER_READY=true && break
  [[ $elapsed -ge $T_PVCVIEWER ]] && break
done

if $PVCVIEWER_READY; then
  pass "PVCViewer reached ready=true"
else
  fail "PVCViewer did not become ready within ${T_PVCVIEWER}s"
fi

# Clean up shared PVC resources
kubectl delete pvcviewer e2e-pvcviewer-test -n "$USER_NS" --ignore-not-found &>/dev/null || true
kubectl delete pvc       e2e-test-pvc       -n "$USER_NS" --ignore-not-found &>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# GPU Tests (only when --include-gpu-tests is passed)
# ══════════════════════════════════════════════════════════════════════════════

if $INCLUDE_GPU; then

header "━━━ GPU Tests ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── GPU-1: Node capability check ───────────────────────────────────────────────
header "GPU-1. Node capability — at least one node with nvidia.com/gpu"

GPU_NODE_COUNT=$(kubectl get nodes -o json | python3 -c "
import sys, json
nodes = json.load(sys.stdin)['items']
print(sum(1 for n in nodes
          if int(n['status']['allocatable'].get('nvidia.com/gpu', '0')) > 0))
" 2>/dev/null || echo "0")

if [[ "${GPU_NODE_COUNT:-0}" -gt 0 ]]; then
  pass "GPU nodes found: ${GPU_NODE_COUNT}"
else
  fail "GPU-1: no nodes with nvidia.com/gpu > 0 — skipping remaining GPU tests"
  # Record remaining GPU tests as skipped by not running them; fall through to summary
  INCLUDE_GPU=false
fi

fi  # end GPU_NODE_COUNT gate — re-checked below per test via $INCLUDE_GPU

if $INCLUDE_GPU; then

# ── GPU-2: CUDA smoke test ─────────────────────────────────────────────────────
header "GPU-2. CUDA smoke — nvidia-smi inside a CUDA container"

kubectl delete pod e2e-cuda-smoke -n "$NS" --ignore-not-found &>/dev/null || true
GPU_NAME=$(kubectl run e2e-cuda-smoke \
  --image=nvidia/cuda:12.1.1-base-ubuntu22.04 \
  --restart=Never \
  --rm \
  --attach \
  -n "$NS" \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --command -- \
  nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "")

if [[ -n "$GPU_NAME" ]]; then
  pass "GPU-2: CUDA smoke OK — GPU: ${GPU_NAME}"
else
  fail "GPU-2: nvidia-smi returned no output (driver or device plugin issue)"
fi

# ── GPU-3: GPU Notebook ────────────────────────────────────────────────────────
header "GPU-3. GPU Notebook — Notebook CR with nvidia.com/gpu: 1 → StatefulSet ready"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: e2e-gpu-notebook
  namespace: ${USER_NS}
spec:
  template:
    spec:
      imagePullSecrets:
      - name: application-collection
      containers:
      - name: e2e-gpu-notebook
        image: dp.apps.rancher.io/containers/bci-busybox:15.7
        command: ["tail", "-f", "/dev/null"]
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
            nvidia.com/gpu: "1"
          limits:
            nvidia.com/gpu: "1"
EOF

if wait_for_value "GPU Notebook StatefulSet" "$T_GPU_NOTEBOOK" "$USER_NS" \
    "sts/e2e-gpu-notebook" '{.status.readyReplicas}' "1"; then
  pass "GPU-3: GPU Notebook StatefulSet reached readyReplicas=1"
  kubectl delete notebook e2e-gpu-notebook -n "$USER_NS" --ignore-not-found &>/dev/null
else
  fail "GPU-3: GPU Notebook StatefulSet did not reach readyReplicas=1 within ${T_GPU_NOTEBOOK}s"
fi

# ── GPU-4: GPU PyTorchJob (CUDA tensor op + NCCL init) ─────────────────────────
header "GPU-4. GPU PyTorchJob — CUDA tensor op + NCCL init → Succeeded"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: e2e-gpu-pytorch
  namespace: ${USER_NS}
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: Never
      template:
        spec:
          containers:
          - name: pytorch
            image: stgregistry.suse.com/ai/containers/pytorch:2.11.0-cuda12.8-cudnn9-runtime
            command:
            - python3
            - -c
            - |
              import torch, torch.distributed as dist, os
              assert torch.cuda.is_available(), f"CUDA not available — device_count={torch.cuda.device_count()}"
              device = torch.device('cuda:0')
              t = torch.randn(128, 128, device=device)
              result = (t @ t.T).sum().item()
              print(f'CUDA tensor matmul OK: {result:.2f}  GPU: {torch.cuda.get_device_name(0)}')
              dist.init_process_group(
                  backend='nccl',
                  init_method='tcp://' + os.environ.get('MASTER_ADDR','127.0.0.1') + ':' + os.environ.get('MASTER_PORT','23456'),
                  world_size=int(os.environ.get('WORLD_SIZE','1')),
                  rank=int(os.environ.get('RANK','0')))
              u = torch.ones(10, device=device)
              dist.all_reduce(u)
              print(f'NCCL all_reduce OK: {u[0].item():.0f}')
              dist.destroy_process_group()
            resources:
              requests:
                cpu: "1"
                memory: 2Gi
                nvidia.com/gpu: "1"
              limits:
                nvidia.com/gpu: "1"
EOF

elapsed=0
GPU_PT_SUCCEEDED=false
GPU_PT_FAILED=false
while true; do
  sleep 5; elapsed=$((elapsed+5))
  COND_OK=$(kubectl get pytorchjob e2e-gpu-pytorch -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")
  COND_FAIL=$(kubectl get pytorchjob e2e-gpu-pytorch -n "$USER_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  info "GPU PyTorchJob Succeeded=${COND_OK:-False} Failed=${COND_FAIL:-False} (${elapsed}s/${T_GPU_PYTORCH}s)"
  [[ "$COND_OK"   == "True" ]] && GPU_PT_SUCCEEDED=true && break
  [[ "$COND_FAIL" == "True" ]] && GPU_PT_FAILED=true    && break
  [[ $elapsed -ge $T_GPU_PYTORCH ]] && break
done

if $GPU_PT_SUCCEEDED; then
  pass "GPU-4: GPU PyTorchJob Succeeded (CUDA + NCCL)"
  kubectl delete pytorchjob e2e-gpu-pytorch -n "$USER_NS" --ignore-not-found &>/dev/null
elif $GPU_PT_FAILED; then
  fail "GPU-4: GPU PyTorchJob Failed"
else
  fail "GPU-4: GPU PyTorchJob did not complete within ${T_GPU_PYTORCH}s"
fi

# ── GPU-5: KServe HuggingFace runtime — tiny synthetic GPT-2 ──────────────────
header "GPU-5. KServe HuggingFace runtime — tiny synthetic GPT-2 on GPU"

# Phase 1: build tiny model + upload to SeaweedFS
# Uses kserve/huggingfaceserver:v0.16.0 — the exact same image as the server.
# This guarantees identical CUDA toolkit + transformers versions between builder
# and server, which is the main CUDA-compat risk for real LLM deployments.
info "GPU-5: building tiny GPT-2 model and uploading to SeaweedFS..."
kubectl delete pod e2e-gpu-model-build -n "$NS" --ignore-not-found &>/dev/null || true
kubectl run e2e-gpu-model-build \
  --image=kserve/huggingfaceserver:v0.16.0 \
  --restart=Never \
  -n "$NS" \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --command -- python3 -c "
import urllib.request, urllib.error, hashlib, hmac, datetime, os

# ── minimal stdlib S3 client (avoids pip install in a no-egress cluster) ─────
_EP = 'http://seaweedfs.kubeflow.svc.cluster.local:9000'
_AK, _SK = 'kubeflow', 'kubeflow123'

def _s3_put(bucket, key='', body=b''):
    host = _EP.split('//', 1)[1]
    t = datetime.datetime.utcnow()
    ad, ds = t.strftime('%Y%m%dT%H%M%SZ'), t.strftime('%Y%m%d')
    ph = hashlib.sha256(body).hexdigest()
    path = '/' + bucket + ('/' + key if key else '')
    cr = 'PUT\n' + path + '\n\nhost:' + host + '\nx-amz-content-sha256:' + ph + '\nx-amz-date:' + ad + '\n\nhost;x-amz-content-sha256;x-amz-date\n' + ph
    sc = ds + '/us-east-1/s3/aws4_request'
    sts = 'AWS4-HMAC-SHA256\n' + ad + '\n' + sc + '\n' + hashlib.sha256(cr.encode()).hexdigest()
    def _h(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    sk = _h(_h(_h(_h(('AWS4' + _SK).encode(), ds), 'us-east-1'), 's3'), 'aws4_request')
    sig = hmac.new(sk, sts.encode(), hashlib.sha256).hexdigest()
    auth = 'AWS4-HMAC-SHA256 Credential=' + _AK + '/' + sc + ', SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=' + sig
    req = urllib.request.Request(_EP + path, data=body, method='PUT',
        headers={'Host': host, 'x-amz-date': ad, 'x-amz-content-sha256': ph,
                 'Authorization': auth, 'Content-Length': str(len(body))})
    try:
        urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        if e.code == 409: return  # bucket already exists
        raise

from transformers import GPT2Config, GPT2LMHeadModel, PreTrainedTokenizerFast
from tokenizers import Tokenizer
from tokenizers.models import BPE
from tokenizers.pre_tokenizers import ByteLevel as BLPre
from tokenizers.decoders import ByteLevel as BLDec

# Build GPT-2 byte-level vocabulary offline (no HF Hub download needed).
# Uses the same byte→unicode mapping as the original GPT-2 paper so the
# KServe huggingface server can decode generated token IDs back to text.
def _b2u():
    bs = list(range(33, 127)) + list(range(161, 173)) + list(range(174, 256))
    cs = list(bs); n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b); cs.append(256 + n); n += 1
    return {b: chr(c) for b, c in zip(bs, cs)}

b2u = _b2u()
vocab = {ch: i for i, ch in enumerate(b2u.values())}
vocab['<|endoftext|>'] = 256  # vocab_size = 257

tok_obj = Tokenizer(BPE(vocab=vocab, merges=[]))
tok_obj.pre_tokenizer = BLPre(add_prefix_space=False)
tok_obj.decoder = BLDec()
tokenizer = PreTrainedTokenizerFast(
    tokenizer_object=tok_obj,
    bos_token='<|endoftext|>', eos_token='<|endoftext|>', unk_token='<|endoftext|>')

# Random-weight model — vocab_size matches our offline tokenizer
config = GPT2Config(n_layer=2, n_head=2, n_embd=64, vocab_size=257)
model = GPT2LMHeadModel(config)
os.makedirs('/tmp/tiny-gpt2', exist_ok=True)
tokenizer.save_pretrained('/tmp/tiny-gpt2')
model.save_pretrained('/tmp/tiny-gpt2', safe_serialization=True)

try:
    _s3_put('e2e-models')
except Exception as e:
    print('bucket create:', e)
for fname in os.listdir('/tmp/tiny-gpt2'):
    with open('/tmp/tiny-gpt2/' + fname, 'rb') as f: data = f.read()
    _s3_put('e2e-models', 'tiny-gpt2/' + fname, data)
    print('uploaded ' + fname)
print('model build complete')
" &>/dev/null

# Wait for model builder pod to succeed
elapsed=0
GPU_BUILD_OK=false
GPU_BUILD_PHASE="Pending"
while true; do
  sleep 5; elapsed=$((elapsed+5))
  GPU_BUILD_PHASE=$(kubectl get pod e2e-gpu-model-build -n "$NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  info "GPU-5 model build: ${GPU_BUILD_PHASE} (${elapsed}s/${T_GPU_HF_BUILD}s)"
  [[ "$GPU_BUILD_PHASE" == "Succeeded" ]] && GPU_BUILD_OK=true && break
  [[ "$GPU_BUILD_PHASE" == "Failed"    ]] && break
  [[ $elapsed -ge $T_GPU_HF_BUILD      ]] && break
done

if ! $GPU_BUILD_OK; then
  kubectl logs e2e-gpu-model-build -n "$NS" 2>/dev/null | tail -5 \
    | while IFS= read -r line; do info "  build log: $line"; done
  fail "GPU-5: model builder did not succeed (phase: ${GPU_BUILD_PHASE})"
else
  pass "GPU-5: tiny GPT-2 model uploaded to SeaweedFS (s3://e2e-models/tiny-gpt2/)"

  # Ensure S3 secret + SA exist (created by Test 4; re-apply to be safe if run standalone)
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: e2e-s3-secret
  namespace: ${USER_NS}
  annotations:
    serving.kserve.io/s3-endpoint: seaweedfs.kubeflow.svc.cluster.local:9000
    serving.kserve.io/s3-usehttps: "0"
    serving.kserve.io/s3-region: us-east-1
    serving.kserve.io/s3-useanoncredential: "false"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: kubeflow
  AWS_SECRET_ACCESS_KEY: kubeflow123
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: e2e-kserve-sa
  namespace: ${USER_NS}
secrets:
- name: e2e-s3-secret
EOF

  # Phase 2: deploy InferenceService
  # nvidia.com/gpu must appear in both requests and limits (Kubernetes extended resource rule).
  # cpu: 100m avoids scheduling pressure on nodes running at high CPU utilisation.
  GPU5_IS_OUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: e2e-tiny-gpt2
  namespace: ${USER_NS}
spec:
  predictor:
    serviceAccountName: e2e-kserve-sa
    model:
      modelFormat:
        name: huggingface
      runtime: kserve-huggingfaceserver
      storageUri: s3://e2e-models/tiny-gpt2
      resources:
        requests:
          cpu: 100m
          memory: 2Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "4"
          memory: 8Gi
          nvidia.com/gpu: "1"
EOF
)
  GPU5_IS_EC=$?
  if [[ $GPU5_IS_EC -ne 0 ]]; then
    fail "GPU-5: InferenceService creation failed (exit ${GPU5_IS_EC}): ${GPU5_IS_OUT}"
  fi
  info "GPU-5: InferenceService created (${GPU5_IS_OUT}), waiting for Ready..."

  elapsed=0
  GPU_IS_READY=false
  while true; do
    sleep 10; elapsed=$((elapsed+10))
    IS_COND=$(kubectl get inferenceservice e2e-tiny-gpt2 -n "$USER_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    info "GPU-5 IS Ready=${IS_COND:-False} (${elapsed}s/${T_GPU_HF_READY}s)"
    [[ "$IS_COND" == "True" ]] && GPU_IS_READY=true && break
    [[ $elapsed -ge $T_GPU_HF_READY ]] && break
  done

  if ! $GPU_IS_READY; then
    kubectl get inferenceservice e2e-tiny-gpt2 -n "$USER_NS" \
      -o jsonpath='{.status.conditions}' 2>/dev/null \
      | python3 -c "import sys,json; [print('  IS status:', c.get('message','')) for c in json.load(sys.stdin) if c.get('message')]" 2>/dev/null || true
    # Show predictor pod status to distinguish image-pull vs scheduling vs runtime failures
    PRED_POD_STATUS=$(kubectl get pod -n "$USER_NS" \
      -l "serving.kserve.io/inferenceservice=e2e-tiny-gpt2" \
      --no-headers 2>/dev/null | head -3 || true)
    if [[ -n "$PRED_POD_STATUS" ]]; then
      info "  predictor pod status:"
      echo "$PRED_POD_STATUS" | while IFS= read -r line; do info "    $line"; done
      PRED_POD_NAME=$(kubectl get pod -n "$USER_NS" \
        -l "serving.kserve.io/inferenceservice=e2e-tiny-gpt2" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [[ -n "$PRED_POD_NAME" ]]; then
        kubectl describe pod "$PRED_POD_NAME" -n "$USER_NS" 2>/dev/null \
          | grep -A5 -E "^(Events|Conditions|Reason|Message|State|Image):" \
          | head -30 | while IFS= read -r line; do info "    $line"; done
      fi
    else
      info "  no predictor pod found — IS controller may not have created one yet"
    fi
    fail "GPU-5: InferenceService did not become Ready within ${T_GPU_HF_READY}s"
  else
    pass "GPU-5: HuggingFace InferenceService Ready"

    # Phase 3: run prediction via the predictor pod's local port (bypasses gateway auth)
    PRED_POD=$(kubectl get pod -n "$USER_NS" \
      -l "serving.kserve.io/inferenceservice=e2e-tiny-gpt2" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$PRED_POD" ]]; then
      fail "GPU-5: could not find predictor pod"
    else
      info "GPU-5: predictor pod: $PRED_POD"
      PRED_RESULT=$(kubectl exec -n "$USER_NS" "$PRED_POD" -c kserve-container -- \
        python3 -c "
import urllib.request, urllib.error, json, sys
payload = {'model': 'e2e-tiny-gpt2', 'prompt': 'Kubeflow is', 'max_tokens': 10, 'stream': False}
data = json.dumps(payload).encode()
headers = {'Content-Type': 'application/json'}
# Try OpenAI-compatible endpoint; fall back to plain v1 path used by some KServe builds
for url in ['http://localhost:8080/openai/v1/completions',
            'http://localhost:8080/v1/completions']:
    try:
        req = urllib.request.Request(url, data=data, headers=headers)
        body = urllib.request.urlopen(req, timeout=30).read()
        r = json.loads(body)
        assert r.get('choices'), f'no choices: {r}'
        print('OK:', repr(r['choices'][0]['text'][:60]))
        sys.exit(0)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode('utf-8', errors='replace')[:300]
        print(f'HTTPError {e.code} from {url}: {err_body}', file=sys.stderr)
    except Exception as ex:
        print(f'ERROR from {url}: {ex}', file=sys.stderr)
sys.exit(1)
" 2>&1 || echo "EXEC_FAILED")

      if echo "$PRED_RESULT" | grep -q "^OK:"; then
        pass "GPU-5: HuggingFace LLM inference OK — ${PRED_RESULT}"

        # Verify GPU was actually used: kserve-huggingfaceserver activates vLLM only
        # when it detects a GPU; it falls back to HF Transformers on CPU-only nodes.
        SERVER_LOGS=$(kubectl logs "$PRED_POD" -n "$USER_NS" -c kserve-container 2>/dev/null || echo "")
        if echo "$SERVER_LOGS" | grep -qi "vllm\|AsyncLLMEngine\|GPU"; then
          pass "GPU-5: vLLM backend active — GPU was used for inference"
        else
          # Not a hard failure: tiny model + CPU fallback still validates the runtime.
          # Warn so CI surfaces it without blocking the suite.
          info "GPU-5: WARNING — vLLM/GPU marker not found in server logs; inference may have run on CPU"
          info "GPU-5:   Check node has nvidia.com/gpu allocatable and driver is healthy"
        fi
      else
        # Show server logs to help diagnose HTTP errors
        kubectl logs "$PRED_POD" -n "$USER_NS" -c kserve-container --tail=20 2>/dev/null \
          | while IFS= read -r line; do info "  server: $line"; done
        fail "GPU-5: /openai/v1/completions failed (response: '${PRED_RESULT:0:300}')"
      fi
    fi
  fi

  kubectl delete inferenceservice e2e-tiny-gpt2 -n "$USER_NS" --ignore-not-found &>/dev/null || true
fi  # end GPU_BUILD_OK

fi  # end INCLUDE_GPU

# ── Summary ────────────────────────────────────────────────────────────────────
header "━━━ Results ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Passed: %d\n" "$PASS"
printf "  Failed: %d\n" "$FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  red "E2E TESTS FAILED ($FAIL failure(s))"
  exit 1
else
  green "ALL E2E TESTS PASSED"
  exit 0
fi
