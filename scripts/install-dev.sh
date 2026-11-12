#!/usr/bin/env bash
# Root-only installer for the shared development server.
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'sudo bash scripts/install-dev.sh <shared-user> 로 실행하세요.' >&2; exit 1; }
USER_NAME="${1:-shared}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_SHELL="$(getent passwd "$USER_NAME" | cut -d: -f7)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || { echo "사용자/홈 디렉터리 없음: $USER_NAME" >&2; exit 1; }
case "${USER_SHELL##*/}" in
  bash|zsh) ;;
  *) echo "지원되지 않는 로그인 셸 (bash/zsh 필요): $USER_SHELL" >&2; exit 1;;
esac
for tool in git gh ssh-keygen flock sha256sum timeout mktemp; do
  command -v "$tool" >/dev/null || { echo "필요한 명령 없음: $tool" >&2; exit 1; }
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/opt/sgh"
install -d -m 755 "$DEST" "$DEST/bin" "$DEST/lib" "$DEST/real" "$DEST/guard-bin"
find_real() {
  local binary
  binary="$(command -v "$1")"
  [[ "$binary" == "$DEST/guard-bin/"* ]] && binary="$DEST/real/$1"
  readlink -f "$binary"
}
REAL_GIT="$(find_real git)"
REAL_GH="$(find_real gh)"
[[ -x "$REAL_GIT" && -x "$REAL_GH" ]] || { echo 'Git/GH 실행 파일을 찾지 못했습니다.' >&2; exit 1; }
ln -sfn "$REAL_GIT" "$DEST/real/git"
ln -sfn "$REAL_GH" "$DEST/real/gh"
install -m 755 "$ROOT/bin/sgh" "$DEST/bin/sgh"
install -m 644 "$ROOT/lib/core.sh" "$ROOT/lib/session.sh" "$DEST/lib/"
install -m 755 "$ROOT/guard-bin/git" "$ROOT/guard-bin/gh" "$DEST/guard-bin/"
ln -sfn "$DEST/bin/sgh" /usr/local/bin/sgh

HOOK=$(cat <<'TEXT'
# >>> sgh >>>
if [[ $- == *i* && -r /opt/sgh/lib/session.sh ]]; then
  source /opt/sgh/lib/session.sh
fi
# <<< sgh <<<
TEXT
)
install_hook() {
  local file="$1" backup
  if [[ ! -e "$file" ]]; then
    touch "$file"; chown "$USER_NAME" "$file"
  fi
  # Migrate the previous proof-of-concept hook without touching other shell config.
  if grep -Fq '# >>> shared-gh-bootstrap >>>' "$file"; then
    backup="$file.sgh-before-migration.$(date +%Y%m%d%H%M%S).bak"
    cp -p "$file" "$backup"
    sed -i '/^# >>> shared-gh-bootstrap >>>$/,/^# <<< shared-gh-bootstrap <<<$/{d;}' "$file"
    echo "구 버전 로그인 훅 제거, 백업: $backup"
  fi
  if ! grep -Fq '# >>> sgh >>>' "$file"; then
    printf '\n%s\n' "$HOOK" >> "$file"
  fi
}
case "${USER_SHELL##*/}" in
  bash)
    install_hook "$USER_HOME/.bashrc"
    if [[ -e "$USER_HOME/.bash_profile" ]]; then
      install_hook "$USER_HOME/.bash_profile"
    else
      install_hook "$USER_HOME/.profile"
    fi
    SESSION_HOOKS="$USER_HOME/.bashrc / 로그인 프로필"
    ;;
  zsh)
    install_hook "$USER_HOME/.zshrc"
    SESSION_HOOKS="$USER_HOME/.zshrc"
    ;;
esac

# Place this option before Include and Match blocks (sshd first-match semantics).
SSHD_CONFIG=/etc/ssh/sshd_config
if [[ -f "$SSHD_CONFIG" ]]; then
  if ! head -n 1 "$SSHD_CONFIG" | grep -Eq '^[[:space:]]*ExposeAuthInfo[[:space:]]+yes([[:space:]]|$)'; then
    backup="$SSHD_CONFIG.sgh.$(date +%Y%m%d%H%M%S).bak"
    cp -p "$SSHD_CONFIG" "$backup"
    tmp="$(mktemp /etc/ssh/.sshd_config.sgh.XXXXXX)"
    { printf 'ExposeAuthInfo yes\n'; cat "$SSHD_CONFIG"; } > "$tmp"
    chmod --reference="$SSHD_CONFIG" "$tmp"
    chown --reference="$SSHD_CONFIG" "$tmp"
    cat "$tmp" > "$SSHD_CONFIG"
    rm -f "$tmp"
    sshd_bin="$(command -v sshd || true)"
    [[ -n "$sshd_bin" ]] || sshd_bin=/usr/sbin/sshd
    if ! "$sshd_bin" -t; then
      cp -p "$backup" "$SSHD_CONFIG"
      echo "sshd -t 실패. 원래 설정으로 복구했습니다: $backup" >&2
      exit 1
    fi
    echo "SSH 설정 백업: $backup"
  fi
else
  echo '주의: /etc/ssh/sshd_config가 없으므로 ExposeAuthInfo yes를 수동 설정해야 합니다.' >&2
fi

cat <<END

[sgh 설치 완료]
  공용 사용자: $USER_NAME
  실행 명령:  /usr/local/bin/sgh
  세션 훅:   $SESSION_HOOKS
  Git 래퍼:  /opt/sgh/guard-bin/git, gh
  인증 정보:  $USER_HOME/.local/share/sgh (Git 저장소 밖)

1) SSH 재시작 전에 설정 확인 (기존 세션을 유지하세요):
   sudo sshd -t
   sudo sshd -T -C user=$USER_NAME,host=localhost,addr=127.0.0.1 | grep -i exposeauthinfo
   sudo systemctl reload ssh   # 시스템에 따라 sshd

2) 공용 계정에 기존 gh 인증과 Git 작성자가 있다면 그대로 보존됩니다.
   공용 계정 SSH 접속 후  sgh init-default  로 명시적으로 등록하세요.

3) 개인별 개발 서버 SSH 공개키를 ~${USER_NAME}/.ssh/authorized_keys에 추가하세요.
   사용자:  sgh add alice  →  sgh bind alice

주의: 같은 Linux UID의 프로세스는 토큰과 세션을 서로 읽을 수 있습니다.
주의: PATH 래퍼는 실수 방지 수단이지 안전한 인증 강제 정책이 아닙니다.
END
