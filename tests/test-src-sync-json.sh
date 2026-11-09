#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SYNC="$SCRIPT_DIR/src-sync.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vanguard-json-test.XXXXXX")
cleanup() {
  case "$tmp" in
    "${TMPDIR:-/tmp}"/vanguard-json-test.*) rm -rf -- "$tmp" ;;
    *) echo "refusing unexpected test cleanup path" >&2; return 1 ;;
  esac
}
trap cleanup EXIT
command -v jq >/dev/null
command -v node >/dev/null
test_bin="$tmp/bin"
mkdir -p "$test_bin"

cat > "$tmp/export.json" <<'JSON'
{"apiKeys":[],"combos":[],"customModels":[],"mitmAlias":{},"modelAliases":{},"pricing":{},"providerConnections":[],"providerNodes":[],"proxyPools":[],"settings":{}}
JSON

cat > "$test_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
out=/dev/null method=GET data_file= url= auth_header= status=200
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w|-X|-H|--data-binary|-d) key=$1; value=$2; shift 2
      case "$key" in
        -X) method=$value ;;
        -H) [[ "$value" == x-9r-cli-token:* ]] && auth_header=$value ;;
        --data-binary) data_file=${value#@} ;;
      esac ;;
    --exclude) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
if [[ "$url" == http://127.0.0.1:20128/api/settings/database ]]; then
  printf '%s\n' "$auth_header" >> "$TEST_CURL_HEADERS"
  if [[ "$method" == POST ]]; then
    status=${TEST_POST_STATUS:-200}
    if [[ "$status" == 200 ]]; then cp -- "$data_file" "$TEST_RECEIVED_JSON"; fi
    printf '{"ok":true}\n' > "$out"
  else
    status=${TEST_EXPORT_STATUS:-200}
    if [[ "$status" == 200 ]]; then
      if [[ ${TEST_INVALID_EXPORT:-0} == 1 && ! -f "$TEST_RECEIVED_JSON" ]]; then
        printf '{"providerConnections":[],"combos":[]}\n' > "$out"
      elif [[ -f "$TEST_RECEIVED_JSON" ]]; then
        cp -- "$TEST_RECEIVED_JSON" "$out"
      else
        cp -- "$TEST_EXPORT_JSON" "$out"
      fi
    fi
  fi
elif [[ "$url" == https://api.github.com/repos/owner/repo ]]; then
  printf '{"id":1,"private":%s}\n' "${TEST_REPO_PRIVATE:-true}" > "$out"
else
  status=404
fi
printf '%s' "$status"
CURL

cat > "$test_bin/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -eu
source_path= dest_path=
exclude_patterns=()
while (($#)); do
  case "$1" in
    --exclude) exclude_patterns+=("$2"); shift 2 ;;
    -*) shift ;;
    *) source_path=$dest_path; dest_path=$1; shift ;;
  esac
done
[[ -n "$source_path" && -n "$dest_path" ]]
mkdir -p "$dest_path"
cp -a "$source_path"/. "$dest_path"/
for pattern in "${exclude_patterns[@]}"; do
  relative=${pattern#/}; relative=${relative%/}
  target="$dest_path/$relative"
  case "$target" in "$TEST_TMP_ROOT"/*) rm -rf -- "$target" ;; esac
done
RSYNC
chmod +x "$test_bin/curl" "$test_bin/rsync"

export PATH="$test_bin:$PATH" TEST_EXPORT_JSON="$tmp/export.json" TEST_TMP_ROOT="$tmp"
export TEST_RECEIVED_JSON="$tmp/received.json" TEST_CURL_HEADERS="$tmp/headers.log"
export VANGUARD_CONFIG="$tmp/no-config"

# Fresh identity is random, private, and stable across restarts.
identity_dir="$tmp/identity"
env NINE_DIR="$identity_dir" VANGUARD_STATE_DIR="$tmp/identity-state" "$SYNC" --init-identity
for file in "$identity_dir/machine-id" "$identity_dir/auth/cli-secret"; do
  [[ $(stat -c '%a' "$file") == 600 && $(wc -c < "$file") == 65 ]]
done
machine_before=$(<"$identity_dir/machine-id") secret_before=$(<"$identity_dir/auth/cli-secret")
env NINE_DIR="$identity_dir" VANGUARD_STATE_DIR="$tmp/identity-state" "$SYNC" --init-identity
[[ $(<"$identity_dir/machine-id") == "$machine_before" && $(<"$identity_dir/auth/cli-secret") == "$secret_before" ]]

# Snapshot exports JSON even when SQLite is corrupt and untracks legacy files.
repo="$tmp/src" remote="$tmp/remote.git" nine="$tmp/root/custom-router" state="$tmp/state" root_files="$tmp/root"
mkdir -p "$repo/9router/db" "$repo/files" "$nine/db" "$nine/auth" "$root_files/docs" "$tmp/home"
printf 'legacy-only sentinel\n' > "$repo/9router/legacy-secret.txt"
printf 'corrupt sqlite sentinel\n' > "$nine/db/data.sqlite"
printf 'saved file\n' > "$root_files/docs/note.txt"
env HOME="$tmp/home" NINE_DIR="$nine" VANGUARD_STATE_DIR="$state" "$SYNC" --init-identity
export TEST_EXPECT_TOKEN
TEST_EXPECT_TOKEN=$(node -e 'const f=require("fs"),c=require("crypto"),[m,s]=process.argv.slice(1).map(p=>f.readFileSync(p,"utf8").trim());process.stdout.write(c.createHash("sha256").update(m+"9r-cli-auth"+s).digest("hex").slice(0,16))' "$nine/machine-id" "$nine/auth/cli-secret")
git init --bare -q "$remote"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
git -C "$repo" add 9router
git -C "$repo" commit -qm legacy
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -qu origin main
HOME="$tmp/home" git -C "$repo" config --global url."file://$remote".insteadOf https://github.com/owner/repo.git
env HOME="$tmp/home" GITHUB_TOKEN=test-token GITHUB_REPO=owner/repo \
  NINE_DIR="$nine" VANGUARD_SRC_DIR="$repo" VANGUARD_STATE_DIR="$state" \
  VANGUARD_ROOT_FILES_DIR="$root_files" TEST_REPO_PRIVATE=true "$SYNC" backup >/dev/null
helper=$(HOME="$tmp/home" git config --global credential.helper)
[[ "$helper" == *"$state/github-token"* ]]
tree=$(git --git-dir="$remote" ls-tree -r --name-only main)
[[ "$tree" == *9router-backup.json* && "$tree" == *files/docs/note.txt* ]]
[[ "$tree" != *9router/legacy-secret.txt* && "$tree" != *9router/db/data.sqlite* && "$tree" != *files/custom-router/* ]]
git --git-dir="$remote" show main:9router-backup.json | jq -S . > "$tmp/remote-export.json"
jq -S . "$tmp/export.json" > "$tmp/expected-export.json"
cmp -s "$tmp/remote-export.json" "$tmp/expected-export.json"

# Public repositories and invalid exports must not update the remote.
remote_before=$(git --git-dir="$remote" rev-parse main)
if env HOME="$tmp/home" GITHUB_TOKEN=test-token GITHUB_REPO=owner/repo \
  NINE_DIR="$nine" VANGUARD_SRC_DIR="$repo" VANGUARD_STATE_DIR="$state" \
  VANGUARD_ROOT_FILES_DIR="$root_files" TEST_REPO_PRIVATE=false "$SYNC" backup >/dev/null 2>&1; then
  echo 'public backup repo was accepted' >&2; exit 1
fi
if env HOME="$tmp/home" GITHUB_TOKEN=test-token GITHUB_REPO=owner/repo \
  NINE_DIR="$nine" VANGUARD_SRC_DIR="$repo" VANGUARD_STATE_DIR="$state" \
  VANGUARD_ROOT_FILES_DIR="$root_files" TEST_REPO_PRIVATE=true TEST_INVALID_EXPORT=1 "$SYNC" backup >/dev/null 2>&1; then
  echo 'invalid JSON export was accepted' >&2; exit 1
fi
[[ $(git --git-dir="$remote" rev-parse main) == "$remote_before" ]]

# Restore queues JSON only for a fresh database and preserves any existing DB.
restore_root="$tmp/restored-root" fresh_nine="$tmp/fresh-nine" fresh_state="$tmp/fresh-state"
mkdir -p "$restore_root"
env HOME="$tmp/home" GITHUB_TOKEN=test-token GITHUB_REPO=owner/repo \
  NINE_DIR="$fresh_nine" VANGUARD_SRC_DIR="$repo" VANGUARD_STATE_DIR="$fresh_state" \
  VANGUARD_ROOT_FILES_DIR="$restore_root" "$SYNC" --restore >/dev/null
jq -S . "$fresh_state/9router-restore.json" > "$tmp/queued-export.json"
cmp -s "$tmp/queued-export.json" "$tmp/expected-export.json"
existing_nine="$tmp/existing-nine" existing_state="$tmp/existing-state" existing_root="$tmp/existing-root"
mkdir -p "$existing_nine/db" "$existing_root"
printf 'preserve-this-db' > "$existing_nine/db/data.sqlite"
env HOME="$tmp/home" GITHUB_TOKEN=test-token GITHUB_REPO=owner/repo \
  NINE_DIR="$existing_nine" VANGUARD_SRC_DIR="$repo" VANGUARD_STATE_DIR="$existing_state" \
  VANGUARD_ROOT_FILES_DIR="$existing_root" "$SYNC" --restore >/dev/null
[[ $(<"$existing_nine/db/data.sqlite") == preserve-this-db && ! -e "$existing_state/9router-restore.json" ]]

# Import requires an exact round-trip; failures retain the queued JSON.
cp -- "$tmp/export.json" "$state/9router-restore.json"
env HOME="$tmp/home" NINE_DIR="$nine" VANGUARD_SRC_DIR="$repo" VANGUARD_STATE_DIR="$state" \
  TEST_EXPECT_TOKEN="$TEST_EXPECT_TOKEN" "$SYNC" --restore-json >/dev/null
[[ ! -e "$state/9router-restore.json" ]]
jq -S . "$TEST_RECEIVED_JSON" > "$tmp/received-export.json"
cmp -s "$tmp/received-export.json" "$tmp/expected-export.json"
[[ $(<"$TEST_CURL_HEADERS") == *"x-9r-cli-token: $TEST_EXPECT_TOKEN"* ]]
cp -- "$tmp/export.json" "$state/9router-restore.json"
if env HOME="$tmp/home" NINE_DIR="$nine" VANGUARD_SRC_DIR="$repo" VANGUARD_STATE_DIR="$state" \
  TEST_EXPECT_TOKEN="$TEST_EXPECT_TOKEN" TEST_POST_STATUS=503 "$SYNC" --restore-json >/dev/null 2>&1; then
  echo 'failed JSON import was accepted' >&2; exit 1
fi
[[ -f "$state/9router-restore.json" ]]

echo 'PASS: JSON-only backup/restore, privacy, identity bootstrap, and live-DB protection'
