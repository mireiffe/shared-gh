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
    mkdir -p "$GH_CONFIG_DIR"
    printf '%s\n' "${MOCK_LOGIN:-shared}" > "$GH_CONFIG_DIR/mock_login"
    ;;
  'api user')
    [[ -e "$GH_CONFIG_DIR/revoked" ]] && exit 1
    [[ -r "$GH_CONFIG_DIR/mock_login" ]] || exit 1
    case "${4:-}" in
      .login) cat "$GH_CONFIG_DIR/mock_login";;
      .id) echo 123;;
      '.name // .login') cat "$GH_CONFIG_DIR/mock_login";;
      *) exit 3;;
    esac
    ;;
  'auth git-credential')
    [[ "${3:-}" == get ]] || exit 0
    name="$(cat "$GH_CONFIG_DIR/mock_login")"
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

echo 'ALL OFFLINE SGH TESTS PASSED.'
