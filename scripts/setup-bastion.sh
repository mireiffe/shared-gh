#!/usr/bin/env bash
# Run as each person's own Unix user on the bastion server.
set -euo pipefail
[[ $# -ge 1 && $# -le 3 ]] || {
  echo 'Usage: bash scripts/setup-bastion.sh <dev-host> [shared-user=shared] [alias=dev-shared]' >&2
  exit 2
}
DEV_HOST="$1" DEV_USER="${2:-shared}" SSH_ALIAS="${3:-dev-shared}"
[[ "$SSH_ALIAS" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Invalid alias' >&2; exit 2; }
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
KEYFILE="$HOME/.ssh/id_ed25519_sgh_$SSH_ALIAS"
if [[ ! -e "$KEYFILE" ]]; then
  ssh-keygen -t ed25519 -f "$KEYFILE" -C "${USER:-user}@bastion-$SSH_ALIAS"
fi
CONFIG="$HOME/.ssh/config"
[[ -e "$CONFIG" ]] || touch "$CONFIG"
if ! grep -Fq "# sgh:$SSH_ALIAS" "$CONFIG"; then
  tmp="$(mktemp "$HOME/.ssh/config.XXXXXX")"
  {
    cat <<SSH
# sgh:$SSH_ALIAS
Host $SSH_ALIAS
  HostName $DEV_HOST
  User $DEV_USER
  IdentityFile $KEYFILE
  IdentitiesOnly yes

SSH
    cat "$CONFIG"
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG"
fi
printf '\n관리자에게 아래 공개키만 전달하세요. 개인키는 공유하지 마세요.\n%s\n\n등록 후 ssh %s 로 접속하세요.\n' "$(cat "$KEYFILE.pub")" "$SSH_ALIAS"
