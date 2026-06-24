---
applyTo: "workloads/**/*.py,workloads/custom-image/**"
---

# Proof & custom-image conventions (loaded for workloads/**)

These scripts are the evidence that the private AKS + Anyscale environment works.
Each prints a single unambiguous **marker** the harness greps for.

## Markers (don't rename without updating the harness grep)
- `CPU_RAY_PROOF_OK` — `cpu_ray_proof.py`
- `GPU_RAY_PROOF_OK` — `gpu_ray_proof.py`
- `CPU_BUILD_JOB_PROOF_OK` — `anyscale_build_cpu_job_proof.py`
- `GPU_TRAIN_JOB_PROOF_OK` — `anyscale_train_gpu_job_proof.py`
- `GPU_SERVE_SERVICE_PROOF_OK` — `anyscale_serve_gpu_proof.py`
- `CUSTOM_IMAGE_DEPENDENCY_PROOF_OK` — `custom_image_dependency_proof.py` (the proof
  emits *only* this success marker; on the standard image the dependency import fails
  and no marker is printed, which the harness then reports as
  `CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK`)

The harness greps these from job/service logs, so emit the marker on its own line,
to stdout, only on the real success/failure condition.

## Custom-image scenario (intentional contrast)
- Representative dependency: `onnxruntime==1.22.0`.
- The **standard-image failure is intentional** — it proves runtime package install
  is blocked in the private data plane. It must be the *only* expected failure.
  Don't "fix" it.
- Success path: image built locally with Podman (`--platform linux/amd64` on Apple
  Silicon), pushed to the **private** ACR, applied to durable workspaces, and passed
  to jobs/services via `--image-uri` (and `--ray-version` when needed).
- Don't bake Podman into the harness — detect and report.

## Conventions
- CPU proofs assert no GPU (`num_gpus=0`); GPU proofs assert `CUDA_VISIBLE_DEVICES`.
- Keep proofs minimal and deterministic; no network installs at runtime (that's the
  whole point of the private data plane).
- Never print tokens or credentials in proof output.

## Validation gate
`python3 -m py_compile` every edited proof before declaring done. A clean compile is
**not** a passing proof — only a real job/service run that emits the marker is.
Typings for Ray live under `typings/ray/`; pyright config is `pyrightconfig.json`.
