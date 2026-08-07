"""
Tutorial — Appendix D: KFP Pipeline with a GPU step
=====================================================
Demonstrates how to request a GPU for a KFP pipeline component.

The `train_on_gpu` component trains a two-layer MLP on MNIST using
PyTorch.  It uses CUDA when a GPU is available and falls back to CPU
gracefully so the pipeline can be tested on CPU-only clusters too.

Usage
-----
  pip install kfp>=2.0.0
  python 03_gpu_pipeline.py
  # Uploads compiled/03_gpu_pipeline.yaml — run it via the KFP UI.
"""

import os
from pathlib import Path
from kfp import dsl, compiler


# ── GPU component ─────────────────────────────────────────────────────────────

@dsl.component(
    base_image="registry.suse.com/ai/containers/pytorch/pytorch:2.11.0-cuda12.8-cudnn9-runtime",
    packages_to_install=["torchvision"],
)
def train_on_gpu(
    epochs: int,
    lr: float,
    accuracy: dsl.Output[dsl.Metrics],
) -> float:
    """Train a small MLP on MNIST; returns test accuracy."""
    import torch
    import torch.nn as nn
    from torchvision import datasets, transforms
    from torch.utils.data import DataLoader

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Using device: {device}")
    if torch.cuda.is_available():
        print(f"  GPU: {torch.cuda.get_device_name(0)}")

    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,)),
    ])
    train_data = datasets.MNIST("/tmp/data", train=True,  download=True, transform=transform)
    test_data  = datasets.MNIST("/tmp/data", train=False, download=True, transform=transform)
    train_loader = DataLoader(train_data, batch_size=256, shuffle=True)
    test_loader  = DataLoader(test_data,  batch_size=512)

    model = nn.Sequential(
        nn.Flatten(),
        nn.Linear(784, 256), nn.ReLU(),
        nn.Linear(256, 10),
    ).to(device)
    opt = torch.optim.Adam(model.parameters(), lr=lr)

    for epoch in range(1, epochs + 1):
        model.train()
        for data, target in train_loader:
            data, target = data.to(device), target.to(device)
            opt.zero_grad()
            nn.CrossEntropyLoss()(model(data), target).backward()
            opt.step()
        print(f"Epoch {epoch}/{epochs} complete")

    # Evaluate
    model.eval()
    correct = 0
    with torch.no_grad():
        for data, target in test_loader:
            data, target = data.to(device), target.to(device)
            correct += (model(data).argmax(1) == target).sum().item()
    test_acc = correct / len(test_data)
    print(f"Test accuracy: {test_acc:.4f}")

    accuracy.log_metric("accuracy", test_acc)
    accuracy.log_metric("device",   str(device))
    return test_acc


# ── Pipeline ──────────────────────────────────────────────────────────────────

@dsl.pipeline(name="GPU Training Pipeline", description="MNIST MLP on GPU via KFP")
def gpu_pipeline(
    epochs: int = 3,
    lr: float   = 1e-3,
):
    task = train_on_gpu(epochs=epochs, lr=lr)

    # Request 1 NVIDIA GPU for this step.
    # The resourceType string is used verbatim as the Kubernetes resource name,
    # so it must be "nvidia.com/gpu" — not "NVIDIA GPU" (which is invalid).
    task.set_accelerator_type("nvidia.com/gpu").set_gpu_limit(1)

    # Optionally constrain CPU / memory alongside the GPU request:
    task.set_cpu_request("500m").set_memory_request("2G")
    task.set_cpu_limit("2").set_memory_limit("8G")


# ── Compile ───────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    out = Path(__file__).parent / "compiled" / "03_gpu_pipeline.yaml"
    out.parent.mkdir(exist_ok=True)
    compiler.Compiler().compile(gpu_pipeline, str(out))
    print(f"Compiled → {out}")
