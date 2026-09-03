# Provider facts, resolved at apply time from the working directory.
#
#   .terraform.lock.hcl        -> version selected at init, plus the declared constraint
#   .terraform/providers/**    -> the version whose binary is actually on disk
#
# Both are read now and baked into the manifest; neither file is needed afterwards.

locals {
  lock_path = "${path.root}/.terraform.lock.hcl"
  lock_raw  = fileexists(local.lock_path) ? file(local.lock_path) : ""

  # Stage 1: capture each `provider "<addr>" { ... }` block whole.
  # Non-greedy body up to the first line-initial `}` closes on the block, not on
  # the `]` that ends the hashes list.
  lock_blocks = regexall("(?s)provider\\s+\"([^\"]+)\"\\s*\\{(.*?)\\n\\}", local.lock_raw)

  # Stage 2: pull fields out of each body independently, so field order in the
  # lock file does not matter and a missing `constraints` is not fatal.
  providers_locked = {
    for b in local.lock_blocks : b[0] => {
      version     = try(regex("version\\s*=\\s*\"([^\"]+)\"", b[1])[0], "unknown")
      constraints = try(regex("constraints\\s*=\\s*\"([^\"]+)\"", b[1])[0], "n/a")
    }
  }

  # Installed binaries live at <host>/<ns>/<type>/<version>/<os_arch>/<binary>,
  # so the path itself carries the version. 6 segments exactly.
  provider_bin_paths = try(fileset("${path.root}/.terraform/providers", "**/terraform-provider-*"), [])

  provider_bin_pairs = [
    for p in local.provider_bin_paths : {
      address = join("/", slice(split("/", p), 0, 3))
      version = split("/", p)[3]
    } if length(split("/", p)) >= 6
  ]

  # Grouped, because a stale version directory can survive `init -upgrade` and
  # duplicate keys in a for-expression are a hard error.
  provider_bins_grouped = { for i in local.provider_bin_pairs : i.address => i.version... }

  providers_installed = {
    for address, versions in local.provider_bins_grouped :
    address => join(",", distinct(versions))
  }

  provider_addresses = distinct(concat(
    keys(local.providers_locked),
    keys(local.providers_installed),
  ))

  providers_out = {
    for a in local.provider_addresses : a => {
      version                  = try(local.providers_locked[a].version, "unknown")
      constraints              = try(local.providers_locked[a].constraints, "n/a")
      installed_binary_version = try(local.providers_installed[a], "unknown")
    }
  }
}
