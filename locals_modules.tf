# Module facts, resolved at apply time from .terraform/modules/.
#
# modules.json records Key / Source / Version / Dir. Source is stored verbatim as
# written in configuration (so `?ref=main` stays the literal string "main") and
# Version is populated for registry modules only -- it is nil for git and local
# sources. Nothing OpenTofu writes records a resolved commit, so the SHA is read
# out of the git checkout that go-getter leaves in .terraform/modules/<key>/.git.

locals {
  modules_json_path = "${path.root}/.terraform/modules/modules.json"

  modules_raw = fileexists(local.modules_json_path) ? try(
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
  # registry patterns, which are the loosest.
  source_type = {
    for k, m in local.mods : k => (
      startswith(m.source, "./") || startswith(m.source, "../") || startswith(m.source, "/") ? "local" :
      startswith(m.source, "git::") || startswith(m.source, "git@") || startswith(m.source, "github.com/") || startswith(m.source, "bitbucket.org/") || strcontains(m.source, ".git") ? "git" :
      m.version != "" ? "registry" :
      can(regex("^[0-9A-Za-z._-]+/[0-9A-Za-z._-]+/[0-9A-Za-z._-]+$", m.source)) ? "registry" :
      can(regex("^[0-9A-Za-z._-]+\\.[0-9A-Za-z._-]+/[0-9A-Za-z._-]+/[0-9A-Za-z._-]+/[0-9A-Za-z._-]+$", m.source)) ? "registry" :
      "other"
    )
  }

  # The ref as DECLARED in the source string. Absent means go-getter took the
  # remote's default branch.
  declared_ref = {
    for k, m in local.mods : k => (
      local.source_type[k] != "git" ? "n/a" :
      try(regex("[?&]ref=([^&]+)", m.source)[0], "n/a")
    )
  }

  # --- git commit resolution -------------------------------------------------
  # go-getter checks out a detached HEAD for both tag and branch refs, so
  # .git/HEAD normally holds the raw SHA outright. The symref fallbacks below
  # cover layouts where it does not.

  git_dir = { for k, m in local.mods : k => "${path.root}/${m.dir}/.git" }

  git_head_raw = {
    for k, d in local.git_dir : k => (
      local.source_type[k] == "git" && fileexists("${d}/HEAD") ? trimspace(file("${d}/HEAD")) : ""
    )
  }

  git_head_sha = {
    for k, h in local.git_head_raw : k => can(regex("^[0-9a-f]{40}$", h)) ? h : ""
  }

  # Fallback 1: HEAD is a symref, e.g. "ref: refs/heads/main".
  git_symref = {
    for k, h in local.git_head_raw : k => try(regex("^ref:\\s*(\\S+)$", h)[0], "")
  }

  git_loose_ref = {
    for k, r in local.git_symref : k => (
      r != "" && fileexists("${local.git_dir[k]}/${r}") ? trimspace(file("${local.git_dir[k]}/${r}")) : ""
    )
  }

  # Fallback 2: the ref is packed. Matched line-by-line rather than by regex so
  # that ref names containing regex metacharacters are handled correctly.
  git_packed_raw = {
    for k, d in local.git_dir : k => (
      local.source_type[k] == "git" && fileexists("${d}/packed-refs") ? file("${d}/packed-refs") : ""
    )
  }

  git_packed_lines = {
    for k, raw in local.git_packed_raw : k => [
      for line in split("\n", raw) : split(" ", trimspace(line))
      if length(split(" ", trimspace(line))) == 2 && !startswith(trimspace(line), "#")
    ]
  }

  git_packed_names = {
    for k, lines in local.git_packed_lines : k => [for l in lines : l[1]]
  }

  git_packed_ref = {
    for k, r in local.git_symref : k => (
      r == "" ? "" : try([for l in local.git_packed_lines[k] : l[0] if l[1] == r][0], "")
    )
  }

  resolved_commit = {
    for k, m in local.mods : k => (
      local.source_type[k] != "git" ? "n/a" : coalesce(
        local.git_head_sha[k],
        local.git_loose_ref[k],
        local.git_packed_ref[k],
        "unknown",
      )
    )
  }

  # Whether the declared ref was a tag, a branch or a raw commit. Derived from
  # the clone's packed refs -- the declared string alone cannot distinguish them.
  ref_type = {
    for k, m in local.mods : k => (
      local.source_type[k] != "git" ? "n/a" :
      local.declared_ref[k] == "n/a" ? "default_branch" :
      can(regex("^[0-9a-f]{7,40}$", local.declared_ref[k])) ? "commit" :
      contains(local.git_packed_names[k], "refs/tags/${local.declared_ref[k]}") ? "tag" :
      contains(local.git_packed_names[k], "refs/remotes/origin/${local.declared_ref[k]}") ? "branch" :
      "unknown"
    )
  }

  # --- local module content hashing ------------------------------------------
  # Local paths carry no version of any kind, so content is the only identity
  # available.
  #
  # Only Terraform-relevant files are hashed, not every file in the directory. A
  # module's identity is its Terraform source: a README edit or a generated file
  # sitting in the same directory is not a change to the module. Hashing
  # everything also makes the hash unstable whenever a tool writes output into
  # the module directory, because that output feeds back into the next hash.
  local_module_patterns = ["**/*.tf", "**/*.tf.json", "**/*.tftpl", "**/*.tpl"]

  local_files = {
    for k, m in local.mods : k => sort(distinct(flatten([
      for pattern in local.local_module_patterns : [
        for f in try(fileset("${path.root}/${m.dir}", pattern), []) : f
        if !startswith(f, ".terraform/")
      ]
    ]))) if local.source_type[k] == "local"
  }

  content_hash = {
    for k, m in local.mods : k => (
      local.source_type[k] != "local" ? "n/a" :
      sha256(join("\n", [
        for f in local.local_files[k] : "${f}:${filesha256("${path.root}/${m.dir}/${f}")}"
      ]))
    )
  }

  modules_out = {
    for k, m in local.mods : k => {
      source           = m.source
      source_type      = local.source_type[k]
      declared_ref     = local.declared_ref[k]
      ref_type         = local.ref_type[k]
      resolved_version = local.source_type[k] == "registry" ? (m.version != "" ? m.version : "unknown") : "n/a"
      resolved_commit  = local.resolved_commit[k]
      content_hash     = local.content_hash[k]
      dir              = m.dir
    }
  }
}
