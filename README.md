<!-- BEGIN_TF_DOCS -->
# opentofu-module-version-manifest

Records **what was actually resolved and applied** — provider versions, module
versions, and git commit SHAs — into your OpenTofu state file, at apply time.

## Why

Git records what was *declared*. Nothing OpenTofu writes natively records what was
*resolved*:

| Artifact | Providers | Modules | Semantics |
|---|---|---|---|
| State file | source address only, **no version** | module path only | written by last apply |
| `.terraform.lock.hcl` | version + constraints + hashes | **nothing** | resolved at init |
| `.terraform/modules/modules.json` | — | `Version` for registry only; git sources keep the raw `?ref=` string | resolved at init |
| `tofu show -json` | `provider_name`, `version_constraint` | `source`, `version_constraint` | declared |
| `tofu version -json` | `provider_selections` | — | resolved, *at command time* |

The lock file documentation is explicit: *"the dependency lock file tracks only
provider dependencies. OpenTofu does not remember version selections for remote
modules."* And `modules.json` never records a commit SHA for git sources.

So all version truth lives in `.terraform/` and `.terraform.lock.hcl`, which describe
**the working directory now** — not **the moment of the last apply**. Run
`tofu init -upgrade` after an apply and those files describe a configuration that was
never applied, with nothing to flag the discrepancy.

This module reads those files *during the apply* and bakes the resolved values into
state, where they survive.

## Usage

One block, once per root configuration. No variables, no wiring, no wrapper script,
and **no provider dependencies** — it uses only built-in functions and the built-in
`terraform_data` resource, so it adds nothing to your lock file.

(The `terraform` provider listed under Providers below is OpenTofu's built-in one,
which backs `terraform_data`. It is not downloaded and never appears in your
`.terraform.lock.hcl`.)

```hcl
module "version_manifest" {
  source = "git::https://github.com/GlueOps/opentofu-module-version-manifest.git?ref=v0.0.1"
}
```

Then `tofu apply` as normal. Every module and provider in the configuration is
discovered automatically.

## Reading the record

The record is a JSON string stored in `terraform_data.manifest`.

From `tofu show -json` (the `input` value comes back unwrapped):

```sh
tofu show -json \
  | jq '.values.root_module.child_modules[]
        | select(.address=="module.version_manifest")
        | .resources[] | select(.type=="terraform_data")
        | .values.input | fromjson'
```

From the raw state file — note the `.value`, because `input` is typed `any` and is
stored as `{"type":…,"value":…}`:

```sh
jq -r '.resources[]
       | select(.module=="module.version_manifest" and .type=="terraform_data")
       | .instances[0].attributes.input.value | fromjson' terraform.tfstate
```

## Output

```json
{
  "schema": 1,
  "root_config": {
    "files":       { "main.tf": "<sha256>" },
    "fingerprint": "<sha256 over the sorted per-file hashes>",
    "git_commit":  "<40-hex sha>",
    "git_branch":  "main",
    "git_dirty":   "unknown"
  },
  "providers": {
    "registry.opentofu.org/hashicorp/random": {
      "version":                  "3.9.0",
      "constraints":              "~> 3.6",
      "installed_binary_version": "3.9.0"
    }
  },
  "modules": {
    "from_git_branch": {
      "source":           "git::https://github.com/example/mod.git?ref=main",
      "source_type":      "git",
      "declared_ref":     "main",
      "ref_type":         "branch",
      "resolved_version": "n/a",
      "resolved_commit":  "38364d79c1082de13373666252e1276975919543",
      "content_hash":     "n/a",
      "dir":              ".terraform/modules/from_git_branch"
    }
  }
}
```

`version` is what the lock file selected; `installed_binary_version` is the version
whose binary is actually on disk under `.terraform/providers/`. They normally agree.

OpenTofu's own version and the apply counter are **not** in the manifest — config
cannot read them (there is no `terraform.version`). They are already written natively
to the top level of the same state file as `terraform_version`, `serial` and `lineage`.

### `n/a` vs `unknown`

Strictly distinguished, never silently omitted:

- **`n/a`** — not applicable to this source type (a registry module has no commit)
- **`unknown`** — applicable, but could not be resolved

### Coverage by module source type

| Source type | `resolved_version` | `resolved_commit` | `content_hash` |
|---|---|---|---|
| Registry | ✅ | `n/a` | `n/a` |
| Git tag (`?ref=v1.2.3`) | `n/a` | ✅ | `n/a` |
| Git branch (`?ref=main`) | `n/a` | ✅ | `n/a` |
| Git commit (`?ref=<sha>`) | `n/a` | ✅ | `n/a` |
| Local path | `n/a` | `n/a` | ✅ |

`ref_type` reports whether the declared ref was a `tag`, `branch`, `commit`, or the
remote's `default_branch` — the source string alone cannot distinguish these, so it is
derived from the clone's refs.

`content_hash` covers a local module's Terraform sources — `*.tf`, `*.tf.json`,
`*.tftpl`, `*.tpl` — not every file in the directory. A module's identity is its
Terraform source, so a README edit beside it is not a change to the module; hashing
everything would also make the value unstable whenever a tool writes output into the
module directory.

## Example

<!-- BEGIN\_EXAMPLE -->
<!-- Generated by scripts/generate-example.sh -- do not edit by hand. -->

### Example configuration

Every module source shape this module can encounter, in one configuration. It uses
only public, credential-free sources, so `tofu apply` needs no secrets and creates
no cloud infrastructure. Live at [`examples/complete`](examples/complete).

```hcl
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
```

### What gets recorded

Applying the above produces this, keyed by module. Commit SHAs and content hashes
are truncated here for width; the committed artifact has them in full.

| Module | `source_type` | `declared_ref` | `ref_type` | `resolved_version` | `resolved_commit` | `content_hash` |
| --- | --- | --- | --- | --- | --- | --- |
| `git_branch_main` | `git` | `main` | `branch` | `n/a` | `38364d79c108…` | `n/a` |
| `git_branch_master` | `git` | `master` | `branch` | `n/a` | `f86cbe2f1041…` | `n/a` |
| `git_commit_sha` | `git` | `488ab91e34a24a86957e397d9f7262ec5925586a` | `commit` | `n/a` | `488ab91e34a2…` | `n/a` |
| `git_default_branch` | `git` | `n/a` | `default_branch` | `n/a` | `38364d79c108…` | `n/a` |
| `git_shorthand` | `git` | `0.24.1` | `tag` | `n/a` | `dc699992922b…` | `n/a` |
| `git_tag_bare` | `git` | `0.25.0` | `tag` | `n/a` | `488ab91e34a2…` | `n/a` |
| `git_tag_prerelease` | `git` | `0.25.0-rc.1` | `tag` | `n/a` | `503f50c2fbf6…` | `n/a` |
| `git_tag_v_prefixed` | `git` | `v1.0.0` | `tag` | `n/a` | `52ca061aaea2…` | `n/a` |
| `local_path` | `local` | `n/a` | `n/a` | `n/a` | `n/a` | `e4135bcb1fbb…` |
| `local_path.nested` | `local` | `n/a` | `n/a` | `n/a` | `n/a` | `cc12eb0ab8e2…` |
| `registry_exact_pin` | `registry` | `n/a` | `n/a` | `1.0.0` | `n/a` | `n/a` |
| `registry_range_pin` | `registry` | `n/a` | `n/a` | `0.25.0` | `n/a` | `n/a` |
| `registry_unpinned` | `registry` | `n/a` | `n/a` | `0.25.0` | `n/a` | `n/a` |
| `version_manifest` | `local` | `n/a` | `n/a` | `n/a` | `n/a` | `35aa4bae40d2…` |

Note what the three registry entries show: `registry_range_pin` was declared as
`~> 0.25` and `registry_unpinned` declared no version at all, yet both record the
exact version that ran. And `git_default_branch` — which names no ref whatsoever —
resolves to the same commit as `git_branch_main`, because that is the repository's
default branch.

Providers are recorded with both the version the lock file selected and the version
whose binary was actually on disk:

| Provider | `constraints` | `version` | `installed_binary_version` |
| --- | --- | --- | --- |
| `local` | `n/a` | `2.9.0` | `2.9.0` |
| `null` | `~> 3.2` | `3.3.1` | `3.3.1` |
| `random` | `3.9.0` | `3.9.0` | `3.9.0` |

### Manifest shape

Abridged to four representative modules. The full artifact is committed at
[`examples/complete/manifest.json`](examples/complete/manifest.json), and the state
file it was extracted from is at
[`examples/complete/terraform.tfstate`](examples/complete/terraform.tfstate).

```json
{
  "modules": {
    "git_branch_main": {
      "content_hash": "n/a",
      "declared_ref": "main",
      "dir": ".terraform/modules/git_branch_main",
      "ref_type": "branch",
      "resolved_commit": "38364d79c1082de13373666252e1276975919543",
      "resolved_version": "n/a",
      "source": "git::https://github.com/cloudposse/terraform-null-label.git?ref=main",
      "source_type": "git"
    },
    "git_tag_bare": {
      "content_hash": "n/a",
      "declared_ref": "0.25.0",
      "dir": ".terraform/modules/git_tag_bare",
      "ref_type": "tag",
      "resolved_commit": "488ab91e34a24a86957e397d9f7262ec5925586a",
      "resolved_version": "n/a",
      "source": "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0",
      "source_type": "git"
    },
    "local_path": {
      "content_hash": "e4135bcb1fbbca443d24656ceac757f1837cf123aae29bcadc681481100230b9",
      "declared_ref": "n/a",
      "dir": "modules/greeting",
      "ref_type": "n/a",
      "resolved_commit": "n/a",
      "resolved_version": "n/a",
      "source": "./modules/greeting",
      "source_type": "local"
    },
    "registry_range_pin": {
      "content_hash": "n/a",
      "declared_ref": "n/a",
      "dir": ".terraform/modules/registry_range_pin",
      "ref_type": "n/a",
      "resolved_commit": "n/a",
      "resolved_version": "0.25.0",
      "source": "registry.opentofu.org/cloudposse/label/null",
      "source_type": "registry"
    }
  },
  "providers": {
    "registry.opentofu.org/hashicorp/local": {
      "constraints": "n/a",
      "installed_binary_version": "2.9.0",
      "version": "2.9.0"
    },
    "registry.opentofu.org/hashicorp/null": {
      "constraints": "~> 3.2",
      "installed_binary_version": "3.3.1",
      "version": "3.3.1"
    },
    "registry.opentofu.org/hashicorp/random": {
      "constraints": "3.9.0",
      "installed_binary_version": "3.9.0",
      "version": "3.9.0"
    }
  },
  "root_config": {
    "files": {
      "main.tf": "c93feab59728536988cc658bfd412a6291de6647df10006508a58f69b690fa22"
    },
    "fingerprint": "98b03f4f3b18d4f5b5fd86ff5e5ae26b9ef0d2caabbdfb875ca1476db40e1857",
    "git_branch": "feat/opentofu-module-version-manifest",
    "git_commit": "cf1127bab9e67d80cf5836af6952597242b8be1d",
    "git_dirty": "unknown"
  },
  "schema": 1
}
```
<!-- END\_EXAMPLE -->

## Guarantees and limits

**Self-contained.** `.terraform.lock.hcl` and `.terraform/` are read only *during* the
apply. Afterwards you can delete them entirely and the record stays complete: every
value is a resolved literal.

**Survives re-initialization.** The record lives in state, so `tofu init -upgrade` can
no longer overwrite the evidence of what was applied. Until you apply again, the
manifest reports the versions the deployed infrastructure was actually built with.

**Advisory, not attestable.** It is produced by the same operator, on the same machine,
with write access to state. It detects accidental drift; it proves nothing against
intent. Do not present it to an auditor as tamper-proof evidence.

**Written at plan time of the apply.** `terraform_data` has no dependencies, so it can
be written even if the apply later fails partway — the record may then describe an
apply that only partly happened. The state `serial` bounds this.

**No history.** Each apply overwrites the previous record.

**`git_dirty` is always `"unknown"`.** Cleanliness cannot be derived from git's plumbing
files without running `git status`. Use `root_config.fingerprint` instead: it hashes the
`.tf` bytes that were actually applied, so an independent system can compare them
against the tree at `git_commit` itself.

**Root repo detection walks up to 5 directories** from `path.root` looking for
`.git/HEAD`. A `.git` *file* (worktrees, submodules) yields `"unknown"` rather than a
wrong answer.

**Git SHA reading depends on go-getter's on-disk layout,** which is not a supported
interface. OpenTofu leaves a real git clone in `.terraform/modules/<key>/` with a
detached `HEAD` containing the raw SHA; this module falls back to loose refs and then
`packed-refs`, and degrades to `"unknown"` rather than failing if none match.

## Useful to know

Plain `tofu init` does **not** re-fetch a module tracking a git branch — it stays at the
already-cloned commit. Only `tofu init -upgrade` moves it. So a branch-sourced module is
more stable across ordinary runs than it looks, but it does move silently on upgrade,
which is exactly what `resolved_commit` captures.

## Development

[`examples/complete`](examples/complete) exercises every module source shape plus
three provider constraint styles:

```sh
cd examples/complete && tofu init && tofu apply
```

The committed example artifacts and the Example section above are generated by:

```sh
./scripts/generate-example.sh
```

CI runs the same script on every pull request and commits the result, so the
example cannot drift from the code.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [terraform_data.manifest](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

No inputs.

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_manifest"></a> [manifest](#output\_manifest) | The version manifest as an object, for use elsewhere in the configuration. |
| <a name="output_manifest_json"></a> [manifest\_json](#output\_manifest\_json) | The version manifest as a JSON string, identical to what is stored in state. |
<!-- END_TF_DOCS -->
