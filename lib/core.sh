#!/usr/bin/env bash
# Common sgh helpers. No file in profiles/ is ever sourced as shell code.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  _sgh_core_file="${(%):-%x}"
else
  _sgh_core_file="${BASH_SOURCE[0]}"
fi
SGH_ROOT="$(cd "$(dirname "$_sgh_core_file")/.." && pwd)"
unset _sgh_core_file
SGH_REAL_GIT="$SGH_ROOT/real/git"
SGH_REAL_GH="$SGH_ROOT/real/gh"
SGH_HOME="${SGH_HOME:-$HOME/.local/share/sgh}"
SGH_PROFILES="$SGH_HOME/profiles"
SGH_BINDINGS="$SGH_HOME/bindings"
SGH_WORKTREE_BINDINGS="$SGH_HOME/worktree-bindings"

sgh_alias_ok() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]
}

sgh_profile_file() { printf '%s/%s/profile\n' "$SGH_PROFILES" "$1"; }

# Accept hostnames and the convenient https://HOST/ spelling, never paths,
# userinfo, ports, or shell metacharacters. gh --hostname expects a hostname.
sgh_host_normalize() {
  local host="${1:-}"
  host="${host#https://}"
  host="${host%/}"
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || return 2
  [[ "$host" != *..* && "$host" != *. && "$host" != *.-* && "$host" != *-.* && "$host" != *- ]] || return 2
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]'
}

sgh_profile_host() {
  local alias="$1" host="" f
  # Registration takes place before metadata exists, so use a process-local
  # override while gh auth login is underway (never shared across sessions).
  if [[ "${SGH_HOST_OVERRIDE_PROFILE:-}" == "$alias" && -n "${SGH_HOST_OVERRIDE:-}" ]]; then
    sgh_host_normalize "$SGH_HOST_OVERRIDE"
    return $?
  fi
  f="$(sgh_profile_file "$alias")"
  if [[ -r "$f" ]]; then
    host="$(sed -n '4p' "$f")"
    [[ -n "$host" ]] || host=github.com   # legacy 3-line profile
  elif [[ "$alias" == default ]]; then
    host="${SGH_GITHUB_HOST:-${GH_HOST:-github.com}}"
  else
    host="${SGH_GITHUB_HOST:-$(sgh_profile_host default)}"
  fi
  sgh_host_normalize "$host"
}

sgh_default_gh_dir() {
  if [[ -n "${SGH_DEFAULT_GH_DIR:-}" ]]; then
    printf '%s\n' "$SGH_DEFAULT_GH_DIR"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf '%s/gh\n' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config/gh\n' "$HOME"
  fi
}

sgh_gh_dir() {
  if [[ "$1" == default ]]; then sgh_default_gh_dir
  else printf '%s/%s/gh\n' "$SGH_PROFILES" "$1"; fi
}

sgh_git_config() {
  if [[ "$1" == default ]]; then printf '%s/.gitconfig\n' "$HOME"
  else printf '%s/%s/gitconfig\n' "$SGH_PROFILES" "$1"; fi
}

sgh_profile_read() {
  local alias="$1" login name email host="github.com" extra f
  sgh_alias_ok "$alias" || return 1
  f="$(sgh_profile_file "$alias")"
  [[ -r "$f" ]] || return 1
  {
    IFS= read -r login || return 1
    IFS= read -r name || return 1
    IFS= read -r email || return 1
    # New profiles have a fourth line for the GitHub host. Old profiles have
    # only three lines and continue to mean github.com.
    if IFS= read -r host; then
      [[ -n "$host" ]] || return 1
      if IFS= read -r extra; then return 1; fi
    else
      host=github.com
    fi
  } < "$f"
  [[ "$login" =~ ^[A-Za-z0-9-]+$ && -n "$name" && "$email" == *@* && "$email" != *' '* ]] || return 1
  host="$(sgh_host_normalize "$host")" || return 1
  SGH_LOGIN="$login" SGH_AUTHOR="$name" SGH_EMAIL="$email" SGH_HOST="$host"
}

sgh_gh_command() {
  local alias="$1" host
  shift
  host="$(sgh_profile_host "$alias")" || return 2
  # Do not allow environment credentials left by another shell to override a profile.
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    GH_HOST="$host" GH_CONFIG_DIR="$(sgh_gh_dir "$alias")" "$SGH_REAL_GH" "$@"
}

sgh_live_login() {
  local alias="$1" host
  host="$(sgh_profile_host "$alias")" || return 2
  command timeout "${SGH_AUTH_TIMEOUT:-8}" \
    env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    GH_HOST="$host" GH_CONFIG_DIR="$(sgh_gh_dir "$alias")" "$SGH_REAL_GH" api user --jq .login 2>/dev/null
}

sgh_verify_profile() {
  local alias="$1" expected actual
  sgh_profile_read "$alias" || return 1
  expected="$SGH_LOGIN"
  actual="$(sgh_live_login "$alias")" || return 1
  [[ -n "$actual" && "${actual,,}" == "${expected,,}" ]]
}

sgh_current() {
  local alias=default
  if [[ -n "${SGH_CONTEXT:-}" && -r "$SGH_CONTEXT/active" ]]; then
    IFS= read -r alias < "$SGH_CONTEXT/active" || alias=default
  fi
  if ! sgh_alias_ok "$alias"; then alias=default; fi
  printf '%s\n' "$alias"
}

sgh_context_set() {
  local alias="$1" tmp
  sgh_alias_ok "$alias" || return 2
  [[ -n "${SGH_CONTEXT:-}" && -d "$SGH_CONTEXT" ]] || return 1
  tmp="$(mktemp "$SGH_CONTEXT/.active.XXXXXX")" || return 1
  printf '%s\n' "$alias" > "$tmp"
  mv -f -- "$tmp" "$SGH_CONTEXT/active"
}

sgh_apply() {
  local alias="$1"
  export GH_HOST="$(sgh_profile_host "$alias")" || return 2
  export GH_CONFIG_DIR="$(sgh_gh_dir "$alias")"
  export GIT_CONFIG_GLOBAL="$(sgh_git_config "$alias")"
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  if sgh_profile_read "$alias"; then
    export GIT_AUTHOR_NAME="$SGH_AUTHOR" GIT_COMMITTER_NAME="$SGH_AUTHOR"
    export GIT_AUTHOR_EMAIL="$SGH_EMAIL" GIT_COMMITTER_EMAIL="$SGH_EMAIL"
  fi
  export SGH_ACTIVE_PROFILE="$alias"
}

# For a personal profile, an invalid credential selects the working default.
# The original operation runs exactly once, using the selected profile.
sgh_resolve() {
  local alias
  alias="$(sgh_current)"
  if [[ "$alias" != default ]] && ! sgh_verify_profile "$alias"; then
    printf '[sgh] %s 프로필 인증 실패/불일치. 현재 세션을 default로 전환합니다.\n' "$alias" >&2
    sgh_context_set default || true
    alias=default
  fi
  sgh_apply "$alias"
}

sgh_ssh_key_id() {
  local key fingerprint
  [[ -n "${SSH_USER_AUTH:-}" && -r "$SSH_USER_AUTH" ]] || return 1
  key="$(awk '$1 == "publickey" {print $2, $3; exit}' "$SSH_USER_AUTH")"
  [[ -n "$key" ]] || return 1
  fingerprint="$(printf '%s\n' "$key" | ssh-keygen -lf - -E sha256 2>/dev/null | awk '{print $2}')"
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]] || return 1
  printf '%s' "$fingerprint" | sha256sum | cut -c1-24
  printf '\n'
}

# Worktree identity is deliberately NOT a user identity. It is an explicit
# workspace preference for terminals launched by a detached IDE server that
# no longer exposes the SSH key used for the original connection.
sgh_worktree_root() {
  local root
  root="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    "$SGH_REAL_GIT" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -d "$root" ]] || return 1
  (cd -- "$root" && pwd -P)
}

sgh_worktree_key() {
  local root
  root="$(sgh_worktree_root)" || return 1
  printf '%s' "$root" | sha256sum | cut -c1-24
}

sgh_write_profile() {
  local alias="$1" login="$2" name="$3" email="$4" host="${5:-github.com}" dir tmp
  sgh_alias_ok "$alias" || return 2
  [[ "$login" =~ ^[A-Za-z0-9-]+$ && -n "$name" && "$name" != *$'\n'* && "$email" == *@* && "$email" != *' '* && "$email" != *$'\n'* ]] || return 2
  host="$(sgh_host_normalize "$host")" || return 2
  dir="$SGH_PROFILES/$alias"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.profile.XXXXXX")" || return 1
  chmod 600 "$tmp"
  printf '%s\n%s\n%s\n%s\n' "$login" "$name" "$email" "$host" > "$tmp"
  mv -f "$tmp" "$dir/profile"
}

# Best-effort identification of read-only git calls. Other calls are checked.
sgh_git_is_read_only() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix|--exec-path)
        [[ $# -ge 2 ]] || return 1; shift 2;;
      -C?*|-c?*|--git-dir=*|--work-tree=*|--namespace=*|--config-env=*|--super-prefix=*|--exec-path=*|--no-pager|--paginate|--no-optional-locks|--bare)
        shift;;
      *) break;;
    esac
  done
  case "${1:-}" in
    status|diff|log|show|rev-parse|ls-files|cat-file|ls-tree|grep|blame|shortlog|describe|name-rev|version|--version|help|--help|var) return 0;;
    remote) [[ "${2:-}" == '-v' && $# -eq 2 || $# -eq 1 ]]; return $?;;
    branch) [[ $# -eq 1 || ( $# -eq 2 && "${2:-}" == '--list' ) ]]; return $?;;
    config) case "${2:-}" in --get|--get-all|--get-regexp|--get-urlmatch|--list|-l) return 0;; esac; return 1;;
    *) return 1;;
  esac
}
