# shared-gh (`sgh`)

**여러 사람이 동일한 Linux 개발 계정으로 로그인하는 환경에서 GitHub 계정을 세션 단위로 선택하는 Bash 기반 CLI. 접속 셸은 bash/zsh를 지원합니다.**

- **접속 서버(Bastion):** 사람마다 다른 Linux 계정과 SSH 키를 사용
- **개발 서버:** 동일한 Linux 계정(예: `shared`), Git 저장소·Claude Code 등 개발 환경 공유
- **`default`:** 기존 공용 GitHub 계정. **commit / push / merge / `gh pr merge` 모두 정상 사용 가능**
- **개인 계정:** `sgh add <이름>`으로 미리 등록하고 `sgh swap <이름>`으로 전환
- **자동 선택:** `sgh bind <이름>`으로 개발 서버 접속에 사용된 SSH 공개키와 프로필을 연결
- **자동 복귀:** 개인 인증이 실패하면 **현재 세션을 `default`로 바꾸고 원래 명령을 실행**. 공용 계정의 별도 GitHub 권한 정책이 적용됨

> **중요한 한계:** 같은 Linux UID에서는 토큰/파일/프로세스를 안전하게 격리할 수 없습니다. 다른 사용자가 토큰에 접근하거나 명령 래퍼를 우회할 수 있습니다. `sgh`는 **일반적인 작업에서 계정 혼동을 줄이는 편의 도구**이며 보안 경계, 접근통제, 감사 인증 수단이 아닙니다. 개인 토큰을 공동 UID에 저장해도 되는지 조직 정책을 먼저 확인하세요.

## 사용 모습

```bash
ssh dev-shared

sgh list
# * default      shared-org-bot
#   alice        alice-github
#   bob          bob-github

sgh swap alice
# [sgh] 현재 세션: alice (GitHub: alice-github)
git commit -m 'feature'     # Alice 작성자
git push                    # Alice GitHub 권한 (HTTPS remote)
gh pr merge 123             # Alice GitHub 권한

sgh swap default
# [sgh] 현재 세션: default (commit / push / merge 허용)
git commit -m 'maintenance' # 기존 공용 Git 작성자
git push                    # 기존 공용 GitHub 권한
gh pr merge 124             # 기존 공용 GitHub 권한
```

개인 계정의 인증이 만료되거나 서로 다른 계정으로 로그인된 경우:

```bash
$ sgh swap alice
[sgh] alice 인증 실패/프로필 없음. default로 복귀합니다.

$ git commit -m 'fix'
# default의 커밋 작성자로 정상 실행
```

이미 `alice`로 선택되어 있더라도 다음 Git **변경** 명령이나 `gh` 명령 실행 전에 검증에 실패하면:

```text
[sgh] alice 프로필 인증 실패/불일치. 현재 세션을 default로 전환합니다.
```

이후 **원래 명령을 단 한 번만** `default`로 실행합니다. **이미 실행한 push/merge가 실패한 경우**에는 중복 실행을 방지하기 위해 자동 재시도하지 않습니다. `sgh status`로 실제 계정을 확인하세요.

## 설치 요구 사항

- 개발 서버: Linux, bash 또는 zsh 로그인 셸 (CLI 자체는 Bash), OpenSSH server (`ExposeAuthInfo yes`), `git`, GitHub CLI `gh`, `ssh-keygen`, `flock`, `sha256sum`, `timeout`, `mktemp`.
- 접속 서버: 개인 Linux 계정, 개인별 **접속 서버 → 개발 서버** SSH 개인키(서로 달라야 함).
- 개인 GitHub 계정 인증을 Git push에도 적용하려면 원격 URL은 **HTTPS** (`https://github.com/ORG/REPO.git`)여야 함. `git@github.com:ORG/REPO.git`은 GitHub SSH 인증을 사용하므로 sgh의 GitHub CLI 계정 전환과 무관함.
- 관리자는 개발 서버 root 권한, 공용 계정 shell 초기화 파일 변경 권한, `authorized_keys` 수정 권한이 있어야 함.

> Bastion에 처음 들어올 때 쓴 SSH 키가 아니라 **Bastion에서 개발 서버에 접속할 때 사용한 키**로 사용자를 식별합니다. 개발 서버 인증키까지 동일하게 공유하면 자동 구분할 수 없습니다.

## 1. 관리자: 개발 서버에 설치

```bash
git clone https://github.com/mireiffe/shared-gh.git
cd shared-gh
sudo bash scripts/install-dev.sh shared

# SSH 접속을 하나 유지한 상태에서 확인 후 reload
sudo sshd -t
sudo sshd -T -C user=shared,host=localhost,addr=127.0.0.1 | grep -i exposeauthinfo
sudo systemctl reload ssh   # 배포판에 따라 sshd
```

**저장소를 clone하지 않고 설치** (공개 GitHub 저장소, 검토한 커밋/태그 고정 권장):

```bash
bash -c '
  set -euo pipefail
  tmp=$(mktemp -d)
  trap '\''rm -rf "$tmp"'\'' EXIT
  curl -fsSL https://github.com/mireiffe/shared-gh/archive/refs/heads/main.tar.gz \
    | tar -xz -C "$tmp" --strip-components=1
  sudo bash "$tmp/scripts/install-dev.sh" shared
'
```

이 명령은 **소스 tarball을 임시 폴더로 받는 방식**이지, 코드가 전혀 내려오지 않는 설치는 아닙니다. `git config` 명령 하나만으로 서버 로그인 훅과 인증 프로필 분리를 설치할 수는 없습니다. 운영 서버에서는 검증한 커밋 SHA / 릴리스 태그와 체크섬을 고정하세요.

설치 스크립트가 수행하는 작업:

1. `/opt/sgh`에 관리자 소유 스크립트, 실제 Git/gh 바이너리 링크, `git`/`gh` 래퍼 설치.
2. `/usr/local/bin/sgh` 명령 등록.
3. 공용 Linux 계정의 로그인 셸에 따라 Bash는 `.bashrc`와 `.bash_profile`/`.profile`, zsh는 **`.zshrc`** 에 대화형 SSH용 훅을 설치합니다.
4. `/etc/ssh/sshd_config` 백업 후 `ExposeAuthInfo yes` 적용 및 `sshd -t` 검증. **SSH 서비스를 자동 재시작하지는 않습니다.**
5. 이전 `shared-gh-bootstrap` 실험용 로그인 훅이 있으면 백업 후 교체. **기존 인증/토큰을 삭제하거나 자동 변환하지는 않습니다.**

### 1-1. default: 기존 공용 계정 연결

기존 공용 Linux 계정의 `~/.config/gh`와 `~/.gitconfig`를 계속 사용합니다. 이미 `gh`와 Git이 설정되어 있다면 기존 권한이 유지됩니다. **관리자가 공용 계정의 SSH 셸에서**:

```bash
sgh init-default                  # github.com 기본 인증
# sgh init-default github.corp.example  # GHE 공용 기본 인증인 경우
sgh status
```

기존 공용 `gh` 인증이 있으면 로그인된 사용자 정보를 읽고, Git 작성자 이름/이메일을 프로필에 기록합니다. 인증이 없으면 공용 GitHub 로그인을 요청합니다. 개인 프로필처럼 `default`의 GitHub 토큰을 따로 복사하지 않습니다. `default` 프로필 등록 전에도 기존 Git/gh 환경은 사용 가능하지만, 프로필 등록으로 작성자를 고정해 두는 것을 권장합니다.

**주의:** `GH_TOKEN`/`GITHUB_TOKEN`으로만 공용 인증을 제공하던 환경은 sgh가 환경 토큰을 해제하므로 그대로 이어지지 않습니다. 공용 계정에 `gh auth login`으로 로그인해 두거나 설치 전에 별도 인증 방식을 설계해야 합니다.

## 2. 접속 서버: 개인별 SSH 키 준비

각자의 Bastion Linux 계정에서 다음 중 하나를 실행합니다. SSH 키는 이미 별도로 발급돼 있다면 그대로 사용할 수 있습니다.

```bash
# 저장소를 받아온 경우
bash scripts/setup-bastion.sh dev.internal shared dev-shared

# 별도 스크립트 없이 직접 구성하는 경우
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_sgh_dev
cat >> ~/.ssh/config <<'SSH'
Host dev-shared
  HostName dev.internal
  User shared
  IdentityFile ~/.ssh/id_ed25519_sgh_dev
  IdentitiesOnly yes
SSH
chmod 600 ~/.ssh/config
cat ~/.ssh/id_ed25519_sgh_dev.pub
```

관리자는 **각 사용자 공개키만** 공용 개발 계정의 `~/.ssh/authorized_keys`에 등록합니다. 비공개키를 서버·저장소·관리자에게 보내면 안 됩니다.

## 3. 사용자: GitHub 프로필 등록 및 SSH 자동 연결

```bash
ssh dev-shared

# 1회: OAuth Device Flow + Git 작성자 이름/이메일
sgh add alice                     # github.com (공용 default의 호스트가 github.com일 때)
# sgh add alice github.corp.example  # GitHub Enterprise Server
# sgh add alice https://github.corp.example/  # URL 입력도 허용, 호스트로 정규화

# 그 SSH 키로 접속할 때 alice가 자동 선택되도록 연결
sgh bind alice

# 다음 접속부터는 자동으로 alice 선택
sgh list
sgh status
```

`gh auth login`은 사용자가 브라우저에서 GitHub 로그인·승인을 직접 해야 합니다. 로그인된 계정이 확인된 후 Git 작성자 이름과 이메일을 저장합니다. GitHub.com에서는 등록된 이메일 또는 본인 noreply 주소를 사용할 수 있습니다. **GHE는 GitHub.com의 noreply 주소를 생성하지 않으며**, GHE API가 반환한 이메일이 있으면 이를 제안하고, 없으면 사용자가 사내/GHE 등록 이메일을 반드시 입력해야 합니다. 모든 인증정보는 개발 서버 공용 Linux 계정 홈 아래에 저장되며 **Git 저장소에는 저장되지 않습니다**.

다른 프로필도 등록할 수 있습니다:

```bash
sgh add bob
sgh swap bob
sgh swap alice
sgh swap default
sgh reauth alice
sgh unbind              # 현재 SSH 키 자동 연결 해제
sgh bind default        # 해당 SSH 키는 항상 공용 default로 시작
```

`sgh swap`은 **부모 Bash 셸의 환경변수를 바꾸지 않아도 동작**합니다. SSH 로그인 시 만든 고유한 세션 컨텍스트 파일에 현재 선택을 기록하고, PATH 앞에 배치한 Git/gh 래퍼가 **매 명령 실행 시** 이 파일을 읽기 때문입니다. 다른 SSH 세션의 선택 상태는 바뀌지 않습니다. Claude Code를 이 셸에서 실행하면 일반적인 `git`/`gh` 호출에 같은 래퍼가 적용됩니다.

## 명령어

| 명령어 | 설명 |
|---|---|
| `sgh list` | 등록된 프로필과 현재 세션 선택 |
| `sgh add NAME [HOST]` | 개인 프로필 등록, HOST 생략 시 default 호스트를 사용 (동일 이름 중복 불가) |
| `sgh swap NAME` | 현재 SSH 세션의 프로필 전환 (`default` 포함) |
| `sgh bind NAME` | 서버가 인증한 SSH 키와 프로필을 매핑하고 현재 세션에도 적용 |
| `sgh unbind` | SSH 키 자동 연결 해제, 현재 세션 default 전환 |
| `sgh reauth NAME` | 해당 프로필을 동일 GitHub 계정으로 다시 인증 |
| `sgh status` | 현재 선택, SSH 키 매핑, Git 작성자, 실시간 GitHub 로그인 확인 |
| `sgh init-default [HOST]` | 공용 기본 GitHub 인증과 커밋 작성자·호스트 등록 |

## GitHub Enterprise Server 설정

`HOST`에는 `github.corp.example`과 같은 **호스트 이름**을 지정합니다. `https://github.corp.example/`도 허용하고 내부적으로 호스트만 저장합니다. `gh auth login --hostname`에는 URL 전체가 아닌 호스트를 전달합니다.

```bash
# 공용 default가 GHE를 사용한다면 관리자가 1회 설정
sgh init-default github.corp.example

# 개인 프로필은 공용 default의 호스트를 상속하거나 직접 지정
sgh add alice                         # default 호스트 사용
sgh add bob github.corp.example
sgh swap bob

# GH_HOST, GH_CONFIG_DIR 및 git credential helper가 모두 지정 호스트를 사용
sgh status
printf 'protocol=https\nhost=github.corp.example\n\n' | git credential fill | sed -n '/^username=/p'  # 비밀번호 출력 방지
```

Git 원격 주소는 `https://github.corp.example/ORG/REPO.git`이어야 합니다. `git@github.corp.example:ORG/REPO.git`처럼 SSH 원격을 쓰면 GitHub CLI 토큰이 아닌 SSH 키로 인증하므로 `sgh`의 HTTPS credential helper가 적용되지 않습니다.

프로필 메타데이터는 로그인·이름·이메일·호스트의 **4줄**이며, 종전 **3줄** 프로필은 `github.com`으로 해석해 계속 지원합니다. 계정별 `GH_HOST`, `GH_CONFIG_DIR` 설정과 `credential.https://<HOST>.helper`를 동일한 호스트로 맞춥니다.

## 동시 사용, 실패, 미등록 정책

| 상황 | 동작 |
|---|---|
| Alice, Bob 동시 SSH 접속 | 각 SSH 세션의 전환 상태 독립, 서로 다른 인증 선택 가능 |
| 같은 사용자의 터미널 2개 | 서로 다른 프로필로 `sgh swap` 가능 |
| 동일한 프로필을 두 사람이 동시에 등록/재인증 | `flock`으로 중복 등록 방지 |
| 사용자가 개인 프로필 등록 없이 접속 | **default 사용 가능** — Git/gh 작업 모두 허용 |
| 개인 OAuth 등록 취소/중단 | 최종 프로필이 생성되지 않음; 현재 세션은 **default** |
| `sgh swap`에 없는 이름 입력 | **default**로 전환, 명령은 오류 코드 반환 |
| 개인 GitHub 토큰 만료·오류·계정 불일치 | 자동으로 **default** 전환 후 원래 명령 1회 실행, 경고 출력 |
| default GitHub 인증 실패 | GitHub 작업은 기존 Git/gh의 인증 오류를 출력. `git commit` 같은 로컬 작업은 default 작성자로 계속 실행 가능 |
| GitHub API/네트워크 일시 장애 | 개인 프로필 검증 실패로 판단하여 default 전환 (전환 사실 출력) |

`git` 명령 중 조회성 명령은 네트워크 검증 없이 빠르게 실행하고, 변경성 명령은 개인 프로필 검증을 수행합니다. `gh` 명령은 일반적으로 검증을 거칩니다. 검증은 프로필 호스트(`GH_HOST`)의 현재 로그인 신원(`gh api user`)을 확인하는 것으로 **특정 저장소 권한까지 보장하지 않습니다**.

### 테스트

```bash
bash -n bin/sgh lib/*.sh guard-bin/* scripts/*.sh tests/*.sh
bash tests/test_sgh.sh
```

네트워크 없이 모의 `gh`와 2개 SSH 공개키를 사용해 다음을 검사합니다: 공용 계정 유지, SSH 자동 선택, 여러 세션 동시 실행, Git 커밋 작성자, `git credential fill` 계정별 반환, `gh pr merge`, 수동 swap, 토큰 철회 시 default 복귀, 로그인 실패 후 default 사용, **GHE hostname OAuth/credential helper/이메일**, 구형 프로필 호환, zsh 설치 시 zsh 시작 셸. **실제 서버 OpenSSH 로그인의 완전한 동작과 GitHub OAuth 성공까지 입증하는 테스트는 아닙니다.** 설치 전 테스트 서버에서 검증하세요.

## 운영 주의사항

- **공유 Linux UID ≠ 사용자별 보안 경계.** 모든 프로필 토큰은 같은 UID의 다른 사용자/Agent에게 읽힐 수 있습니다. OS 계정 또는 컨테이너 격리 없이는 해결할 수 없습니다.
- 개인 프로필은 `gh auth login --insecure-storage`를 사용해 프로필별 디렉터리에 저장합니다. GitHub CLI 키링의 전역 계정 상태를 공유하지 않기 위한 선택이며, **토큰은 평문으로 저장됩니다**.
- PATH 래퍼는 실수 방지 수단입니다. 절대경로 `/usr/bin/git`, 다른 credential helper, URL 내 토큰, SSH remote, 프로세스 환경변수 조작 등으로 우회할 수 있습니다.
- **대화형 SSH Bash/zsh 셸을 대상으로 설치**합니다. `ssh host 'git push'`, cron, systemd, VS Code의 별도 서버/터미널, 기존 tmux 서버, SFTP 등은 로그인 훅을 거치지 않을 수 있습니다.
- GitHub/GHE HTTPS remote에 한해 **프로필에 저장된 호스트**의 `credential.https://HOST.helper`를 런타임에 구성하고, 계정별 `gh auth git-credential`을 사용합니다. 기존 외부 Git credential-helper 설정을 Git 명령 환경에서 우선순위 재설정합니다.
- Git 커밋 Author/Committer를 명시적으로 맞추지만, 이미 생성된 커밋의 작성자는 변경되지 않습니다. GitHub 웹의 PR merge 행위자는 실제 API 인증 계정에 따라 기록됩니다.
- 같은 `.git/index`/working tree에 여러 Coding Agent가 동시에 변경을 가하면 파일 충돌은 별도 발생합니다. **사용자별 `git worktree`**를 권장합니다.
- 개인 인증의 `gh api user` 확인에 네트워크가 필요하며 타임아웃(기본 8초)이 있습니다. 연결 실패 시 자동으로 default가 선택됩니다. **돌아갈 때마다 경고가 표시되므로 의도치 않은 default 귀속 여부를 확인**하세요.
- default 권한은 GitHub에서 별도로 제한·관리해야 합니다. sgh 자체에는 권한 정책이 없습니다.

## 공식 문서

- GitHub CLI 환경변수: https://cli.github.com/manual/gh_help_environment
- GitHub CLI 계정 관리: https://cli.github.com/manual/gh_auth_login
- Git credential helpers: https://git-scm.com/docs/gitcredentials
- OpenSSH `ExposeAuthInfo`: https://man.openbsd.org/sshd_config
