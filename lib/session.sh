#!/usr/bin/env bash
# Sourced by an interactive SSH bash or zsh shell of the shared development user.
[[ "${SGH_SESSION_READY:-}" == 1 ]] && return 0
case "$-" in *i*) ;; *) return 0;; esac
[[ -n "${SSH_CONNECTION:-}" ]] || return 0

if [[ -n "${ZSH_VERSION:-}" ]]; then
  _sgh_source_file="${(%):-%x}"
else
  _sgh_source_file="${BASH_SOURCE[0]}"
fi
_sgh_root="$(cd "$(dirname "$_sgh_source_file")/.." && pwd)"
unset _sgh_source_file
source "$_sgh_root/lib/core.sh"
umask 077
mkdir -p "$SGH_HOME/sessions" "$SGH_PROFILES" "$SGH_BINDINGS"
export SGH_CONTEXT="$(mktemp -d "$SGH_HOME/sessions/session.XXXXXXXX")"
export SGH_SESSION_READY=1
printf 'default\n' > "$SGH_CONTEXT/active"
export PATH="$_sgh_root/guard-bin:$PATH"
# Each SSH login owns its own active-profile state; nested shells inherit it.
"$_sgh_root/bin/sgh" auto || true
unset _sgh_root
