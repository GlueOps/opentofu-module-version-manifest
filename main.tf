locals {
  manifest = {
    # Compatibility contract, see "Schema compatibility" in the README.
    # major increments on any breaking change; minor on additive change only.
    schema = {
      major = 1
      minor = 0
    }

    # Lets a consumer identify this record by shape rather than by the module
    # call name, which the consuming configuration is free to choose.
    producer = "GlueOps/opentofu-module-version-manifest"

    # The only deployment identity available to configuration. Without it, two
    # workspaces of the same root module produce byte-identical manifests.
    workspace = terraform.workspace

    root_config = {
      files       = local.root_file_hashes
      fingerprint = local.root_fingerprint
      git_commit  = local.root_git_commit
      git_branch  = local.root_git_branch

      # Structurally unknowable here: cleanliness cannot be derived from git's
      # plumbing files without running `git status`. Compare `fingerprint`
      # against the tree at `git_commit` instead.
      git_dirty = "unknown"
    }

    providers = local.providers_out
    modules   = local.modules_out
  }
}

# Encoded rather than stored as an object: the per-module records are uniform,
# but jsonencode keeps the stored shape stable regardless of how HCL would
# unify types across an empty vs. populated configuration.
resource "terraform_data" "manifest" {
  input = jsonencode(local.manifest)
}
