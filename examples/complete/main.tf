# A deliberately exhaustive example: every module source shape this module can
# encounter, using only public, credential-free sources so `tofu apply` needs no
# secrets. Nothing here creates cloud infrastructure.
#
# Regenerate the committed manifest.json / terraform.tfstate with:
#   ./scripts/generate-example.sh

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # exact pin
    random = { source = "hashicorp/random", version = "3.9.0" }
    # pessimistic constraint
    null = { source = "hashicorp/null", version = "~> 3.2" }
    # no constraint at all -- resolves to whatever is latest at init
    local = { source = "hashicorp/local" }
  }
}

# The module under test. Records everything below into state at apply time.
module "version_manifest" {
  source = "../.."
}

# ---------------------------------------------------------------------------
# Registry sources
# ---------------------------------------------------------------------------

# Exact version pin.
module "registry_exact_pin" {
  source          = "hashicorp/subnets/cidr"
  version         = "1.0.0"
  base_cidr_block = "10.0.0.0/16"
  networks        = [{ name = "one", new_bits = 8 }]
}

# Pessimistic constraint -- git shows "~> 0.25", never which version ran.
module "registry_range_pin" {
  source  = "cloudposse/label/null"
  version = "~> 0.25"
}

# No version argument at all. The manifest still records what was resolved.
module "registry_unpinned" {
  source = "cloudposse/label/null"
}

# ---------------------------------------------------------------------------
# Git sources -- tags
# ---------------------------------------------------------------------------

# v-prefixed tag.
module "git_tag_v_prefixed" {
  source          = "git::https://github.com/hashicorp/terraform-cidr-subnets.git?ref=v1.0.0"
  base_cidr_block = "10.1.0.0/16"
  networks        = [{ name = "one", new_bits = 8 }]
}

# Tag without a v prefix.
module "git_tag_bare" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"
}

# Prerelease tag.
module "git_tag_prerelease" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0-rc.1"
}

# ---------------------------------------------------------------------------
# Git sources -- branches (no version pin of any kind)
# ---------------------------------------------------------------------------

# Branch named main.
module "git_branch_main" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=main"
}

# Branch named master -- this repo's default branch is not "main".
module "git_branch_master" {
  source          = "git::https://github.com/hashicorp/terraform-cidr-subnets.git?ref=master"
  base_cidr_block = "10.2.0.0/16"
  networks        = [{ name = "one", new_bits = 8 }]
}

# No ref at all: whatever the remote's default branch happens to be.
module "git_default_branch" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git"
}

# ---------------------------------------------------------------------------
# Git sources -- immutable and shorthand
# ---------------------------------------------------------------------------

# Pinned directly to a commit SHA.
module "git_commit_sha" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=488ab91e34a24a86957e397d9f7262ec5925586a"
}

# github.com/owner/repo shorthand rather than an explicit git:: prefix.
module "git_shorthand" {
  source = "github.com/cloudposse/terraform-null-label?ref=0.24.1"
}

# ---------------------------------------------------------------------------
# Local filesystem sources
# ---------------------------------------------------------------------------

# Local path. Carries no version of any kind, so it is content-hashed.
module "local_path" {
  source = "./modules/greeting"
}

# ---------------------------------------------------------------------------
# Resources exist only so the providers above are genuinely exercised.
# ---------------------------------------------------------------------------

resource "random_pet" "example" {}
resource "null_resource" "example" {}

output "manifest" {
  description = "The full version manifest recorded by this apply."
  value       = module.version_manifest.manifest
}
