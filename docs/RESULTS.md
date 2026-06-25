# Lab Results

This file records real harness run results and proof markers from end-to-end
execution of the private Anyscale on AKS sample. Stage durations and proof
strings are copied directly from run logs under
`.cache/aks-anyscale-sample-harness/runs/`.

---

## Modules 1–3: Foundation, Jump Hosts, and Lab Workload

### Deploy — run `20260617T190251Z-deploy`

Source: `.cache/aks-anyscale-sample-harness/runs/20260617T190251Z-deploy/summary.md`

| Stage | Result | Duration |
|---|---:|---:|
| `prepare` | PASS | 6 s |
| `reset-or-state` | PASS | 1 s |
| `terraform-init-validate` | PASS | 5 s |
| `foundation` | PASS | 210 s |
| `bootstrap-a` | PASS | 25 s |
| `platform` | PASS | 412 s |
| `bootstrap-b` | PASS | 15 s |
| `workspaces` | PASS | 260 s |
| `health` | PASS | 115 s |

All 9 deploy stages passed. Total wall time ≈ 17 min.

### Verify — run `20260623T125237Z-verify-full`

Source: `.cache/aks-anyscale-sample-harness/runs/20260623T125237Z-verify-full/summary.md`

| Stage | Result | Duration |
|---|---:|---:|
| `static` | PASS | 16 s |
| `live` | PASS | 290 s |

The `live` stage confirmed: AKS nodes Ready, Anyscale operator `Available`,
`aks-cpu-workspace` and `aks-gpu-workspace` both `RUNNING` with stable worker
pods, and private DNS resolving Storage Blob/DFS and ACR endpoints to Private
Link addresses. The focused live checks reported `pass=9 fail=0 skip=1`; the
only skip was submitter private storage access, which is intentionally bypassed
from jump-host mode.

### Workload proofs — run `20260622T200906Z-workload-all`

Source: `.cache/aks-anyscale-sample-harness/runs/20260622T200906Z-workload-all/`

All five workload proof markers were emitted in a single harness run.

Current-state rerun note: `20260623T130221Z-workload-all` reconfirmed the CPU
workspace, GPU workspace, and CPU build-job proofs. The first GPU train job in
that run hit GPU node-pool capacity because an older proof service was still
using the second T4 node. After terminating that stale proof service,
`20260623T133549Z-workload-pipeline` passed the build, train, and serve stages:
`CPU_BUILD_JOB_PROOF_OK`, `GPU_TRAIN_JOB_PROOF_OK`, and
`GPU_SERVE_SERVICE_PROOF_OK`.

**CPU Ray proof** — executed inside `aks-cpu-workspace`. Proof output:

```
{"marker": "CPU_RAY_PROOF_OK", "row_count": 16, "square_sum": 1240}
CPU_RAY_PROOF_OK
```

**GPU Ray proof** — executed inside `aks-gpu-workspace` on the T4 node pool.
Proof output:

```
{"cube_sum": 784, "gpu_capacity": 1.0, "marker": "GPU_RAY_PROOF_OK", "row_count": 8}
GPU_RAY_PROOF_OK
```

**Build-job proof** — Anyscale job submitted to `aks-cpu-workspace`; dataset
assembled and feature checksum verified. Proof output:

```
{"cpu_capacity": 4.0, "dataset_manifest": {"feature_checksum": 542669, "label_sum": 51, "row_count": 96}, "marker": "CPU_BUILD_JOB_PROOF_OK", "row_count": 96}
CPU_BUILD_JOB_PROOF_OK
```

**GPU Train job proof** — training job ran on the T4 node pool and reached 100 %
accuracy across 96 rows. Proof output:

```
{"cuda_visible_devices": "0", "gpu_capacity": 1.0, "marker": "GPU_TRAIN_JOB_PROOF_OK", "metrics": {"accuracy": 1.0, "correct_predictions": 96, "row_count": 96}}
GPU_TRAIN_JOB_PROOF_OK
```

**GPU Serve service proof** — service `aks-gpu-serve-proof-20260622200906` reached
`RUNNING` state and returned the proof marker over its public endpoint. Proof
output:

```
Service aks-gpu-serve-proof-20260622200906 printed GPU_SERVE_SERVICE_PROOF_OK.
URL: https://aks-gpu-serve-proof-20260622200906-mh5hb.cld-j6fp2ccu2tz18647.s.azure.anyscaleuserdata.com.
GPU_SERVE_SERVICE_PROOF_OK
```

---

## Module 4: Custom Images

### Preflight — run `20260623T005925Z-custom-image-preflight`

The harness verified that the private ACR is reachable and the target image tag
is available. Proof marker:

```
CUSTOM_IMAGE_PREFLIGHT_OK image_uri=cranyscale99bdevwus3.azurecr.io/anyscale/proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129
```

### Apply — run `20260623T012844Z-custom-image-apply`

The harness updated `aks-cpu-workspace` and `aks-gpu-workspace` to use the
custom image. TLS connectivity to the private ACR passed. Pod inspection
afterwards confirmed both workspace pods were `Ready` running:

```
cranyscale99bdevwus3.azurecr.io/anyscale/proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129
```

### Sign — run `20260623T024230Z-custom-image-sign`

The harness signed the image in the private ACR using the Key Vault–backed
Notation certificate. Proof marker:

```
CUSTOM_IMAGE_SIGN_OK image_uri=cranyscale99bdevwus3.azurecr.io/anyscale/proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129 digest=sha256:3225f90c087b66e2b97b864b8c446f2b365fe2cad040b8f9fa846559e29159d5
```

### Verify — run `20260623T134351Z-custom-image-verify`

The harness fetched and verified the Notation signature against the Key Vault
certificate. Proof marker:

```
CUSTOM_IMAGE_VERIFY_OK image_uri=cranyscale99bdevwus3.azurecr.io/anyscale/proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129 digest=sha256:3225f90c087b66e2b97b864b8c446f2b365fe2cad040b8f9fa846559e29159d5
```

### Dependency proof — run `20260623T134359Z-custom-image-proof`

Anyscale job `prodjob_z3uf76g4euqcx1iw9d99jemw33` transitioned
`STARTING → SUCCEEDED`. Job logs:

```json
{"available_providers": ["AzureExecutionProvider", "CPUExecutionProvider"],
 "marker": "CUSTOM_IMAGE_DEPENDENCY_PROOF_OK", "onnxruntime_version": "1.22.0"}
CUSTOM_IMAGE_DEPENDENCY_PROOF_OK
```

This confirms `onnxruntime==1.22.0` was loaded from the custom image in the
private ACR, not from a PyPI install.

---

## Module 5: Image Integrity

### Preflight — run `20260623T134640Z-image-integrity-preflight`

The harness confirmed that the Image Integrity feature flag is registered on
the subscription. Proof marker:

```
IMAGE_INTEGRITY_PREFLIGHT_OK feature_state=Registered aks_preview=0.0.0
```

### Ratify apply — run `20260623T134641Z-image-integrity-apply-ratify`

Source: `.cache/aks-anyscale-sample-harness/runs/20260623T134641Z-image-integrity-apply-ratify/`

| Stage | Result | Duration |
|---|---:|---:|
| `apply-ratify` | PASS | — |

Ratify pod confirmed `Ready`. The three required CRDs (KeyManagementProvider
pointing to the private Key Vault, OrasStore, and NotationVerifier) were applied
or confirmed unchanged. Proof marker:

```
IMAGE_INTEGRITY_RATIFY_OK
```

### Signed vs. unsigned image demo

**Signed image** — pod `demo-signed` was admitted and started using the signed
custom image (`...proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129`).
Ratify verified the Notation signature and allowed admission:

```
Notation signature verification success
isSuccess: true  (digest sha256:3225f90c087b66e2b97b864b8c446f2b365fe2cad040b8f9fa846559e29159d5)
```

**Unsigned image** — pod `demo-unsigned` was admitted and started, because this
sample uses AKS Image Integrity as an audit/reporting signal. Ratify found no
attached signature for `...proof-custom:unsigned` and reported a failed
verification:

```
verifying subject ...:unsigned
isSuccess: false
No verification results for the artifact ...:unsigned. Ensure verifiers are
properly configured and that artifact metadata is attached.
```

The `image-integrity-demo` namespace was deleted after the exercise.
