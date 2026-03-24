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
#   1. KFP pipeline  — compile inline spec → submit run → wait for SUCCEEDED
#   2. Notebook      — create CR → wait StatefulSet ready → delete
#   3. PyTorchJob    — submit 1-replica CPU job → wait for Succeeded
#   4. KServe        — build sklearn model → upload to SeaweedFS → deploy IS
#                      → wait for Ready → run prediction

set -uo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
NS=kubeflow
USER_NS=kubeflow-user-example-com
KFP_USER=user@example.com
PASS=0
FAIL=0

# Timeouts (seconds)
T_KFP=300
T_NOTEBOOK=300
T_PYTORCH=300
T_KSERVE_BUILD=300        # model builder pod
T_KSERVE_READY=600        # IS ready

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
  kubectl delete pod            kfp-e2e-helper       -n "$NS"      --ignore-not-found &>/dev/null || true
  kubectl delete notebook       e2e-test-notebook    -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pytorchjob     e2e-test-pytorchjob  -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete inferenceservice e2e-sklearn         -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete secret         e2e-s3-secret     -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete serviceaccount e2e-kserve-sa        -n "$USER_NS" --ignore-not-found &>/dev/null || true
  kubectl delete pod            e2e-model-builder    -n "$NS"      --ignore-not-found &>/dev/null || true
  kubectl delete trainjob       test-trainjob        -n "$USER_NS" --ignore-not-found &>/dev/null || true
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
  --image=curlimages/curl:8.7.1 \
  --restart=Never \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --wait \
  --command -- sh -c "sleep 300" >/dev/null 2>&1

sleep 5

KFP_EXEC="kubectl exec kfp-e2e-helper -n $NS --"
KFP_BASE="http://ml-pipeline.${NS}.svc.cluster.local:8888"
KFP_RUN_NAME="e2e-test-$(date +%s)"

if ! kubectl wait pod/kfp-e2e-helper -n "$NS" --for=condition=Ready --timeout=60s >/dev/null 2>&1; then
  fail "KFP: helper pod did not become Ready within 60s"
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
    PIPELINE_SPEC='{"components":{"comp-echo":{"executorLabel":"exec-echo"}},"deploymentSpec":{"executors":{"exec-echo":{"container":{"command":["sh","-c","echo Kubeflow E2E test OK; date"],"image":"busybox:1.36"}}}},"pipelineInfo":{"name":"e2e-test"},"root":{"dag":{"tasks":{"echo":{"cachingOptions":{"enableCache":false},"componentRef":{"name":"comp-echo"},"taskInfo":{"name":"echo"}}}}},"schemaVersion":"2.1.0","sdkVersion":"kfp-2.0.0"}'

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
      containers:
      - name: e2e-test-notebook
        image: busybox:1.36
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
          containers:
          - name: pytorch
            image: busybox:1.36
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
#     Uses kserve/sklearnserver:v0.15.2 (same image as the server — identical
#     sklearn version avoids pickle compatibility issues).
info "Launching model builder pod..."
kubectl run e2e-model-builder \
  --image=kserve/sklearnserver:v0.15.2 \
  --restart=Never \
  -n "$NS" \
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
    image: busybox:1.36
    command: ["sh", "-c", "echo Trainer V2 OK; date"]
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
