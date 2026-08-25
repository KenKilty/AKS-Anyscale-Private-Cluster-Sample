terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.12"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

  }
}
