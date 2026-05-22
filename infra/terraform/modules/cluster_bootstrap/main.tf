locals {
  service_account_labels = {
    "app.kubernetes.io/managed-by" = "Helm"
    "azure.workload.identity/use"  = "true"
  }

  service_account_annotations = {
    "meta.helm.sh/release-name"         = var.extension_release_name
    "meta.helm.sh/release-namespace"    = var.operator_namespace
    "azure.workload.identity/client-id" = var.workload_identity_client_id
    "azure.workload.identity/tenant-id" = var.workload_identity_tenant_id
  }

  nvidia_device_plugin_values = {
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key      = "kubernetes.azure.com/accelerator"
                  operator = "Exists"
                }
              ]
            }
          ]
        }
      }
    }

    tolerations = [
      {
        key      = "nvidia.com/gpu"
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        key      = "node.anyscale.com/accelerator-type"
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        key      = "node.anyscale.com/capacity-type"
        operator = "Exists"
        effect   = "NoSchedule"
      },
    ]
  }

  ingress_nginx_values = {
    controller = {
      progressDeadlineSeconds = 600
      allowSnippetAnnotations = false

      config = {
        "enable-underscores-in-headers" = "true"
        "annotations-risk-level"        = "High"
      }

      autoscaling = {
        enabled = true
      }

      service = {
        annotations = {
          "service.beta.kubernetes.io/azure-load-balancer-internal"                  = "true"
          "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/healthz"
        }
      }

      tolerations = [
        {
          key      = "node.anyscale.com/capacity-type"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]

      admissionWebhooks = {
        patch = {
          tolerations = [
            {
              key      = "node.anyscale.com/capacity-type"
              operator = "Exists"
              effect   = "NoSchedule"
            }
          ]
        }
      }
    }
  }
}

resource "kubernetes_namespace_v1" "operator" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.operator_namespace
  }
}

resource "kubernetes_service_account_v1" "anyscale_operator" {
  count = var.enabled ? 1 : 0

  metadata {
    name        = var.operator_service_account_name
    namespace   = var.operator_namespace
    labels      = local.service_account_labels
    annotations = local.service_account_annotations
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels["app.kubernetes.io/instance"],
      metadata[0].labels["app.kubernetes.io/name"],
      metadata[0].labels["helm.sh/chart"],
    ]
  }

  depends_on = [kubernetes_namespace_v1.operator]
}

resource "kubernetes_namespace_v1" "gpu_resources" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.gpu_resources_namespace
  }
}

resource "helm_release" "nvidia_device_plugin" {
  count = var.enabled ? 1 : 0

  name             = var.nvidia_device_plugin_release_name
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = var.nvidia_device_plugin_chart_version
  namespace        = var.gpu_resources_namespace
  create_namespace = false
  wait             = true
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 1200

  values = [yamlencode(local.nvidia_device_plugin_values)]

  depends_on = [kubernetes_namespace_v1.gpu_resources]
}

resource "kubernetes_namespace_v1" "ingress_nginx" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.ingress_namespace
  }
}

resource "helm_release" "ingress_nginx" {
  count = var.enabled ? 1 : 0

  name             = var.ingress_release_name
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_chart_version
  namespace        = var.ingress_namespace
  create_namespace = false
  wait             = true
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 1200

  values = [yamlencode(local.ingress_nginx_values)]

  depends_on = [kubernetes_namespace_v1.ingress_nginx]
}