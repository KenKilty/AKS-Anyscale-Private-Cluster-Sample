# Proof Markers

This document is the source of truth for stable proof markers emitted by the
current harness and workload payloads. A proof marker is credible only when it
appears in the log for a command that exited successfully and the surrounding
evidence identifies the expected environment and resource state.

## Generated Results and Evidence

`./scripts/anyscale-aks.sh e2e` writes a generated `RESULTS.md` at the repository
root. That report contains the command, overall status, build/validation/custom
image/workload/teardown statuses, links to local logs, and selected evidence
lines. It is generated run output and is not this tracked reference.

Detailed evidence is stored under:

```text
.cache/aks-anyscale-sample-harness/runs/<timestamp>-<command>/
```

Each run directory can contain `summary.md`, `stages.tsv`, per-stage logs, and
diagnostics. Read the root report and its referenced `.cache` files together.
Do not commit generated root results or `.cache` evidence.

## Current Markers

| Marker | Evidence interpretation |
| --- | --- |
| `CPU_RAY_PROOF_OK` | The CPU durable workspace executed the Ray CPU payload and returned its expected result. |
| `GPU_RAY_PROOF_OK` | The GPU durable workspace scheduled GPU work and completed the Ray GPU payload. |
| `CPU_BUILD_JOB_PROOF_OK` | The Anyscale CPU build job completed and printed the deterministic job payload result. |
| `GPU_TRAIN_JOB_PROOF_OK` | The Anyscale GPU training job completed with the expected GPU and training result. |
| `GPU_SERVE_SERVICE_PROOF_OK` | The Anyscale service reached `RUNNING` and its private endpoint returned the expected Serve response. |
| `CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK` | The standard image failed only because the configured dependency was absent; this is an expected negative proof. |
| `CUSTOM_IMAGE_PREFLIGHT_OK` | Podman, Azure auth, private ACR resolution, and required custom-image inputs passed preflight. |
| `CUSTOM_IMAGE_BUILD_OK` | The configured `linux/amd64` custom image was built and pushed to private ACR. |
| `CUSTOM_IMAGE_DEPENDENCY_PROOF_OK` | The custom image imported and executed the packaged dependency at the required version. |
| `CUSTOM_IMAGE_SBOM_OK` | An SBOM was generated and attached to the pushed image digest. |
| `CUSTOM_IMAGE_SBOM_PROOF_OK` | The attached SBOM was retrieved and contains the required dependency. |
| `CUSTOM_IMAGE_SIGN_OK` | The private ACR image digest was signed through the configured Key Vault certificate. |
| `CUSTOM_IMAGE_VERIFY_OK` | Notation verified the signature for the expected image digest and trust policy. |
| `IMAGE_INTEGRITY_PREFLIGHT_OK` | Required AKS feature registration and image-integrity prerequisites are available. |
| `IMAGE_INTEGRITY_RATIFY_OK` | Ratify resources and their workload identity configuration were applied successfully. |
| `PRIVATELINK_DNS_PROOF_OK` | The cloud-specific Anyscale hostname resolved from the Windows browser jump host to the Terraform private endpoint IP. |
| `PRIVATELINK_DNS_PROOF_FAIL` | Private Link DNS evidence is invalid or incomplete; the marker includes the failing hostname and available IP facts. |

## Interpreting Evidence

- A bare marker copied without its command exit status and log path is not a
  complete proof.
- Job evidence should include Anyscale state `SUCCEEDED` and the matching job
  proof marker.
- Service evidence should include service and primary version state `RUNNING`,
  a successful private endpoint response, and
  `GPU_SERVE_SERVICE_PROOF_OK`.
- Workspace evidence should identify the expected durable workspace in
  `RUNNING` state and the CPU or GPU proof marker from its pod log.
- The standard-image marker is a pass only when the missing configured
  dependency is the failure cause. Network, auth, scheduling, or unrelated
  import failures are failures.
- Build, SBOM, signature, and verification markers apply to the image URI and
  digest printed on the same evidence line. Do not substitute evidence from a
  different tag or digest.
- `PRIVATELINK_DNS_PROOF_OK` proves DNS-to-private-endpoint agreement. Confirm
  the Azure private endpoint connection is approved and perform the TLS probe
  before treating the control-plane path as operational.
- `PASS`, `FAIL`, `RUNNING`, `PENDING`, and `SKIP` in the generated root report
  summarize stages. The referenced logs remain the evidence for those states.
