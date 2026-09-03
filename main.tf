locals {
  manifest = {
    schema = 1

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
