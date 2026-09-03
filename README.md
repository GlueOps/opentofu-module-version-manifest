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

<!-- x-release-please-start-version -->
```hcl
module "version_manifest" {
  source = "git::https://github.com/GlueOps/opentofu-module-version-manifest.git?ref=v0.0.2"
}
```
<!-- x-release-please-end -->

Then `tofu apply` as normal. Every module and provider in the configuration is
discovered automatically.

## Reading the record

The record is a JSON string stored in `terraform_data.manifest`.

**Select on the payload, not on the module call name.** The name of the block is the
consuming configuration's choice, and it may sit inside a wrapper module or use
`for_each`. A selector that hard-codes a name returns nothing — and `jq` exits 0 — so
a whole deployment silently reports as having no data. Match on `producer` instead,
and treat a zero-row result as an error:

```sh
jq '[ .resources[]
      | select(.mode=="managed" and .type=="terraform_data")
      | . as $r | .instances[]
      | (.attributes.input.value | fromjson) as $m
      | select($m.producer? == "GlueOps/opentofu-module-version-manifest")
      | { address: ($r.module // "root"), manifest: $m } ]' terraform.tfstate
```

Note `.attributes.input.value`: `input` is typed `any`, so state stores it as
`{"type":…,"value":…}` — the payload is double-encoded JSON.

`tofu show -json` also works and returns `.values.input` already unwrapped, but it
requires an initialised working directory (`.terraform/` present) and so cannot read
a state file on its own:

```sh
tofu show -json | jq '[ .. | objects
                        | select(.type? == "terraform_data")
                        | .values.input? // empty | fromjson
                        | select(.producer? == "GlueOps/opentofu-module-version-manifest") ]'
```

Recursive descent (`..`) rather than `.values.root_module.child_modules[]`, because
that path is one level deep and misses a nested module call.

## Output

```json
{
  "schema":    { "major": 1, "minor": 0 },
  "producer":  "GlueOps/opentofu-module-version-manifest",
  "workspace": "default",
  "root_config": {
    "files":       { "main.tf": "<sha256>" },
    "fingerprint": "<sha256 over the sorted per-file hashes>",
    "git_commit":  "<40-hex sha>",
    "git_branch":  "main",
    "git_dirty":   "unknown"
  },
  "providers": {
    "registry.opentofu.org/hashicorp/random": {
      "version":                   "3.9.0",
      "constraints":               "~> 3.6",
      "installed_binary_versions": ["3.9.0"]
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
      "subdir":           "n/a",
      "content_hash":     "<sha256>",
      "dir":              ".terraform/modules/from_git_branch"
    }
  }
}
```

`version` is what the lock file selected; `installed_binary_versions` lists the
versions whose binaries are actually on disk under `.terraform/providers/`. It is
**always a list**, normally of one element — a stale version directory can survive
`init -upgrade`, and emitting that as a joined string would break a consumer casting
the field to a version type.

### Schema compatibility

`schema.major` increments only on a breaking change; `schema.minor` on an additive
one. Within a given `major`, this module guarantees:

- fields are never removed, renamed, or retyped, and the meaning of a sentinel value
  never changes;
- fields **may** be added, and the value sets of `source_type` and `ref_type` **may**
  grow.

So a consumer should pin on `schema.major`, ignore fields it does not recognise, and
treat an unrecognised `source_type` or `ref_type` as opaque rather than assuming it is
one of the values below.

### Deployment identity and time

`workspace` is the only deployment identifier available to configuration; without it
two workspaces of one root module produce byte-identical records.

There is **no timestamp**, and no way to add one honestly. `plantimestamp()` changes
on every plan, so putting it in the payload would make the resource show a diff on
every `tofu plan` — and `terraform_data.input` updates in place regardless of
`triggers_replace`, so it cannot be gated to recompute only on change. A state file
carries no apply time either.

For ordering **within one configuration**, use `lineage` + `serial` from the top level
of the same state file. **Cross-configuration time ordering is not possible from state
alone** — there is no field that would support it and none is coming. A consumer that
needs it must record ingestion time out of band, from whatever the backend provides
(file mtime, or an object store's `LastModified`/version id). This is stated plainly so
that nobody designs a table around a timestamp column that will never be populated.

### `n/a` vs `unknown`

Strictly distinguished, never silently omitted:

- **`n/a`** — not applicable to this source type (a registry module has no commit)
- **`unknown`** — applicable, but could not be resolved

A module whose source could not be classified (`source_type: "other"`) reports
**`unknown`** for every derived field, never `n/a`: if we do not know what kind of
source it is, we cannot claim a field is inapplicable to it. This matters for coverage
metrics — counting unclassified sources as legitimately versionless hides blind spots
exactly where they are most likely.

### Value sets

Closed for a given `schema.major`, but they may grow — treat unrecognised values as
opaque rather than erroring:

- `source_type`: `registry`, `git`, `local`, `other`
- `ref_type`: `tag`, `branch`, `commit`, `default_branch`, `n/a`, `unknown`

### `subdir`

The `//path` portion of a git source, or `n/a`. Kept as its own field rather than as a
`source_type` value: "is this git?" and "does it point at a subdirectory?" are
orthogonal, and a fifth `source_type` would silently stop matching a consumer's
existing `source_type = 'git'` filter — an under-count with no error.

### Coverage by module source type

| Source type | `resolved_version` | `resolved_commit` | `content_hash` |
|---|---|---|---|
| Registry | ✅ | ✅ *when served as a clone* | ✅ |
| Git tag (`?ref=v1.2.3`) | `n/a` | ✅ | ✅ |
| Git branch (`?ref=main`) | `n/a` | ✅ | ✅ |
| Git commit (`?ref=<sha>`) | `n/a` | ✅ | ✅ |
| Git, no ref (default branch) | `n/a` | ✅ | ✅ |
| Git subdirectory (`//sub`) | `n/a` | ✅ *usually* — see below | ✅ |
| Local path (incl. absolute) | `n/a` | `n/a` | ✅ |
| Unclassified (`other`) | `unknown` | `unknown` | `unknown` |

**Registry modules may carry a commit too.** The registry serves some modules as a real
git clone and others as an archive. Where a clone is present its commit is recorded
alongside the version; where it is not, `resolved_commit` is `n/a`, because a registry
module's authoritative identity is its version and an archive genuinely has no commit
on disk. Both forms appear in the example below.

**The one case that can genuinely fail.** For `git::<url>//subdir`, the clone lives at
the checkout root while `modules.json` points `Dir` at the subdirectory; both are
searched, so the SHA resolves normally. But go-getter fetches a given repo+ref **once**
and copies it — without `.git` — for any later caller of the same package. A `//subdir`
module can therefore end up with no git metadata at all. Where a sibling module uses the
same repo and ref, its SHA is authoritative for both and is used. Where none does,
`resolved_commit` is `"unknown"` and `content_hash` is the only identity available.

`ref_type` reports whether the declared ref was a `tag`, `branch`, `commit`, or the
remote's `default_branch` — the source string alone cannot distinguish these, so it is
derived from the clone's refs, read both loose (`.git/refs/…`) and packed. Reading only
`packed-refs` would make the answer depend on whether the repository happened to have
been garbage-collected. The commit-shaped heuristic is applied last, so a branch or tag
legitimately named like a short hex string is still classified correctly.

### `content_hash`, normatively

Computed for **every** module with a readable directory, not only local ones — it is
the only identity a deduplicated subdirectory module has. The algorithm is specified
here so that a consumer can recompute it independently against an upstream checkout and
map a hash back to a tag:

1. Collect files under the module directory matching `**/*.tf`, `**/*.tf.json`,
   `**/*.tftpl`, `**/*.tpl`; discard any path beginning `.terraform/`.
2. Sort the resulting relative paths (lexicographic, as `sort()` orders them).
3. For each, form `"<relative path>:<sha256 of file contents, lowercase hex>"`.
4. Join those strings with a single `\n`, with no trailing newline.
5. `content_hash` is the lowercase hex sha256 of that joined string.

A module with no matching files reports `n/a` (or `unknown` if unclassified).

Only Terraform sources are hashed because a module's identity is its Terraform source:
a README beside it is not part of the module, and hashing every file would make the
value unstable whenever a tool writes output into the directory, since that output
feeds back into the next hash.

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

# Subdirectory of a git repo, at a ref used by no other module here: the clone
# keeps its .git, so the SHA comes from its own checkout.
module "git_subdir" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git//exports?ref=0.23.0"
}

# Subdirectory at the SAME repo and ref as git_tag_bare. go-getter fetches a
# package once and copies it without .git for later callers, so this module has
# no git metadata of its own -- its SHA is borrowed from the sibling that kept
# the clone. Both must report the same commit.
module "git_subdir_shared" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git//exports?ref=0.25.0"
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
| `git_branch_main` | `git` | `main` | `branch` | `n/a` | `38364d79c108…` | `f6174313b352…` |
| `git_branch_master` | `git` | `master` | `branch` | `n/a` | `f86cbe2f1041…` | `85cd1dfae1a5…` |
| `git_commit_sha` | `git` | `488ab91e34a24a86957e397d9f7262ec5925586a` | `commit` | `n/a` | `488ab91e34a2…` | `b8711b66a773…` |
| `git_default_branch` | `git` | `n/a` | `default_branch` | `n/a` | `38364d79c108…` | `f6174313b352…` |
| `git_shorthand` | `git` | `0.24.1` | `tag` | `n/a` | `dc699992922b…` | `0f221c74eaee…` |
| `git_subdir` | `git` | `0.23.0` | `tag` | `n/a` | `6a7c42ef2105…` | `c391bb6c964b…` |
| `git_subdir.this` | `registry` | `n/a` | `n/a` | `0.23.0` | `6a7c42ef2105…` | `3f9e78a1b6da…` |
| `git_subdir_shared` | `git` | `0.25.0` | `tag` | `n/a` | `488ab91e34a2…` | `007ac3baf7c6…` |
| `git_subdir_shared.this` | `registry` | `n/a` | `n/a` | `0.25.0` | `488ab91e34a2…` | `b8711b66a773…` |
| `git_tag_bare` | `git` | `0.25.0` | `tag` | `n/a` | `488ab91e34a2…` | `b8711b66a773…` |
| `git_tag_prerelease` | `git` | `0.25.0-rc.1` | `tag` | `n/a` | `503f50c2fbf6…` | `dbd29b4fa124…` |
| `git_tag_v_prefixed` | `git` | `v1.0.0` | `tag` | `n/a` | `52ca061aaea2…` | `85cd1dfae1a5…` |
| `local_path` | `local` | `n/a` | `n/a` | `n/a` | `n/a` | `e4135bcb1fbb…` |
| `local_path.nested` | `local` | `n/a` | `n/a` | `n/a` | `n/a` | `cc12eb0ab8e2…` |
| `registry_exact_pin` | `registry` | `n/a` | `n/a` | `1.0.0` | `52ca061aaea2…` | `85cd1dfae1a5…` |
| `registry_range_pin` | `registry` | `n/a` | `n/a` | `0.25.0` | `n/a` | `b8711b66a773…` |
| `registry_unpinned` | `registry` | `n/a` | `n/a` | `0.25.0` | `n/a` | `b8711b66a773…` |
| `version_manifest` | `local` | `n/a` | `n/a` | `n/a` | `n/a` | `18963fd929e1…` |

Note what the three registry entries show: `registry_range_pin` was declared as
`~> 0.25` and `registry_unpinned` declared no version at all, yet both record the
exact version that ran. And `git_default_branch` — which names no ref whatsoever —
resolves to the same commit as `git_branch_main`, because that is the repository's
default branch.

Providers are recorded with both the version the lock file selected and the version
whose binary was actually on disk:

| Provider | `constraints` | `version` | `installed_binary_versions` |
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
      "content_hash": "f6174313b352c4ecc4c29d17d882d51d9c153452befc3abfcc5f604711434cdb",
      "declared_ref": "main",
      "dir": ".terraform/modules/git_branch_main",
      "ref_type": "branch",
      "resolved_commit": "38364d79c1082de13373666252e1276975919543",
      "resolved_version": "n/a",
      "source": "git::https://github.com/cloudposse/terraform-null-label.git?ref=main",
      "source_type": "git",
      "subdir": "n/a"
    },
    "git_tag_bare": {
      "content_hash": "b8711b66a773aa21e211daa0005d3165f44818e13028fbe66f173be5222dc9dc",
      "declared_ref": "0.25.0",
      "dir": ".terraform/modules/git_tag_bare",
      "ref_type": "tag",
      "resolved_commit": "488ab91e34a24a86957e397d9f7262ec5925586a",
      "resolved_version": "n/a",
      "source": "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0",
      "source_type": "git",
      "subdir": "n/a"
    },
    "local_path": {
      "content_hash": "e4135bcb1fbbca443d24656ceac757f1837cf123aae29bcadc681481100230b9",
      "declared_ref": "n/a",
      "dir": "modules/greeting",
      "ref_type": "n/a",
      "resolved_commit": "n/a",
      "resolved_version": "n/a",
      "source": "./modules/greeting",
      "source_type": "local",
      "subdir": "n/a"
    },
    "registry_range_pin": {
      "content_hash": "b8711b66a773aa21e211daa0005d3165f44818e13028fbe66f173be5222dc9dc",
      "declared_ref": "n/a",
      "dir": ".terraform/modules/registry_range_pin",
      "ref_type": "n/a",
      "resolved_commit": "n/a",
      "resolved_version": "0.25.0",
      "source": "registry.opentofu.org/cloudposse/label/null",
      "source_type": "registry",
      "subdir": "n/a"
    }
  },
  "providers": {
    "registry.opentofu.org/hashicorp/local": {
      "constraints": "n/a",
      "installed_binary_versions": [
        "2.9.0"
      ],
      "version": "2.9.0"
    },
    "registry.opentofu.org/hashicorp/null": {
      "constraints": "~> 3.2",
      "installed_binary_versions": [
        "3.3.1"
      ],
      "version": "3.3.1"
    },
    "registry.opentofu.org/hashicorp/random": {
      "constraints": "3.9.0",
      "installed_binary_versions": [
        "3.9.0"
      ],
      "version": "3.9.0"
    }
  },
  "root_config": {
    "files": {
      "main.tf": "c34c45b0c32d66dda8c8da89d9defe82a52719fd421c90af463f26080224a1ed"
    },
    "fingerprint": "e5540710cb51066dcc80a7e60c96168027369e12933b817dfe141140d8fff871",
    "git_branch": "ci/release-please-updates-readme-version",
    "git_commit": "540dc036c4438a4bbf4c93ee415d4bd150ba3ee6",
    "git_dirty": "unknown"
  },
  "schema": {
    "major": 1,
    "minor": 0
  }
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
interface. OpenTofu leaves a real git clone under `.terraform/modules/`. When the source
names a `?ref=` — branch, tag or commit — that clone's `HEAD` is detached and holds the
raw SHA outright. When it names no ref, `HEAD` is instead a symref to the default
branch, so the loose-ref read is a normal path, not a fallback; `packed-refs` is then
read if the ref is packed, and the value degrades to `"unknown"` rather than failing if
none match.

## Useful to know

`resolved_commit` is always a *commit* SHA, including for annotated tags. An
annotated tag is its own git object, so `git ls-remote refs/tags/v1.0.0` reports the
tag object rather than the commit — you need `refs/tags/v1.0.0^{}` for that. Because
this module reads the checked-out `HEAD`, it records the peeled commit directly, which
is the value you actually want when comparing against a repository's history.

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

CI runs the same script on every pull request and **fails if the committed artifacts
are stale**, so the example cannot drift from the code. It does not commit for you:
regenerating requires `tofu apply`, which downloads and executes third-party provider
and module code, and that must not run in a job holding a token that can push.

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.manifest](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

No inputs.

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_manifest"></a> [manifest](#output\_manifest) | The version manifest as an object, for use elsewhere in the configuration. |
| <a name="output_manifest_json"></a> [manifest\_json](#output\_manifest\_json) | The version manifest as a JSON string, identical to what is stored in state. |
<!-- END_TF_DOCS -->
