"""
Tutorial — Part 4: Generate TensorBoard Training Logs
======================================================
Run this script from a Kubeflow Notebook after mounting a PVC at /logs
(or at any path you choose).  It simulates a 20-epoch training run and
writes TensorFlow summary event files that TensorBoard can display.

Usage (from a Kubeflow Notebook terminal)
------------------------------------------
    # Install TF CPU (lightweight) if not already present
    pip install tensorflow-cpu -q

    # Write logs to the mounted PVC path
    python write_tb_logs.py --log-dir /logs/tb-demo --epochs 30

Then in the Kubeflow UI:
    Tensorboards → New Tensorboard
        Name       : tb-demo
        PVC        : <your-pvc-name>
        Mount path : /logs
    → click Connect to open TensorBoard in the browser.
"""

import argparse
import math
import os
import random


def simulate_training(log_dir: str, epochs: int = 20) -> None:
    """Write simulated train/val loss and accuracy curves."""
    try:
        import tensorflow as tf
    except ImportError:
        print("TensorFlow not found — installing tensorflow-cpu …")
        os.system("pip install -q tensorflow-cpu")
        import tensorflow as tf

    train_log_dir = os.path.join(log_dir, "train")
    val_log_dir   = os.path.join(log_dir, "validation")

    train_writer = tf.summary.create_file_writer(train_log_dir)
    val_writer   = tf.summary.create_file_writer(val_log_dir)

    print(f"Writing TensorBoard logs → {log_dir}")
    print(f"  Train      : {train_log_dir}")
    print(f"  Validation : {val_log_dir}")
    print()

    for epoch in range(1, epochs + 1):
        # Exponential decay curves with a little noise
        t_loss = 1.0  * math.exp(-epoch * 0.20) + 0.01 * random.random()
        t_acc  = 1.0  - 0.8 * math.exp(-epoch * 0.15) + 0.005 * random.random()
        v_loss = 1.15 * math.exp(-epoch * 0.17) + 0.02 * random.random()
        v_acc  = 1.0  - 0.85 * math.exp(-epoch * 0.13) + 0.008 * random.random()

        # Clamp to [0, 1]
        t_acc = max(0.0, min(1.0, t_acc))
        v_acc = max(0.0, min(1.0, v_acc))

        with train_writer.as_default():
            tf.summary.scalar("loss",     t_loss, step=epoch)
            tf.summary.scalar("accuracy", t_acc,  step=epoch)

        with val_writer.as_default():
            tf.summary.scalar("loss",     v_loss, step=epoch)
            tf.summary.scalar("accuracy", v_acc,  step=epoch)

        if epoch % 5 == 0 or epoch == 1:
            print(
                f"  Epoch {epoch:3d}/{epochs} │ "
                f"train_loss={t_loss:.4f}  train_acc={t_acc:.4f} │ "
                f"val_loss={v_loss:.4f}  val_acc={v_acc:.4f}"
            )

    train_writer.flush()
    val_writer.flush()
    print()
    print("Done!  Event files written.")
    print()
    print("Next steps:")
    print("  1. In Kubeflow UI → Tensorboards → New Tensorboard")
    print(f"     Mount path : {os.path.dirname(log_dir) or log_dir}")
    print()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate simulated TF event logs.")
    parser.add_argument(
        "--log-dir",
        default="/logs/tb-demo",
        help="Directory to write TF event files (default: /logs/tb-demo)",
    )
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--seed",   type=int, default=42)
    args = parser.parse_args()

    random.seed(args.seed)
    os.makedirs(args.log_dir, exist_ok=True)
    simulate_training(args.log_dir, args.epochs)
