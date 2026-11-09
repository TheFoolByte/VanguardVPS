#!/bin/bash
# VanguardVPS — private GitHub backup (9Router JSON + /root files)
# Dev: TheFoolByte
#
#   src-sync            push now
#   src-sync --watch    loop every SYNC_INTERVAL (default 180)
#   src-sync --restore  pull backup and queue JSON restore on a fresh data dir
#   src-sync --init     create/link a private repo
#   src-sync --status
#   --init-identity / --restore-json are boot-only helpers
set -u
umask 077

SRC="${VANGUARD_SRC_DIR:-/root/src}"
ROOT_FILES="${VANGUARD_ROOT_FILES_DIR:-/root}"
NINE="${NINE_DIR:-${DATA_DIR:-/root/.9router}}"
STATE="${VANGUARD_STATE_DIR:-/var/lib/vanguard}"
NINE_PORT="${NINE_PORT:-${PORT:-20128}}"
MARK="$STATE/src-repo"
PENDING_JSON="$STATE/9router-restore.json"
API=https://api.github.com
VANGUARD_CONFIG="${VANGUARD_CONFIG:-/etc/vanguard/config.json}"
cfg() {
  [ -f "$VANGUARD_CONFIG" ] || return 0
  jq -r "$1 | if . == null then empty else tostring end" "$VANGUARD_CONFIG" 2>/dev/null
}
TOKEN="${GITHUB_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN="$(cfg .github_token)"
[ -z "$TOKEN" ] && [ -f "$STATE/github-token" ] \
    && TOKEN="$(cat "$STATE/github-token" 2>/dev/null)"
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

cli_token() {
  node -e 'const fs=require("fs"),c=require("crypto");const [m,s]=process.argv.slice(1).map(f=>fs.readFileSync(f,"utf8").trim());if(!m||!s)process.exit(1);process.stdout.write(c.createHash("sha256").update(m+"9r-cli-auth"+s).digest("hex").slice(0,16))' \
    "$NINE/machine-id" "$NINE/auth/cli-secret" 2>/dev/null
}

ensure_identity_file() {
  local path="$1" tmp="${1}.tmp.$$"
  if [ -s "$path" ]; then chmod 600 "$path"; return; fi
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex")+String.fromCharCode(10))' > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
}

ensure_cli_identity() {
  command -v node >/dev/null 2>&1 || die "node is required to initialize 9Router CLI auth"
  mkdir -p "$NINE/auth" || die "cannot create 9Router auth directory"
  ensure_identity_file "$NINE/machine-id" || die "cannot initialize 9Router machine identity"
  ensure_identity_file "$NINE/auth/cli-secret" || die "cannot initialize 9Router CLI secret"
}

valid_json_export() {
  jq -e 'type == "object" and (.apiKeys|type == "array") and (.combos|type == "array") and (.customModels|type == "array") and (.mitmAlias|type == "object") and (.modelAliases|type == "object") and (.pricing|type == "object") and (.providerConnections|type == "array") and (.providerNodes|type == "array") and (.proxyPools|type == "array") and (.settings|type == "object")' \
    "$1" >/dev/null 2>&1
}

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
    "!f() { echo username=x-access-token; echo \"password=\$(cat '$STATE/github-token')\"; }; f" 2>/dev/null
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
  local u="$1" n="$2" code response="$STATE/gh-repo.json"
  mkdir -p "$STATE"
  code=$(curl -s -o "$response" -w '%{http_code}' --max-time 12 \
    -H "Authorization: Bearer $TOKEN" "$API/repos/$u/$n" 2>/dev/null)
  case "$code" in
    200)
      jq -e '.private == true and (.id != null)' "$response" >/dev/null 2>&1 || {
        echo "src-sync: backup repo must be private; refusing to expose provider credentials" >&2
        return 1
      }
      jq -r '.id // empty' "$response" 2>/dev/null ;;
    404) return 0 ;;                       # genuinely absent
    *) die "GitHub API $code on $u/$n — check token scope/access" ;;
  esac
}

create_repo() {
  local n="$1" code
  code=$(curl -s -o /tmp/gh-new.json -w '%{http_code}' --max-time 20 -X POST "$API/user/repos" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$n\",\"private\":true,\"description\":\"VanguardVPS 9Router JSON + files backup\",\"auto_init\":false}" 2>/dev/null)
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
/9router/
EOF
}

# The official JSON export is the only 9Router data copied to GitHub.
snapshot() {
  local json_tmp="$SRC/.backup-export.json.tmp.$$"
  local json_backup="$SRC/9router-backup.json"
  local token code nine_relative
  local exclude_nine=()
  mkdir -p "$SRC/files" "$STATE" || { echo "src-sync: cannot create backup staging paths" >&2; return 1; }
  write_gitignore || { echo "src-sync: cannot write backup .gitignore" >&2; return 1; }
  token=$(cli_token) || { echo "src-sync: cannot derive 9Router CLI token" >&2; return 1; }
  code=$(curl -sS --max-time 30 -o "$json_tmp" -w '%{http_code}' \
    -H "x-9r-cli-token: $token" "http://127.0.0.1:$NINE_PORT/api/settings/database" 2>/dev/null) || code=000
  if [ "$code" != 200 ] || ! valid_json_export "$json_tmp"; then
    rm -f -- "$json_tmp"
    echo "src-sync: official JSON export failed (HTTP $code or invalid schema); refusing incomplete snapshot" >&2
    return 1
  fi
  chmod 600 "$json_tmp" && mv -f -- "$json_tmp" "$json_backup" || {
    rm -f -- "$json_tmp"
    echo "src-sync: cannot install JSON backup" >&2; return 1;
  }
  git -C "$SRC" rm -r -f --cached --ignore-unmatch -- 9router >/dev/null 2>&1 || {
    echo "src-sync: cannot untrack legacy 9Router file backup" >&2; return 1;
  }
  case "$NINE/" in
    "$ROOT_FILES"/*) nine_relative="${NINE#"$ROOT_FILES"/}"; exclude_nine=(--exclude "/$nine_relative/") ;;
  esac
  rsync -a --delete --max-size=90m \
    --exclude 'src/' \
    --exclude 'src-hermes/' \
    --exclude '.hermes/' \
    --exclude '.9router/' \
    "${exclude_nine[@]}" \
    --exclude '.cache/' \
    --exclude '.npm/' \
    --exclude '.local/' \
    --exclude '.ssh/' \
    --exclude 'node_modules/' \
    "$ROOT_FILES"/ "$SRC/files/" || { echo "src-sync: /root files snapshot rsync failed" >&2; return 1; }
}

# Apply the JSON only to a fresh data directory; never replace an existing DB.
apply_restore() {
  local safety="$STATE/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$STATE"
  if [ ! -f "$PENDING_JSON" ] && [ -f "$SRC/9router-backup.json" ]; then
    if ! valid_json_export "$SRC/9router-backup.json"; then
      if [ ! -f "$NINE/db/data.sqlite" ]; then
        echo "src-sync: JSON backup is invalid and no live database exists; refusing restore" >&2; return 1
      fi
      echo "src-sync: JSON backup is invalid; preserving existing live database" >&2
    elif [ -f "$NINE/db/data.sqlite" ]; then
      echo "src-sync: existing 9Router database found; preserving it instead of applying backup JSON"
    else
      local pending_tmp="$STATE/.9router-restore-$$.tmp"
      cp -- "$SRC/9router-backup.json" "$pending_tmp" \
        && chmod 600 "$pending_tmp" \
        && mv -f -- "$pending_tmp" "$PENDING_JSON" || {
          rm -f -- "$pending_tmp"
          echo "src-sync: cannot queue JSON restore" >&2; return 1;
        }
      echo "src-sync: queued JSON restore for first 9Router startup"
    fi
  elif [ ! -f "$PENDING_JSON" ] && [ ! -f "$NINE/db/data.sqlite" ] \
      && [ -d "$SRC/9router" ] && [ -n "$(ls -A "$SRC/9router" 2>/dev/null)" ]; then
    echo "src-sync: legacy backup has no JSON export; refusing raw SQLite restore" >&2
    return 1
  fi
  if [ -d "$SRC/files" ] && [ -n "$(ls -A "$SRC/files" 2>/dev/null)" ]; then
    mkdir -p "$safety/files"
    rsync -a --exclude src --exclude src-hermes "$ROOT_FILES"/ "$safety/files/" \
      || { echo "src-sync: cannot preserve current /root files" >&2; return 1; }
    rsync -a "$SRC/files"/ "$ROOT_FILES"/ --exclude src --exclude src-hermes || {
      rsync -a "$safety/files"/ "$ROOT_FILES"/ --exclude src --exclude src-hermes || true
      echo "src-sync: files restore failed; safety copy at $safety/files" >&2; return 1;
    }
  fi
  rmdir "$safety" 2>/dev/null || true
}

do_import_json() {
  [ -f "$PENDING_JSON" ] || return 0
  valid_json_export "$PENDING_JSON" || { echo "src-sync: queued JSON backup is invalid; preserving it for recovery" >&2; return 1; }
  local token tmpdir code=000 error="" providers combos
  token=$(cli_token) || { echo "src-sync: cannot derive 9Router CLI token" >&2; return 1; }
  mkdir -p "$STATE" || return 1
  tmpdir=$(mktemp -d "$STATE/.json-restore.XXXXXX") || return 1
  case "$tmpdir" in "$STATE"/.json-restore.*) ;; *) echo "src-sync: invalid temporary restore path" >&2; return 1 ;; esac
  for ((i=0; i<90; i++)); do
    code=$(curl -sS --connect-timeout 1 --max-time 3 -o /dev/null -w '%{http_code}' \
      -H "x-9r-cli-token: $token" "http://127.0.0.1:$NINE_PORT/api/settings/database" 2>/dev/null) || code=000
    [ "$code" = 200 ] && break
    sleep 1
  done
  [ "$code" = 200 ] || error="9Router API did not become ready (HTTP $code)"
  if [ -z "$error" ]; then
    code=$(curl -sS --max-time 30 -o "$tmpdir/post.json" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' -H "x-9r-cli-token: $token" \
      --data-binary "@$PENDING_JSON" "http://127.0.0.1:$NINE_PORT/api/settings/database" 2>/dev/null) || code=000
    [ "$code" = 200 ] || error="JSON import failed (HTTP $code)"
  fi
  if [ -z "$error" ]; then
    code=$(curl -sS --max-time 30 -o "$tmpdir/export.json" -w '%{http_code}' \
      -H "x-9r-cli-token: $token" "http://127.0.0.1:$NINE_PORT/api/settings/database" 2>/dev/null) || code=000
    if [ "$code" != 200 ] || ! valid_json_export "$tmpdir/export.json" \
        || ! jq -S . "$PENDING_JSON" > "$tmpdir/expected.json" \
        || ! jq -S . "$tmpdir/export.json" > "$tmpdir/actual.json" \
        || ! cmp -s "$tmpdir/expected.json" "$tmpdir/actual.json"; then
      error="JSON restore verification failed (HTTP $code); queued copy retained"
    fi
  fi
  if [ -z "$error" ]; then
    providers=$(jq '.providerConnections|length' "$tmpdir/export.json")
    combos=$(jq '.combos|length' "$tmpdir/export.json")
    rm -f -- "$PENDING_JSON" || error="restored JSON but cannot clear pending marker"
  fi
  rm -rf -- "$tmpdir"
  [ -z "$error" ] || { echo "src-sync: $error" >&2; return 1; }
  echo "src-sync: JSON restore verified (providers=$providers combos=$combos)"
}

do_init() {
  need; git_ident; mkdir -p "$SRC"
  resolve_repo || die "cannot resolve repo (set GITHUB_TOKEN / GITHUB_REPO)"
  local me existing
  me=$(gh_user)
  existing=$(repo_exists "$REPO_OWNER" "$REPO_NAME") || die "cannot verify backup repo privacy/access"
  if [ -z "$existing" ]; then
    if [ -n "$(repo_spec)" ] && [ "$REPO_OWNER" != "$me" ]; then
      die "repo $REPO_OWNER/$REPO_NAME not found — token cannot access it"
    fi
    create_repo "$REPO_NAME" >/dev/null || die "failed to create repo $REPO_OWNER/$REPO_NAME (token scope = repo)"
    existing=$(repo_exists "$REPO_OWNER" "$REPO_NAME") || die "cannot verify created repo privacy"
    [ -n "$existing" ] || die "created repo $REPO_OWNER/$REPO_NAME is not accessible"
    echo "created private repo $REPO_OWNER/$REPO_NAME"
  else
    echo "private repo $REPO_OWNER/$REPO_NAME already exists"
  fi
  if [ ! -d "$SRC/.git" ]; then git -C "$SRC" init -q; fi
  git -C "$SRC" remote set-url origin "$(remote_url "$REPO_OWNER" "$REPO_NAME")" 2>/dev/null \
    || git -C "$SRC" remote add origin "$(remote_url "$REPO_OWNER" "$REPO_NAME")" \
    || die "cannot link verified private backup remote"
  write_gitignore || die "cannot write backup .gitignore"
  echo "$REPO_OWNER/$REPO_NAME"
}

do_restore() {
  need; git_ident
  resolve_repo || die "cannot resolve repo"
  local repo_id url
  repo_id=$(repo_exists "$REPO_OWNER" "$REPO_NAME") || die "cannot verify backup repo privacy/access"
  [ -n "$repo_id" ] || { echo "no repo $REPO_OWNER/$REPO_NAME yet — skip restore, will create on first backup"; return 0; }
  url="$(remote_url "$REPO_OWNER" "$REPO_NAME")"
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" remote set-url origin "$url" 2>/dev/null \
      || git -C "$SRC" remote add origin "$url" \
      || die "cannot link verified private backup remote"
    git -C "$SRC" fetch origin main || die "fetch failed; refusing restore"
    git -C "$SRC" reset --hard origin/main || die "checkout failed; refusing restore"
  else
    local fresh="${SRC}.restore-$$"
    rm -rf "$fresh"
    git clone "$url" "$fresh" || { rm -rf "$fresh"; die "clone failed; refusing restore"; }
    [ -d "$fresh/.git" ] || { rm -rf "$fresh"; die "clone produced no git checkout"; }
    if [ -d "$SRC" ]; then rmdir "$SRC" 2>/dev/null || { rm -rf "$fresh"; die "stage exists without git metadata; refusing replace"; }; fi
    mv "$fresh" "$SRC" || die "cannot install restored checkout"
  fi
  apply_restore
}

do_push() {
  need
  [ -d "$SRC/.git" ] || do_init >/dev/null
  git_ident
  resolve_repo || die "cannot resolve backup repo"
  local repo_id url
  repo_id=$(repo_exists "$REPO_OWNER" "$REPO_NAME") || die "cannot verify backup repo privacy/access"
  [ -n "$repo_id" ] || die "backup repo $REPO_OWNER/$REPO_NAME not found; refusing push"
  url="$(remote_url "$REPO_OWNER" "$REPO_NAME")"
  git -C "$SRC" remote set-url origin "$url" 2>/dev/null \
    || git -C "$SRC" remote add origin "$url" \
    || die "cannot set verified private backup remote"
  clean_remote "$SRC"
  snapshot || return 1
  git -C "$SRC" add -A || { echo "src-sync: staging failed" >&2; return 1; }
  if ! git -C "$SRC" diff --cached --quiet; then
    git -C "$SRC" commit -q -m "auto-backup $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      || { echo "src-sync: commit failed" >&2; return 1; }
  fi
  git -C "$SRC" pull --rebase --autostash 2>/dev/null \
    || { git -C "$SRC" rebase --abort 2>/dev/null || true; echo "src-sync: rebase failed; refusing push" >&2; return 1; }
  local out
  out=$(git -C "$SRC" push -u origin HEAD 2>&1) || {
    echo "src-sync: PUSH FAILED — remote retained; resolve divergence before retry: $out" >&2
    return 1
  }
  [ -n "$out" ] && echo "$out" || true
}

do_watch() {
  need
  echo "src-sync: watching 9Router JSON + /root files every ${INTERVAL}s"
  while true; do
    out=$(do_push 2>&1) || printf '%s\n' "$out"
    sleep "$INTERVAL"
  done
}

do_status() {
  need
  resolve_repo || die "cannot resolve repo"
  echo "Backup: 9Router JSON + /root files (fresh DB only; private repo required)"
  echo "Stage:  $SRC"
  echo "Repo:   $REPO_OWNER/$REPO_NAME"
  echo "Remote: $(git -C "$SRC" remote get-url origin 2>/dev/null || echo '(not linked)')"
  echo "Last:   $(git -C "$SRC" log -1 --format='%h %cr %s' 2>/dev/null || echo '(no commits)')"
}

case "${1:-push}" in
  --init)    do_init ;;
  --init-identity) ensure_cli_identity ;;
  --restore|restore) do_restore ;;
  --restore-json) do_import_json ;;
  --watch)   do_watch ;;
  --status)  do_status ;;
  --print-repo) print_repo ;;
  push|--push|backup) do_push ;;
  *) echo "usage: src-sync [backup|restore|--init|--restore|--init-identity|--restore-json|--watch|--status|--print-repo|push]"; exit 1 ;;
esac
