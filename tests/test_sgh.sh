#!/usr/bin/env bash
# Hermetic (no GitHub network) integration coverage of per-session selection/fallback.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/app" HD="$TMP/home"
mkdir -p "$APP"/{bin,lib,real,guard-bin} "$HD/.config/gh" "$TMP/bin" "$TMP/repos"
cp "$ROOT/bin/sgh" "$APP/bin/sgh"
cp "$ROOT/lib/"* "$APP/lib/"
cp "$ROOT/guard-bin/"* "$APP/guard-bin/"
chmod +x "$APP/bin/sgh" "$APP/guard-bin/"*
ln -s "$APP/bin/sgh" "$TMP/bin/sgh"
REAL_GIT="$(command -v git)"
ln -s "$REAL_GIT" "$APP/real/git"
cat > "$APP/real/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'auth login')
    [[ "${MOCK_AUTH_FAIL:-0}" == 1 ]] && exit 1
    host="${GH_HOST:-github.com}"
    args=("$@")
    found=""
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ "${args[i]}" == --hostname ]]; then found="${args[i+1]:-}"; fi
    done
    [[ "$found" == "$host" ]] || { echo "Wrong gh auth hostname: $found != $host" >&2; exit 4; }
    mkdir -p "$GH_CONFIG_DIR"
    printf '%s\n' "${MOCK_LOGIN:-shared}" > "$GH_CONFIG_DIR/mock_login"
    printf '%s\n' "$host" > "$GH_CONFIG_DIR/mock_host"
    ;;
  'api user')
    [[ -e "$GH_CONFIG_DIR/revoked" ]] && exit 1
    [[ -r "$GH_CONFIG_DIR/mock_login" ]] || exit 1
    [[ "${GH_HOST:-github.com}" == "$(cat "$GH_CONFIG_DIR/mock_host")" ]] || exit 5
    case "${4:-}" in
      .login) cat "$GH_CONFIG_DIR/mock_login";;
      .id) echo 123;;
      '.name // .login') cat "$GH_CONFIG_DIR/mock_login";;
      '.email // empty') printf '%s\n' "${MOCK_EMAIL:-}";;
      *) exit 3;;
    esac
    ;;
  'auth git-credential')
    [[ "${3:-}" == get ]] || exit 0
    name="$(cat "$GH_CONFIG_DIR/mock_login")"
    host="$(cat "$GH_CONFIG_DIR/mock_host")"
    [[ "${GH_HOST:-github.com}" == "$host" ]] || exit 5
    req="$(cat)"
    [[ "$req" == *"host=$host"* ]] || { echo 'wrong credential host' >&2; exit 6; }
    printf 'username=%s\npassword=token_%s\n' "$name" "$name"
    ;;
  'pr merge')
    echo "gh-pr-merge-as-$(cat "$GH_CONFIG_DIR/mock_login")"
    ;;
  *) echo "Mock gh unexpected call: $*" >&2; exit 3;;
esac
GH
chmod +x "$APP/real/gh"
echo shared > "$HD/.config/gh/mock_login"
echo github.com > "$HD/.config/gh/mock_host"
"$REAL_GIT" config --file "$HD/.gitconfig" user.name 'Shared Account'
"$REAL_GIT" config --file "$HD/.gitconfig" user.email shared@example.com
cat > "$TMP/bin/ssh-keygen" <<'MOCKSSH'
#!/usr/bin/env python3
import sys,hashlib,base64
args=sys.argv[1:]
if len(args)<3 or '-lf' not in args: sys.exit(2)
s=sys.stdin.read().strip().split()
if len(s)<2: sys.exit(2)
raw=base64.b64decode(s[1]); fp=base64.b64encode(hashlib.sha256(raw).digest()).decode().rstrip('=')
print('256 SHA256:'+fp+' mocked-key (ED25519)')
MOCKSSH
chmod +x "$TMP/bin/ssh-keygen"
cat > "$TMP/alice_key.pub" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOdGNbeWi7Nr90e4dgfTSDjhgItdG0jGPg1mMW91XcXm alice
KEY
cat > "$TMP/bob_key.pub" <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIiZ2gViUMtiajK/5rJTO9O86ttI1AfFYNdHnEJwLFy6 bob
KEY
for actor in alice bob; do
  printf 'publickey %s\n' "$(awk '{print $1, $2}' "$TMP/${actor}_key.pub")" > "$TMP/$actor.auth"
done
export TEST_APP="$APP" TEST_HD="$HD" TEST_TMP="$TMP" TEST_REAL_GIT="$REAL_GIT"
run_actor() {
  local actor="$1" script="$2"; shift 2
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    PATH="$TMP/bin:$PATH" HOME="$HD" SGH_HOME="$HD/.local/share/sgh" SSH_CONNECTION='1 2 3 4' \
    SSH_USER_AUTH="$TMP/$actor.auth" \
    "$@" bash --noprofile --norc -ic \
    "source '$APP/lib/session.sh'; source '$script'" 2>"$TMP/${actor}.stderr"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$TMP/init.sh" <<'BASH'
sgh init-default
BASH
run_actor alice "$TMP/init.sh" > "$TMP/default_init.out"
[[ "$(sed -n '1p' "$HD/.local/share/sgh/profiles/default/profile")" == shared ]] || fail 'default not initialized'
echo 'PASS: existing shared gh auth + git name are kept as the working default.'

cat > "$TMP/add.sh" <<'BASH'
printf '\n\n' | sgh add "$MOCK_LOGIN"
sgh bind "$MOCK_LOGIN"
[[ "$(sgh list)" == *"$MOCK_LOGIN"* ]]
BASH
run_actor alice "$TMP/add.sh" MOCK_LOGIN=alice > "$TMP/alice_add.out" || fail 'Alice registration'
run_actor bob "$TMP/add.sh" MOCK_LOGIN=bob > "$TMP/bob_add.out" || fail 'Bob registration'
echo 'PASS: accounts registered and bound to their distinct authenticated SSH keys.'

cat > "$TMP/status.sh" <<'BASH'
sgh status
BASH
run_actor alice "$TMP/status.sh" > "$TMP/alice_status.out"
run_actor bob "$TMP/status.sh" > "$TMP/bob_status.out"
grep -q '현재 세션 프로필 : alice' "$TMP/alice_status.out" || fail 'alice auto selection'
grep -q '현재 세션 프로필 : bob' "$TMP/bob_status.out" || fail 'bob auto selection'
echo 'PASS: SSH logins auto-select profile using server-verifiable key fingerprints.'

"$REAL_GIT" init -q "$TMP/repos/A"
"$REAL_GIT" init -q "$TMP/repos/B"
cat > "$TMP/parallel.sh" <<'BASH'
sgh swap "$MOCK_LOGIN" >/dev/null
if [[ "$MOCK_LOGIN" == alice ]]; then
  repo="$TEST_TMP/repos/A"
else
  repo="$TEST_TMP/repos/B"
fi
git -C "$repo" commit --allow-empty -qm first
printf 'ACTOR=%s PROFILE=%s GIT_LOGIN=%s\n' "$MOCK_LOGIN" "$(sgh list | grep '^\*' | awk '{print $2}')" "$(gh api user --jq .login)"
BASH
run_actor alice "$TMP/parallel.sh" MOCK_LOGIN=alice > "$TMP/parallel_alice.out" &
pa=$!
run_actor bob "$TMP/parallel.sh" MOCK_LOGIN=bob > "$TMP/parallel_bob.out" &
pb=$!
wait "$pa" || fail 'parallel Alice command'
wait "$pb" || fail 'parallel Bob command'
[[ "$("$REAL_GIT" -C "$TMP/repos/A" log -1 --format='%an <%ae>')" == 'alice <123+alice@users.noreply.github.com>' ]] || fail 'alice author'
[[ "$("$REAL_GIT" -C "$TMP/repos/B" log -1 --format='%an <%ae>')" == 'bob <123+bob@users.noreply.github.com>' ]] || fail 'bob author'
echo 'PASS: simultaneous sessions commit with their own distinct authors.'

# Same SSH key, two independently established shell sessions: swap in one
# should not change the other (session directories are unique).
cat > "$TMP/independent.sh" <<'BASH'
sgh swap default >/dev/null
[[ "$(gh api user --jq .login)" == shared ]]
sgh swap alice >/dev/null
[[ "$(gh api user --jq .login)" == alice ]]
BASH
run_actor alice "$TMP/independent.sh" > "$TMP/independent.out" || fail 'same-identity switching'
run_actor alice "$TMP/status.sh" > "$TMP/alice_still_bound.out"
grep -q '현재 세션 프로필 : alice' "$TMP/alice_still_bound.out" || fail 'independent login selection'
echo 'PASS: independent shells under the same SSH key may select distinct profiles.'

cat > "$TMP/swap.sh" <<'BASH'
sgh swap bob
[[ "$(gh api user --jq .login)" == bob ]]
printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep -q 'username=bob'
sgh swap default
git -C "$TEST_TMP/repos/A" commit --allow-empty -qm shared
[[ "$(gh api user --jq .login)" == shared ]]
[[ "$(gh pr merge 42)" == 'gh-pr-merge-as-shared' ]]
BASH
run_actor alice "$TMP/swap.sh" > "$TMP/swap.out" || { cat "$TMP/alice.stderr"; fail 'swap actions'; }
[[ "$("$REAL_GIT" -C "$TMP/repos/A" log -1 --format='%an <%ae>')" == 'Shared Account <shared@example.com>' ]] || fail 'default author'
echo 'PASS: sgh swap changes only the current shell session; default permits commits and gh merge.'

# Broken personal auth triggers fallback BEFORE mutating git/gh commands.
touch "$HD/.local/share/sgh/profiles/alice/gh/revoked"
cat > "$TMP/fallback.sh" <<'BASH'
sgh status | grep -q '현재 세션 프로필 : default'
# A previously active personal profile can be revoked after login.
rm -f "$SGH_HOME/profiles/alice/gh/revoked"
sgh swap alice
: > "$SGH_HOME/profiles/alice/gh/revoked"
git -C "$TEST_TMP/repos/A" commit --allow-empty -qm fallback
[[ "$(sgh list | grep '^\*' | awk '{print $2}')" == default ]]
[[ "$(gh pr merge 7)" == 'gh-pr-merge-as-shared' ]]
BASH
run_actor alice "$TMP/fallback.sh" > "$TMP/fallback.out" || { cat "$TMP/alice.stderr"; fail 'fallback commit'; }
[[ "$("$REAL_GIT" -C "$TMP/repos/A" log -1 --format='%an <%ae>')" == 'Shared Account <shared@example.com>' ]] || fail 'fallback author'
grep -q 'default로 전환' "$TMP/alice.stderr" || fail 'no fallback warning'
echo 'PASS: invalid personal credentials fall back to fully working default, with visible warning.'

cat > "$TMP/fail_swap.sh" <<'BASH'
if sgh swap nonexistent; then exit 10; fi
[[ "$(sgh list | grep '^\*' | awk '{print $2}')" == default ]]
BASH
run_actor bob "$TMP/fail_swap.sh" > "$TMP/fail_swap.out" || fail 'failed manual swap should select default'
echo 'PASS: unknown profile swap selects default without denying work.'

# A Git operation using GitHub HTTPS routes the credential helper through the
# selected gh config (not the shared account's global Git credential helper).
cat > "$TMP/credential.sh" <<'BASH'
sgh swap bob >/dev/null
printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep -q 'password=token_bob'
BASH
run_actor alice "$TMP/credential.sh" > "$TMP/credential.out" || fail 'HTTPS credential isolation'
echo 'PASS: HTTPS git credential helper selects the per-session GitHub token.'

# A failed OAuth must not create a usable profile or block default operations.
cat > "$TMP/failed_add.sh" <<'BASH'
if sgh add broken; then exit 10; fi
[[ "$(sgh list | grep '^\*' | awk '{print $2}')" == default ]]
git -C "$TEST_TMP/repos/B" commit --allow-empty -qm after_failed_oauth
BASH
run_actor bob "$TMP/failed_add.sh" MOCK_LOGIN=broken MOCK_AUTH_FAIL=1 > "$TMP/failed_add.out" || fail 'failed oauth fallback'
[[ ! -e "$HD/.local/share/sgh/profiles/broken/profile" ]] || fail 'partial profile created after failed auth'
[[ "$("$REAL_GIT" -C "$TMP/repos/B" log -1 --format='%an <%ae>')" == 'Shared Account <shared@example.com>' ]] || fail 'failed oauth must use default author'
echo 'PASS: interrupted/failed OAuth leaves profile unregistered and default remains writable.'

# GHE host must travel through OAuth, profile metadata, gh API, and git credentials.
cat > "$TMP/enterprise.sh" <<'BASH'
printf '\n\n' | sgh add corp https://GHE.corp.example/
[[ "$(sed -n '4p' "$SGH_HOME/profiles/corp/profile")" == ghe.corp.example ]]
[[ "$(sed -n '3p' "$SGH_HOME/profiles/corp/profile")" == engineer@corp.example ]]
[[ "$(cat "$SGH_HOME/profiles/corp/gh/mock_host")" == ghe.corp.example ]]
[[ "$(gh api user --jq .login)" == corpuser ]]
printf 'protocol=https\nhost=ghe.corp.example\n\n' | git credential fill | grep -q 'password=token_corpuser'
[[ "$(git -C "$TEST_TMP/repos/A" config --get-urlmatch credential.helper https://ghe.corp.example)" == '!gh auth git-credential' ]]
sgh swap default
[[ "$(gh api user --jq .login)" == shared ]]
sgh swap corp
[[ "$(gh api user --jq .login)" == corpuser ]]
BASH
run_actor alice "$TMP/enterprise.sh" MOCK_LOGIN=corpuser MOCK_EMAIL=engineer@corp.example > "$TMP/enterprise.out" || { cat "$TMP/alice.stderr"; fail 'GHE host auth and helper'; }
echo 'PASS: GHE hostname used for OAuth, user API, stored metadata and Git HTTPS credential helper.'

# A private GHE email must not silently fall back to users.noreply.github.com.
cat > "$TMP/enterprise-no-email.sh" <<'BASH'
printf '\n\n' | sgh add incomplete https://github.intra
BASH
if run_actor bob "$TMP/enterprise-no-email.sh" MOCK_LOGIN=incomplete > "$TMP/enterprise-no-email.out"; then fail 'GHE email was silently fabricated'; fi
[[ ! -e "$HD/.local/share/sgh/profiles/incomplete/profile" ]] || fail 'invalid empty GHE email registered'
echo 'PASS: GHE registration requires corporate/GHE-linked email when API email is absent.'

# Existing 3-line files remain valid for github.com.
cat > "$TMP/legacy.sh" <<'BASH'
sgh swap alice
[[ "$(gh api user --jq .login)" == alice ]]
BASH
sed -i '4d' "$HD/.local/share/sgh/profiles/alice/profile"
rm -f "$HD/.local/share/sgh/profiles/alice/gh/revoked"
run_actor bob "$TMP/legacy.sh" > "$TMP/legacy.out" || { cat "$TMP/bob.stderr" "$TMP/legacy.out"; fail 'legacy 3-line profile regression'; }
echo 'PASS: legacy 3-line github.com profile remains valid.'

# The shared default can also be an Enterprise host and remains fully writable.
echo github.intra > "$HD/.config/gh/mock_host"
cat > "$TMP/ghe-default.sh" <<'BASH'
sgh init-default https://github.intra/
[[ "$(sed -n '4p' "$SGH_HOME/profiles/default/profile")" == github.intra ]]
sgh swap default
[[ "$(gh api user --jq .login)" == shared ]]
printf 'protocol=https\nhost=github.intra\n\n' | git credential fill | grep -q 'password=token_shared'
BASH
run_actor bob "$TMP/ghe-default.sh" > "$TMP/ghe-default.out" || { cat "$TMP/bob.stderr"; fail 'GHE shared default'; }
echo github.com > "$HD/.config/gh/mock_host"
cat > "$TMP/reset-default.sh" <<'BASH'
sgh init-default github.com
sgh swap default
[[ "$(gh api user --jq .login)" == shared ]]
BASH
run_actor bob "$TMP/reset-default.sh" > "$TMP/reset-default.out" || { cat "$TMP/bob.stderr" "$TMP/reset-default.out"; fail 'reset GitHub.com default'; }
echo 'PASS: enterprise default can commit/push using its host-specific credentials.'

# Guided setup: name + GHE URL + OAuth + default-YES SSH bind.
cat > "$TMP/wizard-yes.sh" <<'BASH'
printf 'wizard-work\nhttps://GHE.team.example/\n\n\n\n' | sgh init
[[ "$(sgh_current)" == wizard-work ]]
[[ "$(sed -n '4p' "$SGH_HOME/profiles/wizard-work/profile")" == ghe.team.example ]]
id="$(sgh_ssh_key_id)"
[[ "$(cat "$SGH_BINDINGS/$id")" == wizard-work ]]
[[ "$(gh api user --jq .login)" == wizarduser ]]
printf 'protocol=https\nhost=ghe.team.example\n\n' | git credential fill | grep -q 'password=token_wizarduser'
BASH
run_actor alice "$TMP/wizard-yes.sh" MOCK_LOGIN=wizarduser MOCK_EMAIL=wizard@team.example > "$TMP/wizard-yes.out" || { cat "$TMP/alice.stderr" "$TMP/wizard-yes.out"; fail 'guided init YES binding'; }
grep -q '초기 설정 완료' "$TMP/wizard-yes.out" || fail 'guided init completion summary'
cat > "$TMP/wizard-yes-verify.sh" <<'BASH'
[[ "$(sgh_current)" == wizard-work ]]
BASH
run_actor alice "$TMP/wizard-yes-verify.sh" > "$TMP/wizard-yes-verify.out" || fail 'guided init binding next SSH login'
echo 'PASS: sgh init guides GHE OAuth and default-YES bind; next session auto-selects the new profile.'

# Choosing n stores a usable profile, but does not change the SSH-key binding.
cat > "$TMP/wizard-no.sh" <<'BASH'
id="$(sgh_ssh_key_id)"
previous="$(cat "$SGH_BINDINGS/$id")"
printf 'manual-only\n\n\n\nn\n' | sgh init
[[ "$(sgh_current)" == manual-only ]]
[[ "$(cat "$SGH_BINDINGS/$id")" == "$previous" ]]
[[ "$(gh api user --jq .login)" == manualuser ]]
BASH
run_actor bob "$TMP/wizard-no.sh" MOCK_LOGIN=manualuser > "$TMP/wizard-no.out" || { cat "$TMP/bob.stderr" "$TMP/wizard-no.out"; fail 'guided init NO binding'; }
cat > "$TMP/wizard-no-verify.sh" <<'BASH'
[[ "$(sgh_current)" == bob ]]
BASH
run_actor bob "$TMP/wizard-no-verify.sh" > "$TMP/wizard-no-verify.out" || fail 'NO binding must leave old SSH mapping unchanged'
echo 'PASS: sgh init with n registers profile without changing the existing SSH key binding.'

# EOF at bind prompt should NEVER be implicitly treated as "yes".
cat > "$TMP/wizard-eof.sh" <<'BASH'
id="$(sgh_ssh_key_id)"
previous="$(cat "$SGH_BINDINGS/$id")"
printf 'no-answer\n\n\n\n' | sgh init
[[ "$(sgh_current)" == no-answer ]]
[[ "$(cat "$SGH_BINDINGS/$id")" == "$previous" ]]
BASH
run_actor bob "$TMP/wizard-eof.sh" MOCK_LOGIN=noanswer > "$TMP/wizard-eof.out" || { cat "$TMP/bob.stderr" "$TMP/wizard-eof.out"; fail 'EOF bind prompt'; }
echo 'PASS: EOF at bind prompt skips binding instead of authorizing it.'

# Auth failure in guided setup must leave the default writable and never bind.
cat > "$TMP/wizard-fail.sh" <<'BASH'
id="$(sgh_ssh_key_id)"
previous="$(cat "$SGH_BINDINGS/$id")"
if printf 'broken-wizard\nhttps://ghe.team.example/\n' | sgh init; then exit 11; fi
[[ "$(sgh_current)" == default ]]
[[ ! -e "$SGH_PROFILES/broken-wizard/profile" ]]
[[ "$(cat "$SGH_BINDINGS/$id")" == "$previous" ]]
git -C "$TEST_TMP/repos/B" commit --allow-empty -qm wizard_fallback
BASH
run_actor bob "$TMP/wizard-fail.sh" MOCK_LOGIN=baduser MOCK_AUTH_FAIL=1 > "$TMP/wizard-fail.out" || { cat "$TMP/bob.stderr"; fail 'guided init auth failure fallback'; }
[[ "$("$REAL_GIT" -C "$TMP/repos/B" log -1 --format='%an <%ae>')" == 'Shared Account <shared@example.com>' ]] || fail 'guided init fallback author'
echo 'PASS: failed sgh init OAuth keeps default writable and does not change SSH key binding.'

# Restore Alice's binding so the existing zsh SSH login regression still applies.
cat > "$TMP/wizard-restore.sh" <<'BASH'
sgh bind alice
BASH
run_actor alice "$TMP/wizard-restore.sh" > "$TMP/wizard-restore.out" || fail 'restore Alice SSH binding after wizard coverage'

# zsh needs to be installed in CI; locally skip if absent.
if command -v zsh >/dev/null; then
  cat > "$TMP/zsh-check.zsh" <<'ZSH'
source "$TEST_APP/lib/session.sh"
[[ "$SGH_ROOT" == "$TEST_APP" ]] || exit 3
[[ "${SGH_SESSION_READY:-}" == 1 ]] || exit 4
[[ "$PATH" == "$TEST_APP/guard-bin:"* ]] || exit 5
source "$TEST_APP/lib/core.sh"
[[ "$SGH_ROOT" == "$TEST_APP" ]] || exit 6
sgh status | grep -q '현재 세션 프로필 : alice'
[[ "$(gh api user --jq .login)" == alice ]]
ZSH
  env HOME="$HD" SGH_HOME="$HD/.local/share/sgh" \
      PATH="$TMP/bin:$PATH" SSH_CONNECTION='1 2 3 4' SSH_USER_AUTH="$TMP/alice.auth" \
      TEST_APP="$APP" TEST_HD="$HD" TEST_TMP="$TMP" \
      zsh -f -ic "source '$TMP/zsh-check.zsh'" > "$TMP/zsh.out" 2> "$TMP/zsh.stderr" || { cat "$TMP/zsh.stderr"; fail 'zsh interactive session'; }
  echo 'PASS: zsh interactive SSH startup loads correct script path and selects SSH-bound GitHub profile.'
else
  echo 'SKIP: zsh binary not installed locally (GitHub Actions installs zsh).'
fi

grep -q 'install_hook "\$USER_HOME/.zshrc"' "$ROOT/scripts/install-dev.sh" || fail '.zshrc hook missing'
echo 'PASS: installer includes .zshrc login hook.'

# Orca IDE managed terminals are detached from SSH. They must initialize a
# fresh context even with neither SSH_CONNECTION nor SSH_USER_AUTH available.
run_orca() {
  local worktree="$1" script="$2"; shift 2
  env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY -u SSH_USER_AUTH \
    -u SGH_CONTEXT -u SGH_SESSION_READY \
    -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    PATH="$TMP/bin:$PATH" HOME="$HD" SGH_HOME="$HD/.local/share/sgh" \
    "$@" bash --noprofile --norc -ic \
    "cd '$worktree'; source '$APP/lib/session.sh'; source '$script'" \
    2>"$TMP/orca.stderr"
}

cat > "$TMP/orca-unbound.sh" <<'BASH'
[[ "${SGH_SESSION_READY:-}" == 1 ]]
[[ -n "${SGH_CONTEXT:-}" && -d "$SGH_CONTEXT" ]]
[[ "$(sgh_current)" == default ]]
[[ "$(gh api user --jq .login)" == shared ]]
sgh status | grep -q 'SSH key ID       : 확인 불가'
BASH
run_orca "$TMP/repos/A" "$TMP/orca-unbound.sh" > "$TMP/orca-unbound.out" || fail 'Orca first session initialization'
! grep -q 'SSH 키 정보가 없어 default 사용' "$TMP/orca.stderr" || fail 'Orca missing SSH info should be quiet'
echo 'PASS: detached Orca terminal initializes correctly and uses the default without SSH-key warning.'

cat > "$TMP/orca-pin-alice.sh" <<'BASH'
sgh bind-worktree alice
[[ "$(sgh_current)" == alice ]]
[[ "$(gh api user --jq .login)" == alice ]]
BASH
run_orca "$TMP/repos/A" "$TMP/orca-pin-alice.sh" > "$TMP/orca-pin-alice.out" || fail 'Orca worktree bind alice'

cat > "$TMP/orca-pin-bob.sh" <<'BASH'
sgh bind-worktree bob
[[ "$(sgh_current)" == bob ]]
BASH
run_orca "$TMP/repos/B" "$TMP/orca-pin-bob.sh" > "$TMP/orca-pin-bob.out" || fail 'Orca worktree bind bob'

cat > "$TMP/orca-reopen-alice.sh" <<'BASH'
[[ "$(sgh_current)" == alice ]]
[[ "$(gh api user --jq .login)" == alice ]]
[[ "$(git var GIT_AUTHOR_IDENT)" == *'alice <'* ]]
BASH
cat > "$TMP/orca-reopen-bob.sh" <<'BASH'
[[ "$(sgh_current)" == bob ]]
[[ "$(gh api user --jq .login)" == bob ]]
BASH
run_orca "$TMP/repos/A" "$TMP/orca-reopen-alice.sh" > "$TMP/orca-reopen-alice.out" &
pa=$!
run_orca "$TMP/repos/B" "$TMP/orca-reopen-bob.sh" > "$TMP/orca-reopen-bob.out" &
pb=$!
wait "$pa" || fail 'Orca reopen Alice'
wait "$pb" || fail 'Orca reopen Bob'
echo 'PASS: separate Orca worktrees restore different profile preferences in simultaneous terminals.'
# A managed IDE server could inherit SGH_CONTEXT from the first SSH shell.
# That environment must never cause independent newly-spawned terminals to
# share the original shell's session-selection file.
mkdir -p "$TMP/stale-orca-context"
printf 'bob\n' > "$TMP/stale-orca-context/active"
cat > "$TMP/orca-inherited.sh" <<'BASH'
[[ "$(sgh_current)" == alice ]]
[[ "$SGH_CONTEXT" != "$TEST_TMP/stale-orca-context" ]]
[[ "$SGH_SESSION_SHELL_PID" == "$BASHPID" ]]
BASH
run_orca "$TMP/repos/A" "$TMP/orca-inherited.sh" \
  SGH_CONTEXT="$TMP/stale-orca-context" SGH_SESSION_READY=1 \
  SGH_SESSION_SHELL_PID=999999 > "$TMP/orca-inherited.out" || fail 'Orca stale inherited session isolation'
echo 'PASS: an Orca managed server cannot make new terminals reuse a stale inherited session context.'


# A real, verified SSH identity is authoritative; another user's worktree
# preference must not override a normal SSH session with an unbound key.
cat > "$TMP/orca-ssh-precedence.sh" <<'BASH'
[[ "$(sgh_current)" == alice ]]
BASH
run_actor alice "$TMP/orca-ssh-precedence.sh" > "$TMP/orca-ssh-precedence.out" || fail 'SSH identity precedence over Orca workspace'
echo 'PASS: authenticated SSH-key binding overrides the worktree preference.'

cat > "$TMP/orca-unbind.sh" <<'BASH'
sgh unbind-worktree
[[ "$(sgh_current)" == default ]]
BASH
run_orca "$TMP/repos/B" "$TMP/orca-unbind.sh" > "$TMP/orca-unbind.out" || fail 'Orca worktree unbind'
run_orca "$TMP/repos/B" "$TMP/orca-unbound.sh" > "$TMP/orca-unbound-again.out" || fail 'Orca unbound subsequent terminal'
echo 'PASS: unbind-worktree restores normal default selection in future detached terminals.'

# Interactive init without SSH identity offers an explicit SECOND confirmation
# before establishing a worktree-wide preference.
"$REAL_GIT" init -q "$TMP/repos/orca-wizard"
cat > "$TMP/orca-wizard.sh" <<'BASH'
printf 'orca-dev\n\n\n\n\nY\ny\n' | sgh init
[[ "$(sgh_current)" == orca-dev ]]
key="$(sgh_worktree_key)"
[[ "$(cat "$SGH_WORKTREE_BINDINGS/$key")" == orca-dev ]]
BASH
run_orca "$TMP/repos/orca-wizard" "$TMP/orca-wizard.sh" MOCK_LOGIN=orca-dev > "$TMP/orca-wizard.out" || { cat "$TMP/orca.stderr" "$TMP/orca-wizard.out"; fail 'Orca wizard worktree binding'; }
grep -q '모든 사용자에게 적용' "$TMP/orca-wizard.out" || fail 'worktree sharing not disclosed in wizard'
echo 'PASS: Orca init requests explicit workspace-wide consent before persistent auto-selection.'

echo 'ALL OFFLINE SGH TESTS PASSED.' 
