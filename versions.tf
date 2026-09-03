terraform {
  # terraform_data and all functions used here are available from OpenTofu 1.6.
  # Deliberately NO required_providers: this module must add zero provider
  # dependencies to any configuration that consumes it.
  required_version = ">= 1.6.0"
}
