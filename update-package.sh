#!/usr/bin/env bash
#
# update-package.sh — check a single melange package YAML for a newer upstream
# GitHub version and, on confirmation, apply the version bump plus derived edits
# (sha256 for fetch packages, commit pin for git-checkout packages).
#
# Usage: update-package.sh <path/to/package.yaml>
# Iterate over every package via `make update`.
#
# Self-contained: depends on gh (authenticated), yq (mikefarah/Go), jq, curl,
# and a sha256 tool (shasum on macOS, sha256sum otherwise). macOS-portable;
# avoids GNU-only flags.

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers (no-op when stdout is not a TTY)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BLUE=$'\033[34m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
else
  C_RESET=''
  C_BLUE=''
  C_YELLOW=''
  C_GREEN=''
fi

info() { printf '%s%s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }

# ---------------------------------------------------------------------------
# sha256 tool detection (done once)
# ---------------------------------------------------------------------------
SHA256_TOOL=""

detect_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    SHA256_TOOL="shasum"
  elif command -v sha256sum >/dev/null 2>&1; then
    SHA256_TOOL="sha256sum"
  fi
}

# SHA256 <file> — print only the hex digest of the given file.
SHA256() {
  case "$SHA256_TOOL" in
    shasum)    shasum -a 256 "$1" | awk '{print $1}' ;;
    sha256sum) sha256sum "$1"     | awk '{print $1}' ;;
    *) warn "no sha256 tool available"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency checks (fail fast)
# ---------------------------------------------------------------------------
require_deps() {
  local missing=0 dep
  for dep in gh yq jq curl; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      warn "missing required dependency: $dep"
      missing=1
    fi
  done

  detect_sha256
  if [ -z "$SHA256_TOOL" ]; then
    warn "missing required dependency: shasum or sha256sum"
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    warn "install the missing dependencies and retry"
    exit 1
  fi

  if ! gh auth status --active >/dev/null 2>&1; then
    warn "gh is not authenticated; run 'gh auth login' first"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

# latest_tag <identifier> <strip-prefix>
# Print the highest tag (by `sort -V`) for the given GitHub repo, with the
# strip-prefix removed. Returns non-zero (and prints nothing) on API error or
# when the repo has no tags.
latest_tag() {
  local id="$1" prefix="$2"
  local raw stripped

  if ! raw="$(gh api --paginate "repos/${id}/tags" --jq '.[].name' 2>/dev/null)"; then
    return 1
  fi
  if [ -z "$raw" ]; then
    return 1
  fi

  # Strip the configured prefix from the start of each tag (literal, anchored
  # at the start — the prefix is treated as a plain string, not a regex), then
  # choose the highest by version sort.
  if [ -n "$prefix" ]; then
    local tag
    stripped=""
    while IFS= read -r tag; do
      [ -n "$tag" ] || continue
      stripped="${stripped}${tag#"$prefix"}"$'\n'
    done <<EOF
$raw
EOF
  else
    stripped="$raw"
  fi

  local highest
  highest="$(printf '%s\n' "$stripped" | sort -V | tail -n 1)"
  if [ -z "$highest" ]; then
    return 1
  fi

  printf '%s\n' "$highest"
}

# is_newer <current> <latest> — succeed iff <latest> sorts strictly above
# <current> (i.e. latest is newer and they differ). Trailing ".0" segments are
# normalized away first so semantically-equal versions like 1.0 and 1.0.0 are
# treated as equal (no spurious update).
is_newer() {
  local current="$1" latest="$2"
  # Strip trailing zero segments (e.g. 1.0.0 -> 1, 1.2.0 -> 1.2) for comparison.
  local cur_norm="$current" lat_norm="$latest"
  while case "$cur_norm" in *.0) true ;; *) false ;; esac; do cur_norm="${cur_norm%.0}"; done
  while case "$lat_norm" in *.0) true ;; *) false ;; esac; do lat_norm="${lat_norm%.0}"; done
  [ "$cur_norm" != "$lat_norm" ] || return 1
  local top
  top="$(printf '%s\n%s\n' "$cur_norm" "$lat_norm" | sort -V | tail -n 1)"
  [ "$top" = "$lat_norm" ]
}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------

# confirm <message> — show a y/N prompt and return 0 for yes, 1 for no.
# Reads from /dev/tty so the prompt works even when invoked from the Makefile
# loop (whose shell may consume stdin). Defaults to No on empty input or anything
# other than y/Y. When /dev/tty is unavailable (non-interactive run) it warns and
# returns 1.
confirm() {
  local message="$1" ans
  if [ ! -r /dev/tty ]; then
    warn "no terminal available for confirmation; skipping"
    return 1
  fi
  if ! read -r -p "$message" ans </dev/tty; then
    warn "no terminal available for confirmation; skipping"
    return 1
  fi
  case "$ans" in
    y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Package-type detection
# ---------------------------------------------------------------------------

# package_type <file> — print the package's pipeline type:
#   git-checkout  if any pipeline step uses git-checkout
#   fetch         else if any pipeline step uses fetch
#   (nothing, returns 1) otherwise
package_type() {
  local f="$1" n
  n="$(yq '[.pipeline[] | select(.uses == "git-checkout")] | length' "$f" 2>/dev/null)"
  case "$n" in *[!0-9]* | '') n=0 ;; esac
  if [ "$n" -gt 0 ]; then
    printf 'git-checkout\n'
    return 0
  fi
  n="$(yq '[.pipeline[] | select(.uses == "fetch")] | length' "$f" 2>/dev/null)"
  case "$n" in *[!0-9]* | '') n=0 ;; esac
  if [ "$n" -gt 0 ]; then
    printf 'fetch\n'
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Atomic write scaffolding
# ---------------------------------------------------------------------------

# atomic_edit <file> <editor_fn> [args...] — run editor_fn against <file> with
# a backup safety net. The editor must mutate <file> in place and return
# non-zero on failure. On failure the backup is restored over <file> and a
# non-zero status is returned; on success the backup is removed.
atomic_edit() {
  local file="$1" editor="$2"
  shift 2
  local tmp
  tmp="$(mktemp)"
  cp "$file" "$tmp"

  if "$editor" "$file" "$@"; then
    rm -f "$tmp"
    return 0
  fi

  # Editor failed: restore the original and report failure.
  cp "$tmp" "$file"
  rm -f "$tmp"
  return 1
}

# ---------------------------------------------------------------------------
# Editors — apply the derived edits for a confirmed version bump. edit_fetch
# recomputes the per-arch expected-sha256 for each fetch step; edit_git_checkout
# resolves the new tag to its commit SHA and pins it. Both bump version/epoch
# and are run under atomic_edit so a failure rolls the file back.
# ---------------------------------------------------------------------------

# edit_fetch <file> <new_version> — bump version and reset epoch for a
# fetch-style package, then recompute the per-arch expected-sha256 for every
# fetch pipeline step by downloading the rendered URL. Returns non-zero on any
# failure (so atomic_edit rolls the file back).
edit_fetch() {
  local file="$1" new_version="$2"

  # Bump version/epoch first so the rendered URLs use the new version.
  NEW_VERSION="$new_version" yq -i '.package.version = strenv(NEW_VERSION) | .package.epoch = 0' "$file"

  # Pipeline indices of the fetch steps.
  local indices
  indices="$(yq '.pipeline | to_entries | map(select(.value.uses == "fetch")) | .[].key' "$file")"

  local tmp
  tmp="$(mktemp)"
  # The download temp file is removed explicitly on every return path below
  # (rather than via a RETURN trap, which in bash leaks up the call stack and
  # would later fire in callers that have no local `tmp`, crashing under
  # `set -u`).

  local i uri cond arch url sha
  while IFS= read -r i; do
    [ -n "$i" ] || continue

    # Only touch steps that already carry an expected-sha256 key.
    if [ "$(yq ".pipeline[$i].with.expected-sha256" "$file")" = "null" ]; then
      continue
    fi

    uri="$(yq ".pipeline[$i].with.uri" "$file")"

    # Derive the architecture token from the step's `if` guard, e.g.
    #   ${{build.arch}} == 'x86_64'  ->  x86_64
    cond="$(yq ".pipeline[$i].if // \"\"" "$file")"
    arch="$(printf '%s' "$cond" | grep -oE 'x86_64|aarch64' || true)"
    if [ -z "$arch" ]; then
      warn "edit_fetch: no arch derivable for ${file} pipeline step $i (no 'if' guard); defaulting to x86_64"
      arch="x86_64"
    fi

    # Render the URI template. The single-quoted patterns are literal melange
    # placeholders (${{...}}); they must not be expanded by the shell.
    # shellcheck disable=SC2016
    url="${uri//'${{package.version}}'/$new_version}"
    # shellcheck disable=SC2016
    url="${url//'${{build.arch}}'/$arch}"

    if ! curl -fSL --connect-timeout 30 --max-time 300 "$url" -o "$tmp"; then
      warn "edit_fetch: download failed for ${arch}: ${url}"
      rm -f "$tmp"
      return 1
    fi

    if ! sha="$(SHA256 "$tmp")"; then
      warn "edit_fetch: sha256 computation failed for ${url}"
      rm -f "$tmp"
      return 1
    fi

    SHA="$sha" yq -i ".pipeline[$i].with.expected-sha256 = strenv(SHA)" "$file"
  done <<EOF
$indices
EOF

  rm -f "$tmp"
  return 0
}

# edit_git_checkout <file> <new_version> <identifier> <tag> — bump version and
# reset epoch for a git-checkout-style package, then resolve the new tag to its
# commit SHA and pin it on the git-checkout pipeline step's expected-commit.
#   <new_version> is the stripped version stored in YAML (e.g. 1.2.3).
#   <identifier>  is the GitHub owner/repo (e.g. secdev/scapy).
#   <tag>         is the original tag WITH prefix (e.g. v1.2.3).
# Returns non-zero on any failure (so atomic_edit rolls the file back).
edit_git_checkout() {
  local file="$1" new_version="$2" id="$3" tag="$4"

  # Bump version/epoch first.
  NEW_VERSION="$new_version" yq -i '.package.version = strenv(NEW_VERSION) | .package.epoch = 0' "$file"

  # Resolve the tag ref. Use the singular-ref endpoint so we get an exact match
  # (or 404) rather than an array of prefix matches.
  local ref obj_type obj_sha commit_sha
  if ! ref="$(gh api "repos/$id/git/ref/tags/$tag" 2>/dev/null)"; then
    warn "edit_git_checkout: could not resolve tag '$tag' for $id"
    return 1
  fi

  obj_type="$(printf '%s' "$ref" | jq -r '.object.type')"
  obj_sha="$(printf '%s' "$ref" | jq -r '.object.sha')"

  case "$obj_type" in
    commit)
      # Lightweight tag: points directly at the commit.
      commit_sha="$obj_sha"
      ;;
    tag)
      # Annotated tag: dereference the tag object to its target commit.
      local tag_obj inner_type
      if ! tag_obj="$(gh api "repos/$id/git/tags/$obj_sha" 2>/dev/null)"; then
        warn "edit_git_checkout: could not dereference annotated tag '$tag' for $id"
        return 1
      fi
      # Verify the dereferenced object is a commit (a chained annotated tag
      # would yield another tag SHA, producing an invalid expected-commit).
      inner_type="$(printf '%s' "$tag_obj" | jq -r '.object.type')"
      if [ "$inner_type" != "commit" ]; then
        warn "edit_git_checkout: annotated tag '$tag' for $id does not dereference to a commit (got '$inner_type')"
        return 1
      fi
      commit_sha="$(printf '%s' "$tag_obj" | jq -r '.object.sha')"
      ;;
    *)
      warn "edit_git_checkout: unexpected ref object type '$obj_type' for tag '$tag'"
      return 1
      ;;
  esac

  if [ -z "$commit_sha" ] || [ "$commit_sha" = "null" ]; then
    warn "edit_git_checkout: empty commit SHA resolving tag '$tag' for $id"
    return 1
  fi

  # Locate the git-checkout pipeline step and pin the resolved commit.
  local idx
  idx="$(yq '.pipeline | to_entries | map(select(.value.uses == "git-checkout")) | .[0].key' "$file")"
  if ! printf '%s' "$idx" | grep -Eq '^[0-9]+$'; then
    warn "edit_git_checkout: could not locate git-checkout pipeline step in $file"
    return 1
  fi
  COMMIT="$commit_sha" yq -i ".pipeline[$idx].with.expected-commit = strenv(COMMIT)" "$file"

  return 0
}

# ---------------------------------------------------------------------------
# Per-package processing
# ---------------------------------------------------------------------------
process_package() {
  local f="$1"
  local name version id prefix
  name="$(yq '.package.name' "$f")"
  version="$(yq '.package.version' "$f")"
  id="$(yq '.update.github.identifier' "$f")"
  prefix="$(yq '.update.github.strip-prefix // ""' "$f")"

  # Guard against a missing identifier (yq yields the literal "null"), which
  # would otherwise produce a request against repos/null/tags.
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    warn "${name} (${f}): missing update.github.identifier (skipping)"
    return
  fi

  local latest
  if ! latest="$(latest_tag "$id" "$prefix")"; then
    warn "${name}: could not determine latest tag from https://github.com/${id} (skipping)"
    return
  fi

  # Tricky-tag guard: only plain numeric tags (e.g. 1.2, 1.2.3) are safe to
  # auto-bump. Anything else (pre-releases, suffixes) is skipped.
  if ! printf '%s' "$latest" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    warn "${name}: non-numeric latest tag '${latest}' from https://github.com/${id} (skipping)"
    return
  fi

  # The new tag (with prefix re-added) is needed by the git-checkout editor
  # regardless of whether a current version is set.
  local new_tag="${prefix}${latest}"

  if [ -z "$version" ] || [ "$version" = "null" ]; then
    # No version set yet (e.g. a freshly added package): seed it with the latest.
    info "${name}: no version set → ${latest}"
    if ! confirm "Set ${name} version to ${latest}? [y/N] "; then
      info "${name}: skipped"
      return
    fi
  else
    if ! is_newer "$version" "$latest"; then
      ok "${name}: up to date (${version})"
      return
    fi

    # Reconstruct the real git tags (with prefix re-added) for the compare URL.
    local old_tag="${prefix}${version}"
    info "${name}: ${version} → ${latest}"
    info "  https://github.com/${id}/compare/${old_tag}...${new_tag}"

    if ! confirm "Update ${name} ${version} → ${latest}? [y/N] "; then
      info "${name}: skipped"
      return
    fi
  fi

  # Detect the package type to choose the right editor.
  local ptype
  if ! ptype="$(package_type "$f")"; then
    warn "${name}: unrecognised pipeline type (skipping)"
    return
  fi

  local editor
  local -a editor_args=("$latest")
  case "$ptype" in
    git-checkout)
      editor="edit_git_checkout"
      # The git-checkout editor needs the identifier and the original tag
      # (with prefix re-added) to resolve the tag to a commit SHA.
      editor_args+=("$id" "$new_tag")
      ;;
    fetch) editor="edit_fetch" ;;
    *)
      warn "${name}: unsupported pipeline type '${ptype}' (skipping)"
      return
      ;;
  esac

  if atomic_edit "$f" "$editor" "${editor_args[@]}"; then
    ok "${name}: updated to ${latest}"
  else
    warn "${name}: update failed, reverted"
  fi
}

# ---------------------------------------------------------------------------
# Entry point — process a single package YAML given as the sole argument.
# ---------------------------------------------------------------------------
usage() { warn "usage: $(basename "$0") <path/to/package.yaml>"; }

main() {
  if [ "$#" -ne 1 ]; then
    usage
    exit 1
  fi

  local file="$1"
  if [ ! -f "$file" ]; then
    warn "file not found: $file"
    exit 1
  fi

  require_deps

  # Skip packages that have not opted into updates.
  if [ "$(yq '.update.enabled // false' "$file")" != "true" ]; then
    local name
    name="$(yq '.package.name // ""' "$file")"
    info "${name:-$file}: updates not enabled (skipping)"
    exit 0
  fi

  process_package "$file"
}

# Only auto-run when executed directly, not when sourced (e.g. by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
