# Module 4: Custom Images for a Private Data Plane

## Purpose

Build an AMD64 custom Ray image on the Linux jump host, push it to the private
ACR, apply it to the durable Anyscale workspaces, and prove that the packaged
dependency is available without runtime package downloads.

The standard-image check is an intentional expected failure. Firewall egress in
the private data plane blocks the runtime installation of
`onnxruntime==1.22.0`.

## Prerequisites

- Module 3 is deployed and its proofs pass.
- Run these procedures from `/opt/anyscale-aks-sample` on the Linux jump host,
  where private ACR and Key Vault DNS resolve.
- Module 2 bootstrap installed Podman, Notation, the `notation-azure-kv` plugin,
  Syft, and ORAS. Rerun `module 2 bootstrap` on the Linux jump host if a tool is
  missing, then use `module 4 preflight` to confirm this module's toolchain.
- The Linux jump-host managed identity can push to ACR and create and use the
  signing certificate. The template grants the required lab roles when
  `TF_VAR_assign_jump_host_subscription_contributor=true`. If you disable that
  broad grant, an administrator must provide equivalent scoped ACR, Key Vault,
  AKS, and role-assignment permissions before continuing.
- Anyscale CLI authentication is cached. If required, run:

  ```bash
  ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login --no-browser
  ```

## Configuration

The harness builds the image URI as:

```text
<ACR login server>/<repository>:<tag>
```

`module 4 preflight` prints the resolved URI before any build. Compare it with
the workstation Terraform output described below and stop if they differ.

Set custom-image values in `.env` using the names documented in
`.env-template`:

| Setting | Current default | Function |
| --- | --- | --- |
| `ANYSCALE_CUSTOM_IMAGE_ENABLED` | `false` | Set to `true` before starting this module; signing and workspace application require it |
| `ANYSCALE_CUSTOM_IMAGE_REPOSITORY` | `anyscale/proof-custom` | ACR repository |
| `ANYSCALE_CUSTOM_IMAGE_TAG` | `onnxruntime-1.22.0-ray-2.55.1-py312-cu129` | Image tag |
| `ANYSCALE_CUSTOM_IMAGE_RAY_VERSION` | `2.55.1` | Ray version passed with the image URI |
| `ANYSCALE_CUSTOM_IMAGE_REQUIREMENT` | `onnxruntime==1.22.0` | Dependency checked by the proofs |
| `ANYSCALE_CUSTOM_IMAGE_BUILD_MODE` | `podman` | Build implementation |
| `ANYSCALE_CUSTOM_IMAGE_BASE_IMAGE` | `docker.io/anyscale/ray:2.55.1-slim-py312-cu129` | Base image for the AMD64 build |
| `ANYSCALE_CUSTOM_IMAGE_URI` | empty | Optional complete image URI override |

Before syncing the jump host, set this in the workstation `.env`:

```bash
ANYSCALE_CUSTOM_IMAGE_ENABLED="true"
```

The harness derives the ACR name from the lab naming inputs when
`ANYSCALE_CUSTOM_IMAGE_URI` is empty. On the workstation, confirm the actual
login server after Module 3:

```bash
terraform -chdir=infra/terraform output -raw acr_login_server
```

If you set `TF_VAR_global_name_suffix` or changed the registry naming contract,
set `ANYSCALE_CUSTOM_IMAGE_URI` to the complete URI using that login server.

> **Warning:** Any change to the workstation `.env` requires `module 2 sync`
> before you run jump-host commands. Without the resync, the Linux jump host
> keeps using the previous values.

## Procedure

Run every command in this procedure from the same Linux jump-host shell in
`/opt/anyscale-aks-sample`.

> **Stop:** Do not continue past the first missing proof marker. Every later
> step depends on the image digest produced by the steps before it.

### 1. Confirm the standard-image failure

```bash
./scripts/anyscale-aks.sh module 4 prove-failure
```

The command must report the expected failure rather than a successful install:

```output
CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK requirement=onnxruntime==1.22.0
```

> **Note:** This failure is the intended result of the lesson. It proves that
> firewall egress blocks runtime package downloads inside the private data
> plane. A successful install here means egress is more permissive than the
> reference posture expects.

### 2. Build and push the image

```bash
./scripts/anyscale-aks.sh module 4 preflight
./scripts/anyscale-aks.sh module 4 prepare
```

`preflight` checks Podman, private ACR DNS, Azure identity, and ACR push access.
`prepare` builds with `--platform linux/amd64`, verifies the resulting image is
`linux/amd64`, pushes it with a short-lived ACR token supplied over stdin, and
confirms that the tag is visible in ACR.

### 3. Sign and verify the image

```bash
./scripts/anyscale-aks.sh module 4 sign
./scripts/anyscale-aks.sh module 4 verify
```

`sign` resolves the image digest, creates the configured signing certificate in
the private Key Vault when absent, and attaches a COSE Notation signature as an
OCI referrer. `verify` downloads the public certificate, imports a repository-
scoped trust policy, and verifies the digest.

### 4. Generate and prove the SBOM

```bash
./scripts/anyscale-aks.sh module 4 sbom
./scripts/anyscale-aks.sh module 4 sbom-proof
```

`sbom` uses Syft to generate SPDX JSON and ORAS to attach it as an
`application/spdx+json` OCI referrer. When Notation and the Azure Key Vault
plugin are available, it also signs the SBOM referrer. `sbom-proof` pulls the
referrer and checks for `onnxruntime==1.22.0`.

### 5. Apply and prove the image

```bash
./scripts/anyscale-aks.sh module 4 apply
./scripts/anyscale-aks.sh module 4 proof
```

`apply` updates `aks-cpu-workspace` and `aks-gpu-workspace` to use the image URI
and `ANYSCALE_CUSTOM_IMAGE_RAY_VERSION`. `proof` imports the packaged dependency
inside the Anyscale platform workload.

## Validation

Confirm these proof markers in the command output and captured evidence:

- [`CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK`](../proof-markers.md)
- [`CUSTOM_IMAGE_PREFLIGHT_OK`](../proof-markers.md)
- [`CUSTOM_IMAGE_BUILD_OK`](../proof-markers.md)
- [`CUSTOM_IMAGE_SIGN_OK`](../proof-markers.md)
- [`CUSTOM_IMAGE_VERIFY_OK`](../proof-markers.md)
- [`CUSTOM_IMAGE_SBOM_OK`](../proof-markers.md)
- [`CUSTOM_IMAGE_SBOM_PROOF_OK`](../proof-markers.md)
- [`CUSTOM_IMAGE_DEPENDENCY_PROOF_OK`](../proof-markers.md)

The dependency proof includes the installed version and available ONNX Runtime
providers. A successful standard-image install is not valid evidence; it means
firewall egress may permit a runtime package source.

## Adapt the Lab

Image repository, tag, Ray version, base image, and dependency are student-facing
`.env` or build inputs. Keep the Ray version and base-image tag aligned, then
rebuild, sign, regenerate the SBOM, apply, and rerun all proofs. Source ownership
and checks are in the
[Configuration Reference](../configuration-reference.md#modification-points).

## Troubleshooting

- **Private ACR DNS check fails:** run the command on the Linux jump host and
  verify both the registry and regional data endpoint resolve to their private
  endpoint addresses.
- **ACR push is denied:** grant `AcrPush` or an equivalent repository push role
  to the active Azure identity and allow role propagation to complete.
- **Podman is installed but not ready:** start the Podman machine, then rerun
  `preflight`.
- **Standard-image check succeeds:** review firewall egress for package registry
  access. The standard-image path is expected to fail.
- **Signing cannot reach Key Vault:** run from the Linux jump host and confirm
  the identity has the configured certificate and crypto roles.
- **The SBOM is attached but unsigned:** install Notation and the
  `notation-azure-kv` plugin, then rerun `sbom`.
- **The proof uses an earlier image:** confirm the configured tag and digest,
  rerun `apply`, and restart the durable workspace if required.

## Next Step

Continue to [Module 5: AKS Image Integrity](module-5-image-integrity.md), or use
[Clean Up](cleanup.md) to remove the environment.
