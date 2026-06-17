terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
  }
}

# NOTE: This module deliberately omits a provider "azurerm" block so it can be
# wrapped by deploy/terraform/stack/ with count or for_each. For standalone use,
# add a provider.tf in your working directory or copy provider.tf.example.
