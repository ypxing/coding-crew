# platforms.sh — every per-platform fact install.sh and uninstall.sh need, read from
# orchestrator/platforms.json (the one source of the platform list and of where each platform
# keeps skills). Sourced, never run; bash 3.2-compatible (uninstall.sh does not re-exec).
#
# The sourcing script sets SCRIPT_DIR (the coding-crew checkout) and REPO_ROOT (the install
# target; $HOME means user scope) and has jq on PATH. Adding a platform is one platforms.json
# entry: nothing here names one.
#
# A skill installs to <projectSkills>/<skill> at project scope and <userSkills>/<skill> at user
# scope. At user scope a path under <configDir>/ moves to $<configDirEnv> when that is set —
# the platform's own CLI reads its config from there — and anything else stays under $HOME.

# CODING_CREW_PLATFORMS_JSON points at another copy of the file (tests add a platform with it).
PLATFORMS_JSON="${CODING_CREW_PLATFORMS_JSON:-$SCRIPT_DIR/orchestrator/platforms.json}"

PLATFORMS=()
_PF_PROJECT=(); _PF_USER=(); _PF_CONFIG=(); _PF_ENV=()
while IFS=$'\t' read -r _pf_name _pf_project _pf_user _pf_config _pf_env; do
  [[ -n "$_pf_name" ]] || continue
  PLATFORMS+=("$_pf_name")
  _PF_PROJECT+=("$_pf_project"); _PF_USER+=("$_pf_user")
  _PF_CONFIG+=("$_pf_config"); _PF_ENV+=("${_pf_env%$'\r'}")
done < <(jq -r 'to_entries[] | [.key, .value.projectSkills, .value.userSkills, .value.configDir, .value.configDirEnv] | @tsv' "$PLATFORMS_JSON")
unset _pf_name _pf_project _pf_user _pf_config _pf_env
[[ ${#PLATFORMS[@]} -gt 0 ]] || { echo "Error: no platforms read from $PLATFORMS_JSON" >&2; exit 1; }

# platforms_joined <separator> — the platform list as one line, in platforms.json order.
platforms_joined() {
  local sep="$1" out="" p
  for p in "${PLATFORMS[@]}"; do out="${out:+$out$sep}$p"; done
  printf '%s' "$out"
}

# _platform_index <platform> — sets $_PF_I; returns 1 for a platform platforms.json lacks.
_PF_I=0
_platform_index() {
  local i
  for i in "${!PLATFORMS[@]}"; do
    [[ "${PLATFORMS[$i]}" == "$1" ]] && { _PF_I=$i; return 0; }
  done
  return 1
}

platform_known() { _platform_index "$1"; }

_platform_user_scope() { [[ "$REPO_ROOT" == "$HOME" ]]; }

# platform_skills_dir <platform> [project|user] — sets $_PLATFORM_SKILLS to the platform's
# skills dir, relative to the target root, for the given scope (default: this run's).
_PLATFORM_SKILLS=""
platform_skills_dir() {
  local platform="$1" scope="${2:-}"
  _platform_index "$platform" || return 1
  if [[ -z "$scope" ]]; then
    scope=project; _platform_user_scope && scope=user
  fi
  if [[ "$scope" == user ]]; then _PLATFORM_SKILLS="${_PF_USER[$_PF_I]}"; else _PLATFORM_SKILLS="${_PF_PROJECT[$_PF_I]}"; fi
}

# platform_scope_path <platform> <path> [project|user] — <path> rewritten to the given scope
# (default: this run's): a path under one scope's base (the dir holding its skills dir) moves
# to the other's, so `.pi/agents/x` is `.pi/agent/agents/x` at user scope. Anything else is
# returned unchanged. Used for paths the registry writes once for both scopes (retired agents).
platform_scope_path() {
  local platform="$1" path="$2" scope="${3:-}" project_base user_base target rest
  _platform_index "$platform" || { printf '%s' "$path"; return 0; }
  if [[ -z "$scope" ]]; then
    scope=project; _platform_user_scope && scope=user
  fi
  project_base="$(dirname "${_PF_PROJECT[$_PF_I]}")"
  user_base="$(dirname "${_PF_USER[$_PF_I]}")"
  if [[ "$scope" == user ]]; then target="$user_base"; else target="$project_base"; fi
  # The longer base first: pi's user base (.pi/agent) sits inside its project base (.pi).
  if [[ ${#user_base} -ge ${#project_base} ]]; then
    if [[ "$path" == "$user_base"/* ]]; then rest="${path#"$user_base"/}"
    elif [[ "$path" == "$project_base"/* ]]; then rest="${path#"$project_base"/}"
    else printf '%s' "$path"; return 0; fi
  else
    if [[ "$path" == "$project_base"/* ]]; then rest="${path#"$project_base"/}"
    elif [[ "$path" == "$user_base"/* ]]; then rest="${path#"$user_base"/}"
    else printf '%s' "$path"; return 0; fi
  fi
  printf '%s/%s' "$target" "$rest"
}

# platform_scope_paths <platform> <path> — every path <path> may occupy in this target: this
# scope's, then the other scope's when an earlier install wrote it here. Earlier installs wrote
# under .<platform>/ at both scopes, so the other scope's path is a dead copy only when that
# scope's base is .<platform> (Copilot's .copilot/ at project scope, pi's .pi/ at user scope);
# any other is a live install of its own (a repo's .github/ under $HOME), left in place.
platform_scope_paths() {
  local platform="$1" path="$2" here there other=user
  here=$(platform_scope_path "$platform" "$path")
  printf '%s\n' "$here"
  _platform_user_scope && other=project
  platform_skills_dir "$platform" "$other" || return 0
  [[ "$(dirname "$_PLATFORM_SKILLS")" == ".$platform" ]] || return 0
  there=$(platform_scope_path "$platform" "$path" "$other")
  [[ "$there" != "$here" ]] && printf '%s\n' "$there"
  return 0
}

# resolve_dest <platform> <path> — sets $_DEST_ROOT (absolute base dir, in place of $REPO_ROOT)
# and $_DEST_REL (the path's remainder under it). Differs from ($REPO_ROOT, <path>) only at user
# scope, for a path under the platform's configDir, with its configDirEnv set. A caller joins
# them once and reuses the result rather than calling this per file (fork count on Git Bash).
_DEST_ROOT=""; _DEST_REL=""
resolve_dest() {
  local platform="$1" path="$2"
  _DEST_ROOT="$REPO_ROOT"; _DEST_REL="$path"
  _platform_user_scope || return 0
  _platform_index "$platform" || return 0
  local config="${_PF_CONFIG[$_PF_I]}" env_name="${_PF_ENV[$_PF_I]}"
  local env_val="${!env_name:-}"
  [[ -n "$env_val" && "$path" == "$config"/* ]] || return 0
  _DEST_ROOT="$env_val"
  _DEST_REL="${path#"$config"/}"
}

# resolve_skill_dest <platform> <skill> — resolve_dest for <skill>'s install dir at this scope;
# also sets $_SKILL_DEST, the dir relative to the target root before any relocation.
_SKILL_DEST=""
resolve_skill_dest() {
  platform_skills_dir "$1" || return 1
  _SKILL_DEST="$_PLATFORM_SKILLS/$2"
  resolve_dest "$1" "$_SKILL_DEST"
}

# platform_user_dirs — the user-level dirs a host may resolve a skill or agent definition from,
# one absolute path per line: each platform's user skills dir and <configDir>/agents, relocated
# as a user-scope install would be.
platform_user_dirs() {
  local i env_name env_val config user
  for i in "${!PLATFORMS[@]}"; do
    config="${_PF_CONFIG[$i]}"; user="${_PF_USER[$i]}"; env_name="${_PF_ENV[$i]}"
    env_val="${!env_name:-}"
    if [[ -n "$env_val" && "$user" == "$config"/* ]]; then
      printf '%s/%s\n' "$env_val" "${user#"$config"/}"
    else
      printf '%s/%s\n' "$HOME" "$user"
    fi
    printf '%s/agents\n' "${env_val:-$HOME/$config}"
  done
}
