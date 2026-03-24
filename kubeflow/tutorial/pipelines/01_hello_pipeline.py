"""
Tutorial — Part 1a: Hello World Pipeline
=========================================
A simple two-step pipeline demonstrating KFP v2 basics:
  - @dsl.component  :  defines a self-contained step
  - @dsl.pipeline   :  wires components into a DAG
  - Output passing  :  the output of step 1 is the input to step 2

Compile
-------
    pip install kfp>=2.0.0
    python 01_hello_pipeline.py
    # → writes compiled/01_hello_pipeline.yaml

Upload and run (UI)
-------------------
    1. Kubeflow UI → Pipelines → Upload Pipeline
       Select:  compiled/01_hello_pipeline.yaml
    2. Create Run → fill in the "name" parameter (default: "World")
    3. Watch the two steps complete in the graph view.
    4. Click any step → Logs to see the printed output.
"""

from kfp import dsl
from kfp.compiler import Compiler
import os


@dsl.component(base_image="python:3.11-slim")
def say_hello(name: str) -> str:
    """Step 1 — build a greeting string and return it."""
    message = f"Hello, {name}!  Welcome to Kubeflow Pipelines."
    print(message)
    return message


@dsl.component(base_image="python:3.11-slim")
def log_message(message: str) -> None:
    """Step 2 — receive the greeting and log some stats about it."""
    print(f"[Logger] Received : {message}")
    print(f"[Logger] Words    : {len(message.split())}")
    print(f"[Logger] Characters: {len(message)}")
    print("[Logger] Pipeline completed successfully!")


@dsl.pipeline(
    name="Hello World Pipeline",
    description="A minimal two-step pipeline: greet -> log.",
)
def hello_pipeline(name: str = "World"):
    hello_task = say_hello(name=name)
    log_task   = log_message(message=hello_task.output)
    log_task.after(hello_task)


if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(__file__), "compiled")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "01_hello_pipeline.yaml")
    Compiler().compile(hello_pipeline, out_path)
    print(f"Compiled → {out_path}")
