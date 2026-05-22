# P2S VPN Plan for Anyscale Data Plane Access

Status: proposal only. Do not start implementation until this plan is approved.

## Goal

Add an optional Azure Point-to-Site VPN path so an operator workstation can reach private Anyscale data-plane endpoints from macOS, Windows, and Linux without changing the current Bastion-first control-plane workflow for `kubectl`, Terraform, or Helm.

In this repository, the problem is not Kubernetes API reachability. That already exists through Bastion. The missing piece is a routed client path into the workload VNet so the SaaS-hosted Anyscale console can reach the private browser/session path without relying on the local `workspace-browser-tunnel` port-forward workaround.

## Current Fit

Today the repo already has:

- a private AKS cluster
- Bastion-based local control-plane access
- Azure Firewall-based egress control
- Azure DNS Private Resolver
- an existing `workspace-browser-tunnel` helper in `scripts/setup.sh` that port-forwards ingress-nginx to localhost for troubleshooting

That browser tunnel is useful as a fallback, but it is not the desired steady-state access path. P2S is the missing network primitive that gives the client machine a real route into the VNet for private Anyscale session/browser traffic.

## Recommendation

Implement Phase 1 with Azure VPN Gateway P2S using OpenVPN plus certificate authentication.

Recommended Phase 1 characteristics:

- Azure resource: standard route-based VPN gateway in the existing VNet
- Tunnel type: `OpenVPN (SSL)`
- Auth type: `Certificate`
- Routing mode: split tunnel only
- Client DNS: point VPN clients at the Azure DNS Private Resolver inbound endpoint, not the firewall IP
- Control-plane access: keep Bastion as-is
- Browser fallback: keep `workspace-browser-tunnel` until P2S browser access is proven end to end

Why this is the recommended Phase 1 path:

- it is simpler for a lab than wiring Microsoft Entra app and client behavior into the VPN path
- it still uses native Azure VPN Gateway and the Azure DNS Private Resolver
- it works better as a cross-platform lab access story
- it keeps Bastion unchanged for admin workflows
- Azure CLI already exposes the client-package lifecycle we need after apply via `az network vnet-gateway vpn-client generate` and `az network vnet-gateway vpn-client show-url`

This recommendation accepts the tradeoff that we will need to manage lab certificate material for client onboarding.

## Decision Needed Before Buildout

### Option A: Certificate-auth OpenVPN for lab access

This is the recommended option.

Pros:

- simpler fit for a lab environment
- avoids Microsoft Entra sign-in and client auth complexity in the VPN path
- Azure documents certificate-auth OpenVPN support across Windows, macOS, and Linux, though the client differs by OS
- still uses Azure VPN Gateway and Azure DNS Private Resolver

Cons:

- requires certificate generation and distribution
- we need a clear lab process for issuing, storing, and rotating client certs
- macOS uses an OpenVPN client rather than Azure VPN Client for the documented certificate-auth OpenVPN path

### Option B: Entra ID plus Azure VPN Client

This is the more managed Azure identity option, but not the recommended Phase 1 default for a lab.

Pros:

- no certificate distribution to end users
- strongest Azure-native identity story
- Windows and macOS align cleanly with Azure VPN Client

Cons:

- Linux support is narrower and more client-specific
- it is more than a lab setup usually needs
- it introduces Microsoft Entra behavior into a path that should stay simple

## Proposed Phase 1 Scope

Phase 1 should deliver the Azure-native network path with lab-friendly client auth:

- optional P2S deployment in Terraform
- client profile generation after apply
- OS-aware onboarding helpers for Windows, macOS, and Linux
- validation that the Anyscale console browser/data-plane path works over P2S
- clean Terraform destroy of all VPN-related Azure resources

Phase 1 should not try to solve every client variant on day one.

If we later decide the lab should use Microsoft Entra sign-in, that should be treated as a deliberate auth-model change after the simpler certificate-based path is working.

## Proposed Network Design

### Azure-side additions

Add the following to the existing `10.50.0.0/16` VNet design:

- `GatewaySubnet`: proposed CIDR `10.50.1.64/27`
- P2S client address pool: proposed default `172.16.201.0/24`, configurable
- new VPN gateway public IP
- new route-based VPN gateway with P2S enabled

The proposed `GatewaySubnet` fits the next unused `/27` after the DNS resolver subnets:

- `10.50.1.0/28` AKS API server
- `10.50.1.16/28` DNS resolver inbound
- `10.50.1.32/28` DNS resolver outbound
- `10.50.1.64/27` proposed `GatewaySubnet`
- `10.50.0.128/26` Bastion remains unchanged

### Recommended gateway defaults

Use an AZ SKU by default and keep it overrideable.

Recommended default:

- `VpnGw1AZ`

Reasoning:

- zone-redundant by default
- enough for a small number of operator clients in a sample repo
- materially cheaper than larger SKUs while still supporting P2S OpenVPN

If we later validate that concurrency or throughput is insufficient, bumping to `VpnGw2AZ` should be a straight variable change.

### DNS design for VPN clients

Use the Azure DNS Private Resolver inbound endpoint IP as the VPN client DNS server.

In the current layout, that is expected to be:

- `10.50.1.20`

Reasoning:

- this endpoint is already described by the repo as the hybrid DNS client entry point
- it is the cleanest way for remote VPN clients to resolve private Azure names and any VNet-linked private DNS zones
- it avoids coupling client name resolution to the firewall's VNet DNS proxy path

### Routing requirement specific to this repo

This is the main repo-specific network issue that has to be handled in Terraform.

`modules/routing/main.tf` currently sets:

- `bgp_route_propagation_enabled = false`
- `0.0.0.0/0 -> Azure Firewall private IP`

That is correct for AKS egress control, but it means the AKS node subnet will not automatically learn the P2S client pool route from the VPN gateway.

Because of that, the buildout must add an explicit route on the AKS node route table when P2S is enabled:

- destination: the P2S client pool, for example `172.16.201.0/24`
- next hop type: `VirtualNetworkGateway`

Without that route, replies from workload pods and ingress-backed services to P2S clients are likely to follow the default route toward Azure Firewall instead of returning directly to the VPN gateway.

## Terraform Changes

### Root variables

Add an opt-in P2S configuration surface in `infra/terraform/variables.tf`.

Recommended new inputs:

- `enable_p2s_vpn` default `false`
- `vpn_gateway_sku` default `VpnGw1AZ`
- `p2s_client_address_pool`
- `subnet_cidrs.gateway`
- `p2s_client_dns_servers` defaulting to the resolver inbound IP logic

Keeping the feature disabled by default is important because VPN Gateway is a meaningful always-on cost and slow-create resource.

### Network module

Update `infra/terraform/modules/network` to:

- add `GatewaySubnet`
- include the gateway subnet in outputs
- preserve the Azure-reserved subnet naming requirement exactly

### New VPN module

Add a dedicated module, for example `infra/terraform/modules/vpn`, to own:

- public IP for the VPN gateway
- `azurerm_virtual_network_gateway`
- point-to-site configuration for OpenVPN plus certificate authentication

Phase 1 should not require a new Terraform provider. `azurerm` should be enough for the gateway resources.

### Routing module

Update `infra/terraform/modules/routing` to add the explicit P2S return-path route when `enable_p2s_vpn` is true:

- `p2s_client_pool -> VirtualNetworkGateway`

### Outputs

Expose outputs needed by the harness and operators, for example:

- VPN gateway name
- VPN gateway public IP
- P2S client address pool
- VPN client DNS server list
- `az network vnet-gateway vpn-client generate` command hint
- `az network vnet-gateway vpn-client show-url` command hint

### Terraform tests

Update the Terraform tests under `infra/terraform/tests` to cover the new shape.

At minimum:

- extend the `subnet_cidrs` object to include the gateway subnet
- preserve default test behavior with `enable_p2s_vpn = false`
- add plan assertions for the gateway subnet and P2S return route when P2S is enabled

The important constraint is that adding the optional feature must not destabilize the current private-mode assertions when P2S is off.

## Harness and Client Onboarding Plan

The Azure resource is only half of the work. We also need a post-apply operator flow that turns the gateway configuration into a usable client profile.

### Generated artifacts

After apply, use Azure CLI to generate or retrieve the client profile package:

- `az network vnet-gateway vpn-client generate`
- `az network vnet-gateway vpn-client show-url`

Store generated artifacts under `.cache/aks-anyscale-sample-harness/` so they remain local-only and disappear naturally from the repo surface.

### Profile post-processing

Split client handling by client type instead of treating the generated package as one generic profile format.

For Azure VPN Client artifacts, we can post-process the generated XML profile where the chosen client supports it:

- custom DNS server pointing at the resolver inbound endpoint
- any required DNS suffixes if we confirm they are necessary for the session hostnames

For OpenVPN clients, we should treat the generated package as OpenVPN-native configuration and certificate material, not as Azure VPN Client XML.

We also need a lab certificate flow:

- generate a lab root certificate and store its public material in Terraform or a local input path
- generate one or more client certificates for operator machines
- keep private key material out of Terraform state and out of Git

We should keep split tunneling and avoid forced tunneling in Phase 1.

### OS-specific client plan

Use a short supported matrix and keep the implementation opinionated.

Supported Phase 1 client matrix:

- Windows: Azure VPN Client or OpenVPN client
- macOS: OpenVPN client
- Linux: OpenVPN client or Azure VPN Client

#### Windows

Target experience:

- support either Azure VPN Client or OpenVPN client for certificate-auth OpenVPN
- if we use Azure VPN Client on Windows, XML import and Azure VPN Client DNS customization apply
- if we use OpenVPN on Windows, use the OpenVPN configuration and certificate artifacts directly
- connect directly without Microsoft Entra sign-in

#### macOS

Target experience:

- use an OpenVPN client
- import the generated OpenVPN configuration and client certificate
- connect directly without Microsoft Entra sign-in

#### Linux

Target experience:

- support OpenVPN client or Azure VPN Client for certificate-auth OpenVPN
- choose one lab default during implementation instead of leaving Linux behavior vague
- use Azure VPN Client XML customization only if we explicitly choose Azure VPN Client for the supported Linux flow
- connect directly without Microsoft Entra sign-in

## Validation Plan

Validation needs to prove both correctness and rollback.

### Infrastructure validation

- `terraform validate`
- existing plan tests still pass with `enable_p2s_vpn = false`
- new plan test passes with `enable_p2s_vpn = true`

### Network validation

From a connected VPN client:

- confirm the client receives an address from the P2S pool
- confirm DNS resolution uses the configured resolver endpoint
- resolve the private AKS FQDN
- resolve the target private Anyscale session/browser hostname
- confirm the session path is reachable without the local browser tunnel

### Workflow validation

On at least one client per supported platform:

- Windows
- macOS
- Ubuntu Linux

Prove:

- install or setup instructions are sufficient
- the VPN connects successfully
- the Anyscale console can reach the private data-plane path over P2S
- Bastion-based control-plane workflows still behave exactly as before

### Fallback validation

Keep the current `workspace-browser-tunnel` workflow working until P2S is fully proven. It remains the troubleshooting fallback if the console/browser path regresses.

## Teardown Plan

VPN Gateway resources are slow-create and slow-delete Azure resources. This plan must explicitly account for that.

Implementation should include:

- Terraform-managed destroy of the gateway public IP, VPN gateway, and `GatewaySubnet`
- bounded but realistic destroy timeouts for the VPN gateway resource
- harness-side teardown status reporting so long-running deletes are visible
- Azure CLI validation after destroy that the VPN gateway, public IP, and sample resource groups are gone

The desired lifecycle contract remains the same as the rest of this repo:

- start with nothing in the subscription for this sample
- deploy all required resources
- validate the feature end to end
- destroy everything cleanly
- finish with nothing left behind in the subscription for this sample

Local VPN profile artifacts under `.cache/` can remain local-only and do not need to be tracked by Terraform state.

## Non-Goals for Phase 1

Phase 1 should not include:

- replacing Bastion for Kubernetes API access
- forced tunneling of workstation internet traffic through Azure
- support for every Linux distribution
- changing the VPN auth model again after implementation starts

## Approval Ask

Approve one of the following before buildout begins:

1. Approve Option A: certificate-auth OpenVPN as the lab-friendly default, while still using Azure VPN Gateway and Azure DNS Private Resolver.
2. Reject Option A and switch back to Microsoft Entra ID plus Azure VPN Client as the primary auth model.

If Option A is approved, the next step is implementation of the Terraform changes, client certificate handling, post-apply profile generation flow, OS-aware onboarding helpers, and the teardown validation updates described above.
