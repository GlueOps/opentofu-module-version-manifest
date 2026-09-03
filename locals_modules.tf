# Module facts, resolved at apply time from .terraform/modules/.
#
# modules.json records Key / Source / Version / Dir. Source is stored verbatim as
# written in configuration (so `?ref=main` stays the literal string "main") and
# Version is populated for registry modules only -- it is nil for git and local
# sources. Nothing OpenTofu writes records a resolved commit, so the SHA is read
# out of the git checkout that go-getter leaves under .terraform/modules/.
#
# Every fileexists() call here is wrapped in try(). fileexists throws -- it does
# not return false -- when a path component is a regular file rather than a
# directory, which happens for git worktree/submodule `.git` files and for repos
# using git's reftable backend (where .git/refs is a file). Unguarded, that
# aborts the entire consuming configuration.

locals {
  modules_json_path = "${path.root}/.terraform/modules/modules.json"

  modules_raw = try(fileexists(local.modules_json_path), false) ? try(
    jsondecode(file(local.modules_json_path)).Modules, []
  ) : []

  # The root module appears as a record with an empty Key; it is not a dependency.
  mods = {
    for m in local.modules_raw : m.Key => {
      source  = try(m.Source, "")
      dir     = try(m.Dir, "")
      version = try(m.Version, "")
    } if try(m.Key, "") != ""
  }

  # Classification order matters: local and git sources are checked before the
  # registry patterns, which are the loosest. OpenTofu rewrites an absolute local
  # path to a file:// URL, so that form is a local module too.
  source_type = {
    for k, m in local.mods : k => (
      startswith(m.source, "./") || startswith(m.source, "../") || startswith(m.source, "/") || startswith(m.source, "file://") ? "local" :
      startswith(m.source, "git::") || startswith(m.source, "git@") || startswith(m.source, "github.com/") || startswith(m.source, "bitbucket.org/") || strcontains(m.source, ".git") ? "git" :
      m.version != "" ? "registry" :
      can(regex("^[0-9A-Za-z._-]+/[0-9A-Za-z._-]+/[0-9A-Za-z._-]+$", m.source)) ? "registry" :
      can(regex("^[0-9A-Za-z._-]+\\.[0-9A-Za-z._-]+/[0-9A-Za-z._-]+/[0-9A-Za-z._-]+/[0-9A-Za-z._-]+$", m.source)) ? "registry" :
      "other"
    )
  }

  # Sentinel for a field that does not apply to this source type, vs one that
  # applies but could not be resolved. An unclassified source is "unknown"
  # throughout: we cannot claim a field is inapplicable when we do not know what
  # kind of source it is.
  na = { for k, m in local.mods : k => local.source_type[k] == "other" ? "unknown" : "n/a" }

  # The ref as DECLARED in the source string. Absent means go-getter took the
  # remote's default branch.
  declared_ref = {
    for k, m in local.mods : k => (
      local.source_type[k] != "git" ? local.na[k] :
      try(regex("[?&]ref=([^&]+)", m.source)[0], "n/a")
    )
  }

  # --- git checkout location --------------------------------------------------
  # For `git::<url>//subdir`, modules.json Dir points at the SUBDIRECTORY while
  # the clone -- and therefore .git -- sits at the checkout root
  # .terraform/modules/<Key>. Both are tried.

  git_dir_candidates = {
    for k, m in local.mods : k => distinct([
      "${path.root}/${m.dir}/.git",
      "${path.root}/.terraform/modules/${k}/.git",
    ])
  }

  git_dir = {
    for k, cands in local.git_dir_candidates : k => try([
      for c in cands : c if try(fileexists("${c}/HEAD"), false)
    ][0], "")
  }

  # --- git commit resolution -------------------------------------------------
  # When the source names a ref, go-getter leaves a detached HEAD holding the raw
  # SHA. When it names no ref, HEAD is a symref to the default branch, so the
  # loose-ref read below is a normal path rather than a fallback.

  git_head_raw = {
    for k, d in local.git_dir : k => (
      d != "" ? trimspace(file("${d}/HEAD")) : ""
    )
  }

  git_head_sha = {
    for k, h in local.git_head_raw : k => can(regex("^[0-9a-f]{40}$", h)) ? h : ""
  }

  git_symref = {
    for k, h in local.git_head_raw : k => try(regex("^ref:\\s*(\\S+)$", h)[0], "")
  }

  git_loose_ref = {
    for k, r in local.git_symref : k => (
      r != "" && local.git_dir[k] != "" && try(fileexists("${local.git_dir[k]}/${r}"), false)
      ? trimspace(file("${local.git_dir[k]}/${r}"))
      : ""
    )
  }

  # Packed refs are matched line-by-line rather than by regex, so ref names
  # containing regex metacharacters are handled correctly.
  git_packed_raw = {
    for k, d in local.git_dir : k => (
      d != "" && try(fileexists("${d}/packed-refs"), false)
      ? file("${d}/packed-refs") : ""
    )
  }

  git_packed_lines = {
    for k, raw in local.git_packed_raw : k => [
      for line in split("\n", raw) : split(" ", trimspace(line))
      if length(split(" ", trimspace(line))) == 2 && !startswith(trimspace(line), "#")
    ]
  }

  git_packed_names = { for k, lines in local.git_packed_lines : k => [for l in lines : l[1]] }

  git_packed_ref = {
    for k, r in local.git_symref : k => (
      r == "" ? "" : try([for l in local.git_packed_lines[k] : l[0] if l[1] == r][0], "")
    )
  }

  # Not coalesce(): it errors when every argument is empty, which is exactly the
  # case here for a module whose git metadata could not be read at all.
  git_sha_direct = {
    for k, m in local.mods : k => try([
      for s in [local.git_head_sha[k], local.git_loose_ref[k], local.git_packed_ref[k]] : s if s != ""
    ][0], "")
  }

  # --- borrowing a SHA across a shared package -------------------------------
  # go-getter fetches a given repo+ref once and COPIES it, without .git, for any
  # further caller of the same package. A `//subdir` caller can therefore end up
  # with no git metadata at all -- but a sibling that kept its clone is by
  # definition at the same commit, so its SHA is authoritative for both.

  git_src_plain  = { for k, m in local.mods : k => split("?", replace(m.source, "git::", ""))[0] }
  git_src_scheme = { for k, s in local.git_src_plain : k => split("://", s) }

  # The `//subdir` portion, kept as its own field rather than folded into
  # source_type: "is this git?" and "does it point at a subdirectory?" are
  # orthogonal facts, and a fifth source_type value would silently stop matching
  # every consumer's existing `source_type = 'git'` filter.
  subdir = {
    for k, m in local.mods : k => (
      length(local.git_src_scheme[k]) > 1
      ? try(split("//", local.git_src_scheme[k][1])[1], "n/a")
      : try(split("//", local.git_src_scheme[k][0])[1], "n/a")
    )
  }

  git_package_key = {
    for k, m in local.mods : k => (
      local.source_type[k] != "git" ? "" : join("@", [
        length(local.git_src_scheme[k]) > 1
        ? "${local.git_src_scheme[k][0]}://${split("//", local.git_src_scheme[k][1])[0]}"
        : split("//", local.git_src_scheme[k][0])[0],
        local.declared_ref[k],
      ])
    )
  }

  git_shas_by_package = {
    for pk, shas in { for k, pk in local.git_package_key : pk => local.git_sha_direct[k]... if pk != "" } :
    pk => try([for s in shas : s if s != ""][0], "")
  }

  git_sha_resolved = {
    for k, m in local.mods : k => try([
      for s in [local.git_sha_direct[k], try(local.git_shas_by_package[local.git_package_key[k]], "")] : s if s != ""
    ][0], "")
  }

  # A registry module carries a commit only when the registry served it as a git
  # clone rather than an archive; the version is its authoritative identity
  # either way, so an archive-served module reports "n/a" rather than a failure.
  resolved_commit = {
    for k, m in local.mods : k => (
      local.source_type[k] == "local" ? "n/a" :
      local.source_type[k] == "git" ? (local.git_sha_resolved[k] != "" ? local.git_sha_resolved[k] : "unknown") :
      local.git_sha_resolved[k] != "" ? local.git_sha_resolved[k] : local.na[k]
    )
  }

  # Whether the declared ref was a tag, a branch or a raw commit. Refs are looked
  # up both loose (.git/refs/...) and packed; checking only packed-refs makes the
  # answer depend on whether the repo happens to have been gc'd. The commit
  # heuristic is tried LAST, so a branch or tag legitimately named like a short
  # hex string is still reported correctly.
  ref_loose_tag = {
    for k, m in local.mods : k => local.git_dir[k] != "" && local.declared_ref[k] != "n/a" &&
    try(fileexists("${local.git_dir[k]}/refs/tags/${local.declared_ref[k]}"), false)
  }

  ref_loose_branch = {
    for k, m in local.mods : k => local.git_dir[k] != "" && local.declared_ref[k] != "n/a" && (
      try(fileexists("${local.git_dir[k]}/refs/heads/${local.declared_ref[k]}"), false) ||
      try(fileexists("${local.git_dir[k]}/refs/remotes/origin/${local.declared_ref[k]}"), false)
    )
  }

  ref_type_direct = {
    for k, m in local.mods : k => (
      local.source_type[k] != "git" ? local.na[k] :
      local.declared_ref[k] == "n/a" ? "default_branch" :
      local.ref_loose_tag[k] || contains(local.git_packed_names[k], "refs/tags/${local.declared_ref[k]}") ? "tag" :
      local.ref_loose_branch[k] || contains(local.git_packed_names[k], "refs/remotes/origin/${local.declared_ref[k]}") ? "branch" :
      can(regex("^[0-9a-f]{7,40}$", local.declared_ref[k])) ? "commit" :
      "unknown"
    )
  }

  # Same package, same ref -- so a sibling that kept its clone can classify the
  # ref for a caller whose checkout was deduplicated away, exactly as for the SHA.
  ref_types_by_package = {
    for pk, ts in { for k, pk in local.git_package_key : pk => local.ref_type_direct[k]... if pk != "" } :
    pk => try([for x in ts : x if x != "unknown"][0], "unknown")
  }

  ref_type = {
    for k, m in local.mods : k => (
      local.ref_type_direct[k] != "unknown" ? local.ref_type_direct[k] :
      try(local.ref_types_by_package[local.git_package_key[k]], "unknown")
    )
  }

  # --- content hashing -------------------------------------------------------
  # Applied to every module with a readable directory, not just local ones: it is
  # the only identity a `//subdir` git module has when its clone was deduplicated
  # away, and it lets a moved branch be detected even where a SHA is available.
  #
  # Only Terraform-relevant files are hashed. A module's identity is its
  # Terraform source: a README beside it is not part of the module, and hashing
  # everything makes the value unstable whenever a tool writes output into the
  # directory, because that output feeds back into the next hash.
  content_patterns = ["**/*.tf", "**/*.tf.json", "**/*.tftpl", "**/*.tpl"]

  content_files = {
    for k, m in local.mods : k => sort(distinct(flatten([
      for pattern in local.content_patterns : [
        for f in try(fileset("${path.root}/${m.dir}", pattern), []) : f
        if !startswith(f, ".terraform/")
      ]
    ])))
  }

  content_hash = {
    for k, m in local.mods : k => (
      length(local.content_files[k]) == 0 ? local.na[k] :
      sha256(join("\n", [
        for f in local.content_files[k] : "${f}:${filesha256("${path.root}/${m.dir}/${f}")}"
      ]))
    )
  }

  modules_out = {
    for k, m in local.mods : k => {
      source           = m.source
      source_type      = local.source_type[k]
      declared_ref     = local.declared_ref[k]
      ref_type         = local.ref_type[k]
      resolved_version = local.source_type[k] == "registry" ? (m.version != "" ? m.version : "unknown") : local.na[k]
      resolved_commit  = local.resolved_commit[k]
      subdir           = local.subdir[k]
      content_hash     = local.content_hash[k]
      dir              = m.dir
    }
  }
}
