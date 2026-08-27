# Module 5: AKS Image Integrity

## Purpose

Audit signed and unsigned images with AKS Image Integrity, Azure Policy,
Gatekeeper, and Ratify.

> **Note:** AKS Image Integrity is in Preview and this module demonstrates
> audit-only behavior. Unsigned images are reported as non-compliant but still
> start; this is not admission enforcement and is not suitable for production
> registries or workloads.

## Prerequisites

- Module 4 completed through `sign` and `verify`.
- `TF_VAR_enable_image_integrity=true` was applied by Terraform.
- The deploying identity can create policy assignments at the resource-group
  scope.
- Terraform has registered the `EnableImageIntegrityPreview` subscription
  feature. Registration is eventually consistent; preflight reports its state.
- Azure CLI on the Linux jump host has the `aks-preview` extension version
  `0.5.96` or later. Install or update it before preflight:

  ```bash
  az extension add --name aks-preview --upgrade --yes
  ```

- The Ratify workload identity has `AcrPull` on the private ACR and access to the
  signing certificate.
- Run every procedure and validation command from
  `/opt/anyscale-aks-sample` on the Linux jump host in one shell session.

## Configuration

Terraform creates the Ratify workload identity, federated credential, Azure
Policy initiative assignment, remediation, and required role assignments when
`TF_VAR_enable_image_integrity=true`.

The verification manifests are:

| File | Current function |
| --- | --- |
| `workloads/image-integrity/certstore.yaml` | Trusts the inline public Notation certificate |
| `workloads/image-integrity/store.yaml` | Reads image manifests and signature referrers from private ACR |
| `workloads/image-integrity/verifier.yaml` | Applies the Notation trust policy to the configured repository and certificate subject |

The harness renders these manifests with the current Key Vault URI, tenant,
Ratify client ID, certificate, ACR login server, repository, and certificate
subject before applying them.

## Procedure

### 0. Resolve this deployment's values

Load the synchronized `.env` and derive the Azure resource group, ACR login
server, signed image URI, and unsigned test URI. These variables avoid copying
placeholders into later commands:

```bash
set -a
source .env
set +a
RESOURCE_GROUP="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
ACR_LOGIN_SERVER="$(az acr list --resource-group "${RESOURCE_GROUP}" --query '[0].loginServer' -o tsv)"
ACR_NAME="${ACR_LOGIN_SERVER%%.*}"
SIGNED_IMAGE="${ANYSCALE_CUSTOM_IMAGE_URI:-${ACR_LOGIN_SERVER}/${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}:${ANYSCALE_CUSTOM_IMAGE_TAG}}"
UNSIGNED_IMAGE="${ACR_LOGIN_SERVER}/${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}:unsigned"
printf 'Resource group: %s\nSigned image: %s\nUnsigned image: %s\n' "${RESOURCE_GROUP}" "${SIGNED_IMAGE}" "${UNSIGNED_IMAGE}"
```

> **Stop:** If any printed value is empty or names a different deployment, do
> not continue. Every later command in this module depends on these values.

### 1. Run preflight

```bash
./scripts/anyscale-aks.sh module 5 preflight
```

Expected marker:

```output
IMAGE_INTEGRITY_PREFLIGHT_OK feature_state=Registered aks_preview=<version>
```

The command reports a non-registered feature or an extension below the supported
version as a warning. If the feature is not registered, run these commands and
repeat preflight until the state is `Registered`:

```bash
az feature register --namespace Microsoft.ContainerService --name EnableImageIntegrityPreview
az provider register --namespace Microsoft.ContainerService
```

### 2. Apply the Ratify configuration

```bash
./scripts/anyscale-aks.sh module 5 apply-ratify
```

The command waits for the policy-deployed Ratify pod in `gatekeeper-system`,
downloads the public signing certificate from private Key Vault, renders the
three manifests, and applies them to AKS.

Expected marker:

```output
IMAGE_INTEGRITY_RATIFY_OK
```

### 3. Deploy the signed image

```bash
kubectl create namespace image-integrity-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl run demo-signed \
  --namespace image-integrity-demo \
  --image "${SIGNED_IMAGE}" \
  --command -- sleep 3600
```

The pod starts. Ratify should report successful Notation verification, and
Azure Policy should report the image as compliant.

### 4. Push and deploy an unsigned image

Run the image operations on the Linux jump host:

```bash
podman pull docker.io/anyscale/ray:2.55.1-slim-py312-cu129
podman tag docker.io/anyscale/ray:2.55.1-slim-py312-cu129 \
  "${UNSIGNED_IMAGE}"
TOKEN="$(az acr login --name "${ACR_NAME}" --expose-token --query accessToken -o tsv)"
printf '%s' "${TOKEN}" | podman login "${ACR_LOGIN_SERVER}" \
  --username 00000000-0000-0000-0000-000000000000 \
  --password-stdin
unset TOKEN
podman push "${UNSIGNED_IMAGE}"
```

```bash
kubectl run demo-unsigned \
  --namespace image-integrity-demo \
  --image "${UNSIGNED_IMAGE}" \
  --command -- sleep 3600
```

The unsigned pod also starts. Ratify should report no valid verification result,
and Azure Policy should report the image as non-compliant.

## Validation

Inspect Ratify logs:

```bash
kubectl logs -n gatekeeper-system -l app=ratify --tail=100
```

The signed image should include:

```output
"isSuccess": true
"message": "Notation signature verification success"
```

The unsigned image should include:

```output
"isSuccess": false
"errorReason": "No verification results for the artifact ..."
```

Inspect non-compliant Azure Policy state after evaluation completes:

```bash
az policy state list \
  --resource-group "${RESOURCE_GROUP}" \
  --filter "complianceState eq 'NonCompliant'" \
  --query "[].{resource:resourceId, policy:policyDefinitionName}" -o table
```

The unsigned image should be non-compliant. Its running pod confirms the
audit-only behavior; it does not indicate enforcement.

> **Note:** Azure Policy results are not immediate. Allow at least 15-30 minutes
> in a test subscription and rerun the query; evaluation can take longer. Ratify
> logs give you the immediate signed-versus-unsigned signal.

## Adapt the Lab

Certificate, subject, repository, and enablement are supported inputs. Re-sign
the image and rerun `apply-ratify` after changing any trust value. Ratify
manifest ownership and validation checks are listed in the
[Configuration Reference](../configuration-reference.md#modification-points).

## Troubleshooting

- **Ratify pod is not Ready:** allow the Azure Policy remediation to complete,
  then rerun `apply-ratify`.
- **Feature state is not `Registered`:** wait for subscription feature
  registration and Microsoft.ContainerService provider registration.
- **Ratify identity cannot be resolved:** confirm
  `TF_VAR_enable_image_integrity=true` was applied and the identity exists.
- **Signed image has no verification result:** run `module 4 verify`, compare the
  deployed digest with the signed digest, and check repository and subject scope
  in `verifier.yaml`.
- **Ratify receives ACR `401` responses:** confirm the Ratify workload identity
  has `AcrPull` on the private ACR.
- **Certificate store is not successful:** confirm the signing certificate
  exists and `certstore-inline` reports `issuccess: true`.
- **Both test images are compliant:** confirm `:unsigned` resolves to a digest
  without a signature referrer.

## Production Limitation

This module validates the current Preview audit signal only. It does not provide
admission enforcement and does not block unsigned images from starting. Use a
supported production image-verification control before relying on signature
policy as a deployment gate.

## Next Step

Remove the test namespace from the Linux jump host, then follow
[Clean Up](cleanup.md):

```bash
kubectl delete namespace image-integrity-demo
```
