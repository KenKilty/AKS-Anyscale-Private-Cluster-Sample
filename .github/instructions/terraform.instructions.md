---
applyTo: "infra/**/*.tf,infra/**/*.tftest.hcl,infra/**/*.tfvars.json"
---

# Terraform conventions (loaded for infra/** Terraform files)

One Terraform root owns the lab: `infra/terraform`. Module 1 uses targeted
  Terraform operations for the foundation resources; Module 3 reconciles and tears
down the full lab. Provider `azurerm ~> 5.2`, Terraform `>= 1.9.0`. Changes must
stay aligned with the Microsoft Learn Anyscale-on-Azure, AKS, and ACR docs.

## azurerm v5 gotchas (verified the hard way)

- Every firewall `application_rule` MUST include a `protocols` block (Https:443 /
  Http:80) — a missing block returns an opaque 400.
- `destination_fqdns` requires `dns { proxy_enabled = true }` on the firewall
  policy; without DNS proxy use `fqdn_tags` or IPs/service tags.
- Firewall RCG create is slow (~3 min) and serialized — never drive concurrent ops
  on the same policy.
- `outboundType = userDefinedRouting` needs the UDR + firewall egress allow-list to
  exist **before** AKS create; keep `depends_on = [module.routing, module.firewall]`
  on the AKS module. `outboundType = none` and a UDR are mutually exclusive.
- `azurerm_kubernetes_cluster_extension`: `version` and `release_train` are mutually
  exclusive — set `release_train = null` when pinning an exact `version`.
- Attribute names: `api_server_access_profile.virtual_network_integration_enabled`,
  `azurerm_federated_identity_credential.user_assigned_identity_id`,
  `azurerm_route_table.bgp_route_propagation_enabled`. Use
  `terraform providers schema -json` when unsure.
- VpnGw*AZ SKUs require the attached Standard public IP to declare `zones`.
- GPU node pools: set `gpu_driver` explicitly to avoid spurious replacement plans.

## Private-mode invariants

- Storage/ACR are private-only (public network access disabled). With
  `shared_access_key_enabled = false`, set provider `storage_use_azuread = true`.
- Keep ACR pulls Azure-native (AKS kubelet identity `AcrPull`); don't introduce
  registry credentials.
- Teardown ordering: drain the Anyscale cloud before deleting the AKS extension,
  AKS cluster, and foundation resources.

## No secrets, no machine-specific values

No subscription/tenant/object ids, keys, connection strings, or tokens in committed
`.tf` or checked-in `.tfvars.json`. Real values live only in the git-ignored repo-root
`.env`, exported as `TF_VAR_*` at deploy time; the harness no longer renders a
`terraform.auto.tfvars.json`. No personal checkout paths.

## Validation gate (run for the affected stack before declaring done)

```console
terraform -chdir=<stack> fmt -check -recursive
terraform -chdir=<stack> validate
```

Run `./scripts/anyscale-aks.sh self-test terraform` when identity/private-mode
contracts change. The billable apply test under `tests/e2e` requires separate,
explicit user authorization and must never run as part of the normal gate.
Plan-only tests can't know PE subnet ids — assert PE subnet placement in `apply`
tests, not plan tests. Never run `apply`/`destroy` without explicit user
instruction.
