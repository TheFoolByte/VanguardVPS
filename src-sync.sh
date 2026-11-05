#!/bin/bash
# VanguardVPS — full backup ⇄ GitHub (9router DB + /root files)
# Dev: TheFoolByte
#
#   src-sync            push now
#   src-sync --watch    loop every SYNC_INTERVAL (default 180)
#   src-sync --restore  pull + apply onto the VPS
#   src-sync --init     create/link private repo
#   src-sync --status
set -u

SRC=/root/src
NINE=/root/.9router
STATE=/var/lib/vanguard
MARK="$STATE/src-repo"
API=https://api.github.com
VANGUARD_CONFIG="${VANGUARD_CONFIG:-/etc/vanguard/config.json}"
cfg() {
  [ -f "$VANGUARD_CONFIG" ] || return 0
  jq -r "$1 | if . == null then empty else tostring end" "$VANGUARD_CONFIG" 2>/dev/null
}
TOKEN="${GITHUB_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN="$(cfg .github_token)"
[ -z "$TOKEN" ] && [ -f /var/lib/vanguard/github-token ] \
    && TOKEN="$(cat /var/lib/vanguard/github-token 2>/dev/null)"
INTERVAL="${SYNC_INTERVAL:-}"
[ -z "$INTERVAL" ] && INTERVAL="$(cfg .sync_interval)"
INTERVAL="${INTERVAL:-180}"
GITHUB_REPO="${GITHUB_REPO:-}"
[ -z "$GITHUB_REPO" ] && GITHUB_REPO="$(cfg .github_repo)"
GITHUB_SYNC_EMAIL="${GITHUB_SYNC_EMAIL:-}"
[ -z "$GITHUB_SYNC_EMAIL" ] && GITHUB_SYNC_EMAIL="$(cfg .github_sync_email)"
GITHUB_SYNC_NAME="${GITHUB_SYNC_NAME:-}"
[ -z "$GITHUB_SYNC_NAME" ] && GITHUB_SYNC_NAME="$(cfg .github_sync_name)"
REPO_OWNER=""
REPO_NAME=""

die()  { echo "src-sync: $*" >&2; exit 1; }
need() { [ -n "$TOKEN" ] || die "GITHUB_TOKEN not set — cannot backup"; }

git_ident() {
  git config --global user.email "${GITHUB_SYNC_EMAIL:-sync@vanguardvps.local}" 2>/dev/null
  git config --global user.name  "${GITHUB_SYNC_NAME:-VanguardVPS Sync}" 2>/dev/null
  git config --global init.defaultBranch main 2>/dev/null
  git config --global push.autoSetupRemote true 2>/dev/null
  cred_setup
}

# Keep the token out of git config: remote URLs stay credential-free and the
# token is handed to git at request time by a helper reading the 600-mode file.
cred_setup() {
  [ -n "$TOKEN" ] || return 0
  mkdir -p "$STATE"
  printf '%s' "$TOKEN" > "$STATE/github-token"
  chmod 600 "$STATE/github-token"
  git config --global credential.helper \
    '!f() { echo username=x-access-token; echo "password=$(cat /var/lib/vanguard/github-token)"; }; f' 2>/dev/null
}

# Strip credentials from a remote URL written by an older release.
clean_remote() {
  local d="$1" u
  u=$(git -C "$d" remote get-url origin 2>/dev/null) || return 0
  case "$u" in
    *@github.com*) git -C "$d" remote set-url origin "$(printf '%s' "$u" | sed -E 's#//[^@]+@#//#')" 2>/dev/null ;;
  esac
}

auto_name() {
  local id="${RAILWAY_PROJECT_ID:-}"
  [ -z "$id" ] && id="$(hostname)"
  echo "$id" | tr -c 'A-Za-z0-9' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-40 \
    | sed 's/-*$//' | sed 's/^/vanguard-vps-src-/'
}

# GITHUB_REPO: empty | name | owner/name | https://github.com/owner/name.git
repo_spec() {
  local spec
  spec="$(echo "${GITHUB_REPO:-}" | tr -d '[:space:]')"
  spec="${spec%.git}"
  spec="${spec#https://github.com/}"
  spec="${spec#http://github.com/}"
  spec="${spec#github.com/}"
  echo "$spec"
}

gh_user() {
  curl -s --max-time 12 -H "Authorization: Bearer $TOKEN" "$API/user" \
    | jq -r '.login // empty' 2>/dev/null
}

repo_exists() {
  local u="$1" n="$2" code
  code=$(curl -s -o /tmp/gh-repo.json -w '%{http_code}' --max-time 12 \
    -H "Authorization: Bearer $TOKEN" "$API/repos/$u/$n" 2>/dev/null)
  case "$code" in
    200) jq -r '.id // empty' /tmp/gh-repo.json 2>/dev/null ;;
    404) return 0 ;;                       # genuinely absent
    *) die "GitHub API $code on $u/$n — check token scope/access" ;;
  esac
}

create_repo() {
  local n="$1" code
  code=$(curl -s -o /tmp/gh-new.json -w '%{http_code}' --max-time 20 -X POST "$API/user/repos" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$n\",\"private\":true,\"description\":\"VanguardVPS full backup — 9router DB + files\",\"auto_init\":false}" 2>/dev/null)
  case "$code" in
    201) jq -r '.id // empty' /tmp/gh-new.json 2>/dev/null ;;
    422) echo "exists" ;;                  # already there
    *) die "cannot create repo $n (HTTP $code) — a fine-grained token cannot create repos; create it on GitHub and set GITHUB_REPO, or use a classic token with 'repo' scope" ;;
  esac
}

remote_url() { echo "https://github.com/$1/$2.git"; }

# Sets REPO_OWNER REPO_NAME. Empty GITHUB_REPO → auto vanguard-vps-src-<id> (create later).
resolve_repo() {
  local spec u
  spec="$(repo_spec)"
  if [ -z "$spec" ] && [ -f "$MARK" ]; then
    spec="$(cat "$MARK")"
    spec="${spec#https://github.com/}"
  fi
  if [ -n "$spec" ]; then
    case "$spec" in
      */*) REPO_OWNER="${spec%%/*}"; REPO_NAME="${spec##*/}" ;;
      *)
        u=$(gh_user); [ -n "$u" ] || return 1
        REPO_OWNER="$u"; REPO_NAME="$spec"
        ;;
    esac
  else
    u=$(gh_user); [ -n "$u" ] || return 1
    REPO_OWNER="$u"
    REPO_NAME="$(auto_name)"
  fi
  mkdir -p "$STATE"
  echo "$REPO_OWNER/$REPO_NAME" > "$MARK"
}

print_repo() {
  local spec
  spec="$(repo_spec)"
  if [ -z "$spec" ]; then
    echo "AUTO:$(auto_name)"
    return 0
  fi
  case "$spec" in
    */*) echo "$spec" ;;
    *) echo "NAME:$spec" ;;
  esac
}

write_gitignore() {
  cat > "$SRC/.gitignore" <<'EOF'
node_modules/
**/.git/
__pycache__/
*.pyc
.cache/
*.log
9router/logs/
EOF
}

# Snapshot live VPS into the git staging tree (does not touch user files in place).
snapshot() {
  mkdir -p "$SRC/9router" "$SRC/files"
  write_gitignore
  if [ -d "$NINE" ]; then
    rsync -a --delete --max-size=90m \
      --exclude 'logs/' --exclude 'db/data.sqlite-wal' --exclude 'db/data.sqlite-shm' \
      "$NINE"/ "$SRC/9router/" 2>/dev/null || true
    if [ -f "$NINE/db/data.sqlite" ] && command -v sqlite3 >/dev/null 2>&1; then
      mkdir -p "$SRC/9router/db"
      sqlite3 "$NINE/db/data.sqlite" ".backup '$SRC/9router/db/data.sqlite'" 2>/dev/null || true
    fi
  fi
  rsync -a --delete --max-size=90m \
    --exclude 'src/' \
    --exclude 'src-hermes/' \
    --exclude '.hermes/' \
    --exclude '.9router/' \
    --exclude '.cache/' \
    --exclude '.npm/' \
    --exclude '.local/' \
    --exclude '.ssh/' \
    --exclude 'node_modules/' \
    /root/ "$SRC/files/" 2>/dev/null || true
}

# Apply staged backup onto the live VPS. Call BEFORE starting 9router.
apply_restore() {
  if [ -d "$SRC/9router" ] && [ -n "$(ls -A "$SRC/9router" 2>/dev/null)" ]; then
    mkdir -p "$NINE"
    rsync -a "$SRC/9router"/ "$NINE"/ 2>/dev/null || true
  fi
  if [ -d "$SRC/files" ] && [ -n "$(ls -A "$SRC/files" 2>/dev/null)" ]; then
    rsync -a "$SRC/files"/ /root/ --exclude src 2>/dev/null || true
  fi
}

do_init() {
  need; git_ident; mkdir -p "$SRC"
  resolve_repo || die "cannot resolve repo (set GITHUB_TOKEN / GITHUB_REPO)"
  local me; me=$(gh_user)
  if [ -z "$(repo_exists "$REPO_OWNER" "$REPO_NAME")" ]; then
    if [ -n "$(repo_spec)" ] && [ "$REPO_OWNER" != "$me" ]; then
      die "repo $REPO_OWNER/$REPO_NAME not found — token cannot access it"
    fi
    create_repo "$REPO_NAME" >/dev/null && echo "created repo $REPO_OWNER/$REPO_NAME" \
      || die "failed to create repo $REPO_OWNER/$REPO_NAME (token scope = repo)"
  else
    echo "repo $REPO_OWNER/$REPO_NAME already exists"
  fi
  if [ ! -d "$SRC/.git" ]; then git -C "$SRC" init -q; fi
  git -C "$SRC" remote set-url origin "$(remote_url "$REPO_OWNER" "$REPO_NAME")" 2>/dev/null \
    || git -C "$SRC" remote add origin "$(remote_url "$REPO_OWNER" "$REPO_NAME")"
  write_gitignore
  echo "$REPO_OWNER/$REPO_NAME"
}

do_restore() {
  need; git_ident
  resolve_repo || die "cannot resolve repo"
  [ -z "$(repo_exists "$REPO_OWNER" "$REPO_NAME")" ] \
    && { echo "no repo $REPO_OWNER/$REPO_NAME yet — skip restore, will create on first backup"; return 0; }
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" remote set-url origin "$(remote_url "$REPO_OWNER" "$REPO_NAME")"
    git -C "$SRC" pull --rebase --autostash 2>/dev/null \
      || echo "src-sync: restore pull failed" >&2
  elif [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
    git clone "$(remote_url "$REPO_OWNER" "$REPO_NAME")" "$SRC" 2>&1 | tail -2
  else
    mv "$SRC" "${SRC}.local"
    git clone "$(remote_url "$REPO_OWNER" "$REPO_NAME")" "$SRC" 2>&1 | tail -2
    cp -a "${SRC}.local"/. "$SRC"/ 2>/dev/null; rm -rf "${SRC}.local"
  fi
  apply_restore
}

do_push() {
  need
  [ -d "$SRC/.git" ] || do_init >/dev/null
  git_ident
  clean_remote "$SRC"
  snapshot
  git -C "$SRC" add -A
  git -C "$SRC" diff --cached --quiet && { echo "backup: nothing to sync"; return 0; }
  git -C "$SRC" commit -q -m "auto-backup $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null
  git -C "$SRC" pull --rebase --autostash 2>/dev/null || true
  local out
  out=$(git -C "$SRC" push -u origin HEAD 2>&1)
  case "$out" in
    *"rejected"*|*"non-fast-forward"*)
      # A redeploy can overlap the outgoing container, leaving the backup repo
      # diverged. The staged tree is the snapshot we want, so it wins.
      git -C "$SRC" fetch -q origin 2>/dev/null || true
      out=$(git -C "$SRC" push --force-with-lease -u origin HEAD 2>&1)
      case "$out" in
        *"fatal"*|*"error:"*|*"denied"*|*"not found"*)
          echo "src-sync: PUSH FAILED — $out" >&2; return 1 ;;
      esac
      echo "src-sync: diverged history — snapshot force-pushed" >&2 ;;
    *"fatal"*|*"error:"*|*"denied"*|*"not found"*)
      echo "src-sync: PUSH FAILED — $out" >&2; return 1 ;;
  esac
}

do_watch() {
  need
  echo "src-sync: watching 9router DB + /root every ${INTERVAL}s"
  while true; do
    out=$(do_push 2>&1) || printf '%s\n' "$out"
    sleep "$INTERVAL"
  done
}

do_status() {
  need
  resolve_repo || die "cannot resolve repo"
  echo "Backup: 9router DB + /root files (restore at launch, then push-only)"
  echo "Stage:  $SRC"
  echo "Repo:   $REPO_OWNER/$REPO_NAME"
  echo "Remote: $(git -C "$SRC" remote get-url origin 2>/dev/null || echo '(not linked)')"
  echo "Last:   $(git -C "$SRC" log -1 --format='%h %cr %s' 2>/dev/null || echo '(no commits)')"
}

case "${1:-push}" in
  --init)    do_init ;;
  --restore|restore) do_restore ;;
  --watch)   do_watch ;;
  --status)  do_status ;;
  --print-repo) print_repo ;;
  push|--push|backup) do_push ;;
  *) echo "usage: src-sync [backup|restore|--init|--restore|--watch|--status|--print-repo|push]"; exit 1 ;;
esac
