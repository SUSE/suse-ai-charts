"""
Tutorial — Part 7c: Train an Iris classifier and upload it to SeaweedFS
========================================================================
Trains a scikit-learn LogisticRegression on the Iris dataset, serialises
it with joblib, then uploads it to the in-cluster SeaweedFS bucket so KServe
can download it at predictor startup.

Run from a Kubeflow Notebook (recommended)
------------------------------------------
    # SeaweedFS is reachable directly inside the cluster
    pip install boto3 joblib scikit-learn -q
    python train_and_upload.py

Run from your local machine (requires port-forward)
----------------------------------------------------
    kubectl port-forward svc/seaweedfs 9000:9000 -n kubeflow &
    pip install boto3 joblib scikit-learn -q
    python train_and_upload.py --endpoint localhost:9000

Output
------
After a successful run the script prints the storageUri you should put
in sklearn_iris_isvc.yaml, e.g.:

    storageUri: "s3://kserve-models/sklearn/iris"
"""

import argparse
import os
import sys
import tempfile

# ── Install dependencies if missing ──────────────────────────────────────────
for pkg in ("boto3", "scikit-learn", "joblib"):
    try:
        __import__(pkg.replace("-", "_").split("==")[0])
    except ImportError:
        print(f"Installing {pkg} …")
        os.system(f"{sys.executable} -m pip install -q {pkg}")

import boto3                                              # noqa: E402
from botocore.config import Config                        # noqa: E402
import joblib                                             # noqa: E402
from sklearn.datasets import load_iris                    # noqa: E402
from sklearn.linear_model import LogisticRegression       # noqa: E402
from sklearn.metrics import accuracy_score                # noqa: E402
from sklearn.model_selection import train_test_split      # noqa: E402


# ── Training ──────────────────────────────────────────────────────────────────
def train() -> object:
    print("Training Iris LogisticRegression …")
    iris = load_iris()
    X_tr, X_te, y_tr, y_te = train_test_split(
        iris.data, iris.target, test_size=0.2, random_state=42, stratify=iris.target
    )
    model = LogisticRegression(max_iter=200, C=1.0, random_state=42)
    model.fit(X_tr, y_tr)
    acc = accuracy_score(y_te, model.predict(X_te))
    print(f"  Test accuracy : {acc:.4f}")
    print(f"  Classes       : {model.classes_.tolist()}")
    return model


# ── Upload ────────────────────────────────────────────────────────────────────
def upload(
    model,
    *,
    endpoint: str,
    access_key: str,
    secret_key: str,
    bucket: str,
    prefix: str,
    use_tls: bool = False,
) -> str:
    """Upload model.joblib to SeaweedFS and return the KServe storageUri."""
    scheme = "https" if use_tls else "http"
    client = boto3.client(
        "s3",
        endpoint_url=f"{scheme}://{endpoint}",
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="us-east-1",
        config=Config(signature_version="s3v4"),
    )

    # Create bucket if it does not exist
    try:
        client.head_bucket(Bucket=bucket)
        print(f"  Bucket exists  : {bucket}")
    except client.exceptions.ClientError:
        client.create_bucket(Bucket=bucket)
        print(f"  Created bucket : {bucket}")

    # Serialise to a temp file then stream-upload
    with tempfile.NamedTemporaryFile(suffix=".joblib", delete=False) as fh:
        tmp_path = fh.name
        joblib.dump(model, tmp_path)

    object_name = f"{prefix}/model.joblib"
    client.upload_file(tmp_path, bucket, object_name)
    os.unlink(tmp_path)

    storage_uri = f"s3://{bucket}/{prefix}"
    print(f"  Uploaded to    : {storage_uri}")
    return storage_uri


# ── CLI ───────────────────────────────────────────────────────────────────────
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train Iris model and upload to SeaweedFS.")
    p.add_argument(
        "--endpoint",
        default="seaweedfs.kubeflow:9000",
        help="S3-compatible endpoint (default: in-cluster seaweedfs.kubeflow:9000)",
    )
    p.add_argument("--access-key", default="kubeflow",    help="S3 access key")
    p.add_argument("--secret-key", default="kubeflow123", help="S3 secret key")
    p.add_argument("--bucket",     default="kserve-models", help="Target bucket")
    p.add_argument(
        "--prefix",
        default="sklearn/iris",
        help="Path prefix inside the bucket (no leading slash)",
    )
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()

    model       = train()
    storage_uri = upload(
        model,
        endpoint=args.endpoint,
        access_key=args.access_key,
        secret_key=args.secret_key,
        bucket=args.bucket,
        prefix=args.prefix,
    )

    print()
    print("=" * 60)
    print("Model uploaded successfully.")
    print()
    print("Use this storageUri in sklearn_iris_isvc.yaml:")
    print(f'  storageUri: "{storage_uri}"')
    print("=" * 60)
