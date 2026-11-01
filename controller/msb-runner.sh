#!/usr/bin/env bash
# Keeps POOL_SIZE idle, ephemeral GitHub Actions runners alive, each in its own
# microsandbox microVM. Every VM takes exactly one job (JIT config), then is
# destroyed and replaced.
set -uo pipefail

: "${GITHUB_TARGET:?set GITHUB_TARGET to an org name or owner/repo}"
API=${GITHUB_API_URL:-https://api.github.com}
POOL_SIZE=${POOL_SIZE:-2}
RUNNER_PREFIX=${RUNNER_PREFIX:-msb}
RUNNER_IMAGE=${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}
RUNNER_GROUP_ID=${RUNNER_GROUP_ID:-1}
case $(uname -m) in aarch64|arm64) arch=arm64 ;; *) arch=x64 ;; esac
RUNNER_LABELS=${RUNNER_LABELS:-self-hosted,linux,$arch,msb}
VM_CPUS=${VM_CPUS:-2}
VM_MEMORY=${VM_MEMORY:-4G}
JOB_MAX_DURATION=${JOB_MAX_DURATION:-6h}
ENABLE_DOCKER=${ENABLE_DOCKER:-1}
# Public internet only (no RFC1918/LAN), and never the cloud metadata endpoint.
MSB_NET_ARGS=${MSB_NET_ARGS:---net public --net-rule deny@169.254.169.254}
MSB_EXTRA_ARGS=${MSB_EXTRA_ARGS:-}
GUEST_SCRIPT=${GUEST_SCRIPT:-/app/start-runner.sh}

STATE=/run/msb-runner
mkdir -p "$STATE"

if [[ $GITHUB_TARGET == */* ]]; then
  RUNNERS_PATH=/repos/$GITHUB_TARGET/actions/runners
  INSTALL_PATH=/repos/$GITHUB_TARGET/installation
else
  RUNNERS_PATH=/orgs/$GITHUB_TARGET/actions/runners
  INSTALL_PATH=/orgs/$GITHUB_TARGET/installation
fi

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# api METHOD PATH [JSON]; authenticates with $AUTH.
api() {
  curl -sS --fail-with-body -X "$1" \
    -H "Authorization: Bearer $AUTH" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    ${3:+-d "$3"} "$API$2"
}

app_jwt() {
  local now hdr body
  now=$(date +%s)
  hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  body=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$GITHUB_APP_ID" | b64url)
  printf '%s.%s.%s' "$hdr" "$body" \
    "$(printf '%s.%s' "$hdr" "$body" | openssl dgst -sha256 -sign "$GITHUB_APP_KEY_FILE" | b64url)"
}

# Prints a token for the GitHub API: the PAT if set, otherwise a cached
# GitHub App installation token (refreshed after 50 of its 60 minutes).
access_token() {
  if [[ -n ${GITHUB_TOKEN:-} ]]; then printf '%s' "$GITHUB_TOKEN"; return; fi
  (
    flock 9
    cache=$STATE/token
    if [[ -s $cache ]] && (( $(stat -c %Y "$cache") > $(date +%s) - 3000 )); then
      cat "$cache"; exit 0
    fi
    jwt=$(app_jwt) || exit 1
    id=${GITHUB_APP_INSTALLATION_ID:-$(AUTH=$jwt api GET "$INSTALL_PATH" | jq -r .id)} || exit 1
    AUTH=$jwt api POST "/app/installations/$id/access_tokens" | jq -er .token > "$cache.tmp" || exit 1
    mv "$cache.tmp" "$cache"
    cat "$cache"
  ) 9>"$STATE/token.lock"
}

# Remove runner registrations left behind by an earlier run of this pool.
# Busy runners refuse deletion (422), which is fine.
deregister_stale() {
  local AUTH ids
  AUTH=$(access_token) || return
  ids=$(api GET "$RUNNERS_PATH?per_page=100" |
    jq -r --arg p "$RUNNER_PREFIX-" '.runners[] | select(.name | startswith($p)) | .id') || return
  for id in $ids; do api DELETE "$RUNNERS_PATH/$id" >/dev/null 2>&1 || true; done
}

run_slot() {
  local slot=$1 backoff=5 name resp id jit AUTH rc
  while :; do
    name=$RUNNER_PREFIX-$slot-$(date +%s)
    resp=
    if ! AUTH=$(access_token) || ! resp=$(api POST "$RUNNERS_PATH/generate-jitconfig" "$(
      jq -nc --arg n "$name" --argjson g "$RUNNER_GROUP_ID" --arg l "$RUNNER_LABELS" \
        '{name: $n, runner_group_id: $g, labels: ($l | split(",")), work_folder: "_work"}'
    )"); then
      log "slot $slot: failed to get JIT config: ${resp:-}; retrying in ${backoff}s"
      sleep "$backoff"; backoff=$(( backoff < 300 ? backoff * 2 : 300 ))
      continue
    fi
    backoff=5
    id=$(jq -r .runner.id <<<"$resp")
    jit=$(jq -r .encoded_jit_config <<<"$resp")

    log "slot $slot: booting $name (runner id $id)"
    # shellcheck disable=SC2086 # word-splitting of the *_ARGS strings is intended
    msb run --name "$name" --replace --no-stdin --quiet \
      --label "pool=$RUNNER_PREFIX" \
      -c "$VM_CPUS" -m "$VM_MEMORY" --max-duration "$JOB_MAX_DURATION" \
      $MSB_NET_ARGS $MSB_EXTRA_ARGS \
      -u runner -w /home/runner \
      --script-path "start-runner:$GUEST_SCRIPT" \
      -e "ENABLE_DOCKER=$ENABLE_DOCKER" \
      -e "RUNNER_JITCONFIG=$jit" \
      "$RUNNER_IMAGE" -- start-runner 2>&1 | sed -u "s/^/[$name] /"
    rc=${PIPESTATUS[0]}
    log "slot $slot: $name exited ($rc)"

    msb rm -f -q "$name" >/dev/null 2>&1 || true
    # Ephemeral runners deregister themselves after a job; this catches VMs
    # that died before picking one up.
    AUTH=$(access_token) && api DELETE "$RUNNERS_PATH/$id" >/dev/null 2>&1 || true
    (( rc == 0 )) || sleep 5
  done
}

shutdown() {
  log "shutting down: destroying sandboxes in pool $RUNNER_PREFIX"
  trap - TERM INT
  # shellcheck disable=SC2046
  kill $(jobs -p) 2>/dev/null
  msb rm -f -q --label "pool=$RUNNER_PREFIX" >/dev/null 2>&1 || true
  deregister_stale
  exit 0
}
trap shutdown TERM INT

log "pool=$RUNNER_PREFIX target=$GITHUB_TARGET size=$POOL_SIZE image=$RUNNER_IMAGE labels=$RUNNER_LABELS"
msb rm -f -q --label "pool=$RUNNER_PREFIX" >/dev/null 2>&1 || true
deregister_stale
msb pull "$RUNNER_IMAGE" || log "warning: pre-pull of $RUNNER_IMAGE failed; first boot will pull"

for ((i = 1; i <= POOL_SIZE; i++)); do run_slot "$i" & done
wait
