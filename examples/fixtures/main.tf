# Exercises all four module source types simultaneously, plus a provider, so the
# manifest can be checked for correct resolution and correct n/a vs unknown labels.

terraform {
  required_providers {
    random = { source = "hashicorp/random", version = "~> 3.6" }
    # deliberately unconstrained, to exercise the "n/a" constraints path
    null = { source = "hashicorp/null" }
  }
}

module "version_manifest" {
  source = "../.."
}

# 1. Public registry, pinned version
module "from_registry" {
  source  = "cloudposse/label/null"
  version = "0.25.0"
}

# 2. Git, pinned to a tag
module "from_git_tag" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"
}

# 3. Git, tracking a branch -- no version pin of any kind
module "from_git_branch" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=main"
}

# 4. Local filesystem path
module "from_local" {
  source = "./localmod"
}

resource "random_pet" "example" {}
resource "null_resource" "example" {}

output "manifest" { value = module.version_manifest.manifest }
