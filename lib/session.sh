#!/usr/bin/env bash
# Sourced by interactive bash/zsh shells, including detached Orca IDE terminals.
# Reuse the context within the same interactive shell or a direct nested
# shell. Detached IDE servers may inherit the environment of a startup shell;
# new shells spawned later MUST get a fresh context instead of accidentally
# sharing the first shell's selected profile.
_sgh_this_shell_pid="${BASHPID:-$$}"
if [[ "${SGH_SESSION_READY:-}" == 1 && -d "${SGH_CONTEXT:-/nonexistent}" ]]; then
  if [[ "${SGH_SESSION_SHELL_PID:-}" == "$_sgh_this_shell_pid" || \
        "${SGH_SESSION_SHELL_PID:-}" == "${PPID:-}" ]]; then
    unset _sgh_this_shell_pid
    return 0
  fi
  unset SGH_CONTEXT SGH_SESSION_READY SGH_SESSION_SHELL_PID
fi
unset _sgh_this_shell_pid
case "$-" in *i*) ;; *) return 0;; esac
# Orca managed terminals may not inherit SSH_CONNECTION or SSH_USER_AUTH.
# Initialize them as independent sessions anyway; auto-select can use a
# previously authorized worktree binding when the SSH identity is unavailable.

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
export SGH_SESSION_SHELL_PID="${BASHPID:-$$}"
printf 'default\n' > "$SGH_CONTEXT/active"
export PATH="$_sgh_root/guard-bin:$PATH"
# Each interactive shell owns a profile selection; nested shells inherit it.
"$_sgh_root/bin/sgh" auto || true
unset _sgh_root
