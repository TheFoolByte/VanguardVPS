#!/bin/bash
# Fails if VanguardVPS rebrand or default password regresses.
set -e
fail() { echo "FAIL: $1"; exit 1; }

grep -q '"root_password"' config.json || fail "config.json missing root_password"
grep -q '"github_token"' config.json || fail "config.json missing github_token"
grep -q '"github_repo"' config.json || fail "config.json missing github_repo"
grep -q '/etc/vanguard/config.json' ssh-user-config.sh || fail "boot does not load config.json"
grep -q 'config.json' Dockerfile || fail "Dockerfile does not copy config.json"
grep -q 'config.json' railway.json || fail "railway.json does not watch config.json"
! grep -q 'ROOT_PASSWORD is required' ssh-user-config.sh || fail "password still mandatory"

grep -q 'VanguardVPS' vanguard-welcome.sh || fail "welcome brand"
grep -q 'TheFoolByte' vanguard-welcome.sh || fail "dev name"
grep -q 'VanguardVPS' railway-template.json || fail "template name"
grep -q 'vanguard-welcome.sh' Dockerfile || fail "welcome copy path"
grep -q 'vanguard-vps-src-' src-sync.sh || fail "src-sync prefix"
grep -q 'vanguard-vps-hermes-' hermes-sync.sh || fail "hermes-sync prefix"
grep -q '/var/lib/vanguard' ssh-user-config.sh || fail "state dir"
grep -q 'setup_lts.x' Dockerfile || fail "node not LTS"
grep -q 'npm install -g.*9router' Dockerfile || fail "9router not installed"
test -f static/favicon.svg || fail "favicon svg missing"
test -f static/favicon.ico || fail "favicon ico missing"
test -f static/patch-favicon.py || fail "favicon patch script missing"
! grep -q '<text' static/favicon.svg || fail "favicon uses text (Chrome skips it)"
grep -q 'favicon.svg' Dockerfile || fail "Dockerfile does not install favicon"
grep -q 'patch-favicon.py' Dockerfile || fail "Dockerfile does not run favicon patch"
grep -q 'sqlite3' src-sync.sh || fail "9router sqlite backup missing"
grep -q 'src-sync --restore' ssh-user-config.sh || fail "restore-before-9router missing"
grep -q '"hostname": "0.0.0.0"' config.json || fail "9router not bound public"
grep -q 'GITHUB_REPO' src-sync.sh || fail "GITHUB_REPO not in src-sync"
grep -q 'GITHUB_REPO' railway-template.json || fail "GITHUB_REPO not in template"
# pasted repo (url / owner/name) is used as-is; empty = auto vanguard-vps-src-*
got=$(GITHUB_REPO='https://github.com/thefoolbyte/my-src.git' bash src-sync.sh --print-repo) || fail "print-repo failed"
[ "$got" = "thefoolbyte/my-src" ] || fail "print-repo url parse got $got"
got=$(GITHUB_REPO='thefoolbyte/my-src' bash src-sync.sh --print-repo) || fail "print-repo name failed"
[ "$got" = "thefoolbyte/my-src" ] || fail "print-repo owner/name got $got"
got=$(GITHUB_REPO='' bash src-sync.sh --print-repo) || fail "print-repo auto failed"
echo "$got" | grep -q '^AUTO:vanguard-vps-src-' || fail "empty repo should auto-create, got $got"
! test -f cl || fail "cl still exists"
! test -f claude-settings.json || fail "claude-settings still exists"
! grep -q '@anthropic-ai/claude-code' Dockerfile || fail "claude-code still in image"
! grep -q 'ANTHROPIC_' ssh-user-config.sh Dockerfile railway-template.json || fail "ANTHROPIC leftover"

if grep -R --exclude-dir=.git --exclude='test_rebrand.sh' -E 'XD VPS|KurrXd|xd-welcome|xd-vps|/var/lib/xd|/etc/xd' .; then
  fail "old brand leftovers"
fi

# CRLF shebang makes Linux exec fail: "No such file or directory"
for f in ssh-user-config.sh src-sync.sh hermes-sync.sh vanguard-welcome.sh usage Dockerfile; do
  grep -q $'\r' "$f" && fail "$f has CRLF"
done

echo OK
