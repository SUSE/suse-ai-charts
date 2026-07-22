"""
Tutorial — Part 1b: Iris Classification Pipeline
==================================================
A three-step ML pipeline demonstrating:
  - Dataset artifacts     : pass dataframes between steps as files
  - Model artifacts       : serialize/deserialize a trained model
  - Metrics artifacts     : log scalar metrics visible in the KFP UI
  - Parameterised inputs  : tune test_size, max_iter, C from the UI at run time

Steps
-----
    load_data  →  train_model  →  evaluate_model
                       │
                   model artifact (joblib file)
        dataset artifacts (CSV files)

Compile
-------
    pip install kfp>=2.0.0 scikit-learn pandas joblib
    python 02_iris_train_eval_pipeline.py
    # → writes compiled/02_iris_train_eval_pipeline.yaml

Upload and run (UI)
-------------------
    1. Kubeflow UI → Pipelines → Upload Pipeline
       Select:  compiled/02_iris_train_eval_pipeline.yaml
    2. Create Run — optionally change test_size / max_iter / C.
    3. After completion click the "evaluate_model" step → Artifacts
       to see the logged accuracy, precision, recall, f1 metrics.
"""

from kfp import dsl
from kfp.dsl import Dataset, Model, Metrics, Input, Output
from kfp.compiler import Compiler
import os


# ---------------------------------------------------------------------------
# Step 1 — Load and split the Iris dataset
# ---------------------------------------------------------------------------
@dsl.component(
    base_image="registry.suse.com/ai/containers/python:3.11-slim",
    packages_to_install=["scikit-learn>=1.4", "pandas>=2.0"],
)
def load_data(
    test_size: float,
    random_state: int,
    train_dataset: Output[Dataset],
    test_dataset: Output[Dataset],
) -> None:
    import pandas as pd
    from sklearn.datasets import load_iris
    from sklearn.model_selection import train_test_split

    iris = load_iris(as_frame=True)
    df = iris.frame  # columns: sepal length (cm), …, target

    X = df.drop("target", axis=1)
    y = df["target"]
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=test_size, random_state=random_state, stratify=y
    )

    train_df = X_tr.copy()
    train_df["target"] = y_tr
    test_df = X_te.copy()
    test_df["target"] = y_te

    train_df.to_csv(train_dataset.path, index=False)
    test_df.to_csv(test_dataset.path, index=False)

    print(f"Train rows : {len(train_df)}")
    print(f"Test  rows : {len(test_df)}")
    print(f"Features   : {list(X.columns)}")


# ---------------------------------------------------------------------------
# Step 2 — Train a Logistic Regression classifier
# ---------------------------------------------------------------------------
@dsl.component(
    base_image="registry.suse.com/ai/containers/python:3.11-slim",
    packages_to_install=["scikit-learn>=1.4", "pandas>=2.0", "joblib>=1.4"],
)
def train_model(
    train_dataset: Input[Dataset],
    max_iter: int,
    C: float,
    model: Output[Model],
) -> None:
    import pandas as pd
    from sklearn.linear_model import LogisticRegression
    import joblib

    df = pd.read_csv(train_dataset.path)
    X = df.drop("target", axis=1)
    y = df["target"]

    clf = LogisticRegression(max_iter=max_iter, C=C, random_state=42)
    clf.fit(X, y)

    joblib.dump(clf, model.path)

    # Store provenance metadata on the artifact
    model.metadata["framework"] = "scikit-learn"
    model.metadata["algorithm"] = "LogisticRegression"
    model.metadata["C"] = str(C)
    model.metadata["max_iter"] = str(max_iter)
    model.metadata["train_samples"] = str(len(y))

    print(f"Trained  : LogisticRegression(C={C}, max_iter={max_iter})")
    print(f"Classes  : {clf.classes_.tolist()}")
    print(f"Coefficients shape: {clf.coef_.shape}")


# ---------------------------------------------------------------------------
# Step 3 — Evaluate on the held-out test set and log metrics
# ---------------------------------------------------------------------------
@dsl.component(
    base_image="registry.suse.com/ai/containers/python:3.11-slim",
    packages_to_install=["scikit-learn>=1.4", "pandas>=2.0", "joblib>=1.4"],
)
def evaluate_model(
    test_dataset: Input[Dataset],
    model: Input[Model],
    metrics: Output[Metrics],
) -> None:
    import pandas as pd
    from sklearn.metrics import (
        accuracy_score,
        precision_score,
        recall_score,
        f1_score,
        confusion_matrix,
    )
    import joblib

    df = pd.read_csv(test_dataset.path)
    X = df.drop("target", axis=1)
    y_true = df["target"]

    clf = joblib.load(model.path)
    y_pred = clf.predict(X)

    accuracy  = accuracy_score(y_true, y_pred)
    precision = precision_score(y_true, y_pred, average="macro")
    recall    = recall_score(y_true, y_pred, average="macro")
    f1        = f1_score(y_true, y_pred, average="macro")
    cm        = confusion_matrix(y_true, y_pred).tolist()

    # These values appear in the KFP UI under the run's "Metrics" tab
    metrics.log_metric("accuracy",        round(accuracy,  4))
    metrics.log_metric("precision_macro", round(precision, 4))
    metrics.log_metric("recall_macro",    round(recall,    4))
    metrics.log_metric("f1_macro",        round(f1,        4))
    metrics.log_metric("test_samples",    len(y_true))

    print(f"Accuracy  : {accuracy:.4f}")
    print(f"Precision : {precision:.4f}")
    print(f"Recall    : {recall:.4f}")
    print(f"F1 (macro): {f1:.4f}")
    print(f"Confusion matrix:\n{cm}")


# ---------------------------------------------------------------------------
# Pipeline wiring
# ---------------------------------------------------------------------------
@dsl.pipeline(
    name="Iris Train & Evaluate",
    description=(
        "Full ML workflow: split Iris data -> train Logistic Regression -> "
        "evaluate and log metrics."
    ),
)
def iris_pipeline(
    test_size: float = 0.2,
    random_state: int = 42,
    max_iter: int = 200,
    C: float = 1.0,
):
    data_task  = load_data(test_size=test_size, random_state=random_state)
    train_task = train_model(
        train_dataset=data_task.outputs["train_dataset"],
        max_iter=max_iter,
        C=C,
    )
    evaluate_model(
        test_dataset=data_task.outputs["test_dataset"],
        model=train_task.outputs["model"],
    )


if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(__file__), "compiled")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "02_iris_train_eval_pipeline.yaml")
    Compiler().compile(iris_pipeline, out_path)
    print(f"Compiled → {out_path}")
