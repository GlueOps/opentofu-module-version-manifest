# Root configuration identity.
#
# A content fingerprint of the .tf files actually on disk at apply time. This is
# what answers "was the tree dirty?" honestly: git cannot be asked whether the
# working tree was clean without running `git status`, but the bytes that were
# applied can be hashed directly and compared against any ref afterwards.

locals {
  root_files = sort(concat(
    tolist(try(fileset(path.root, "*.tf"), [])),
    tolist(try(fileset(path.root, "*.tf.json"), [])),
  ))

  root_file_hashes = { for f in local.root_files : f => filesha256("${path.root}/${f}") }

  root_fingerprint = sha256(join("\n", [
    for f in local.root_files : "${f}:${local.root_file_hashes[f]}"
  ]))

  # --- root repository commit ------------------------------------------------
  # Read from git plumbing rather than by shelling out. The config often sits in
  # a subdirectory of the repo, so walk up a few levels looking for .git/HEAD.
  # A .git *file* (worktrees, submodules) has no HEAD beside it and yields
  # "unknown" rather than a wrong answer.

  root_git_candidates = [
    "${path.root}/.git",
    "${path.root}/../.git",
    "${path.root}/../../.git",
    "${path.root}/../../../.git",
    "${path.root}/../../../../.git",
    "${path.root}/../../../../../.git",
  ]

  root_git_dir = try([for d in local.root_git_candidates : d if fileexists("${d}/HEAD")][0], "")

  root_head_raw = local.root_git_dir != "" ? trimspace(file("${local.root_git_dir}/HEAD")) : ""
  root_head_sha = can(regex("^[0-9a-f]{40}$", local.root_head_raw)) ? local.root_head_raw : ""
  root_symref   = try(regex("^ref:\\s*(\\S+)$", local.root_head_raw)[0], "")

  root_loose_ref = (
    local.root_symref != "" && local.root_git_dir != "" && fileexists("${local.root_git_dir}/${local.root_symref}")
    ? trimspace(file("${local.root_git_dir}/${local.root_symref}"))
    : ""
  )

  root_packed_raw = (
    local.root_git_dir != "" && fileexists("${local.root_git_dir}/packed-refs")
    ? file("${local.root_git_dir}/packed-refs")
    : ""
  )

  root_packed_lines = [
    for line in split("\n", local.root_packed_raw) : split(" ", trimspace(line))
    if length(split(" ", trimspace(line))) == 2 && !startswith(trimspace(line), "#")
  ]

  root_packed_ref = (
    local.root_symref == "" ? "" :
    try([for l in local.root_packed_lines : l[0] if l[1] == local.root_symref][0], "")
  )

  root_git_commit = coalesce(
    local.root_head_sha,
    local.root_loose_ref,
    local.root_packed_ref,
    "unknown",
  )

  root_git_branch = local.root_symref != "" ? replace(local.root_symref, "refs/heads/", "") : "unknown"
}
