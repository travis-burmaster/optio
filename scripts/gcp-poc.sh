#!/usr/bin/env bash
# Pause / resume an Optio deployment on GKE + Cloud SQL to save cost (e.g. over
# a weekend).
#
#   scripts/gcp-poc.sh down     # stop Optio, scale nodes to 0, stop Cloud SQL
#   scripts/gcp-poc.sh up       # start Cloud SQL, bring nodes back, start Optio
#   scripts/gcp-poc.sh status
#
# Settings come from the environment or from $OPTIO_GCP_ENV (default
# ~/.config/optio-poc/env), a shell file kept outside the repo:
#
#   PROJECT=my-project ZONE=us-central1-a CLUSTER=optio-poc
#   SQL_INSTANCE=optio-poc-db URL=https://optio.example.com
#
# While down: no nodes, Cloud SQL stopped (storage only), and the load balancer
# + static IP stay so DNS keeps pointing at the same address. Redis (with
# redis.persistence.enabled) and repo-pod volumes are kept. Run `down` when no
# work is running: interrupted runs become needs-attention rather than retrying.
set -euo pipefail

ENV_FILE="${OPTIO_GCP_ENV:-$HOME/.config/optio-poc/env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${PROJECT:?set PROJECT (or create $ENV_FILE)}"
: "${ZONE:?set ZONE}"
: "${CLUSTER:?set CLUSTER}"
: "${SQL_INSTANCE:?set SQL_INSTANCE}"
: "${URL:?set URL, e.g. https://optio.example.com}"
POOL="${POOL:-default-pool}"
NS="${NS:-optio}"
MAX_NODES="${MAX_NODES:-3}"

# kubectl needs gke-gcloud-auth-plugin, which ships in gcloud's bin directory.
export PATH="$(dirname "$(readlink -f "$(command -v gcloud)")"):$PATH"
export CLOUDSDK_CORE_PROJECT="$PROJECT"

log() { printf '\n==> %s\n' "$*"; }

# gcloud, minus the project-tag nag it prints on every call. Fails when gcloud
# fails, so a step that didn't happen stops the script.
gc() {
  local out rc=0
  out="$(gcloud "$@" 2>&1)" || rc=$?
  grep -viE "environment' tag|add an 'environment'|resource-manager/docs|^$" <<<"$out" || true
  if ((rc)); then
    echo "gcloud $1 $2 $3 failed (exit $rc)" >&2
    return "$rc"
  fi
}

kube_creds() {
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" >/dev/null 2>&1
}

down() {
  kube_creds

  local running
  running="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -cE '^optio-(repo|job|agent|session|pa)-' || true)"
  if [[ "$running" != "0" ]]; then
    echo "Note: $running agent/repo pod(s) exist; any work still running in them will be interrupted."
  fi

  log "Stopping Optio API/web, then Redis (Redis flushes its append-only file on shutdown)"
  kubectl -n "$NS" scale deploy/optio-api --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app=optio-api --timeout=180s 2>/dev/null || true
  kubectl -n "$NS" scale deploy/optio-redis --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app=redis --timeout=120s 2>/dev/null || true

  # Autoscaling off first: otherwise pending pods (ingress, cert-manager,
  # kube-system) make the autoscaler bring a node straight back.
  log "Disabling autoscaling and scaling $POOL to 0 nodes"
  gc container node-pools update "$POOL" --cluster "$CLUSTER" --zone "$ZONE" --no-enable-autoscaling --quiet
  gc container clusters resize "$CLUSTER" --node-pool "$POOL" --zone "$ZONE" --num-nodes 0 --quiet

  log "Stopping Cloud SQL ($SQL_INSTANCE)"
  gc sql instances patch "$SQL_INSTANCE" --activation-policy=NEVER --quiet

  log "Down. Resume with: $0 up"
}

up() {
  log "Starting Cloud SQL ($SQL_INSTANCE) — takes a few minutes"
  gc sql instances patch "$SQL_INSTANCE" --activation-policy=ALWAYS --quiet

  log "Scaling $POOL to 1 node and re-enabling autoscaling (0-$MAX_NODES)"
  gc container clusters resize "$CLUSTER" --node-pool "$POOL" --zone "$ZONE" --num-nodes 1 --quiet
  gc container node-pools update "$POOL" --cluster "$CLUSTER" --zone "$ZONE" \
    --enable-autoscaling --min-nodes 0 --max-nodes "$MAX_NODES" --quiet

  kube_creds
  log "Waiting for a node to be Ready"
  kubectl wait --for=condition=Ready node --all --timeout=600s

  log "Starting Redis, then Optio API/web"
  kubectl -n "$NS" scale deploy/optio-redis --replicas=1
  kubectl -n "$NS" rollout status deploy/optio-redis --timeout=300s
  kubectl -n "$NS" scale deploy/optio-api --replicas=1
  kubectl -n "$NS" rollout status deploy/optio-api --timeout=600s

  log "Checking $URL/api/health"
  for _ in $(seq 1 30); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/health")" == "200" ]]; then
      echo "Up: $URL"
      return 0
    fi
    sleep 10
  done
  echo "Pods are running but $URL/api/health is not 200 yet; check: kubectl -n $NS get pods" >&2
  return 1
}

status() {
  log "Cloud SQL"
  gc sql instances describe "$SQL_INSTANCE" --format='value(state,settings.activationPolicy)'
  log "Node pool $POOL"
  gc container node-pools describe "$POOL" --cluster "$CLUSTER" --zone "$ZONE" \
    --format='value(autoscaling.enabled,initialNodeCount)'
  if kube_creds; then
    kubectl get nodes --no-headers 2>/dev/null | awk '{print "  node", $1, $2}'
    kubectl -n "$NS" get deploy,pods --no-headers 2>/dev/null | sed 's/^/  /'
  fi
  log "Health"
  curl -s -o /dev/null -w "  $URL/api/health -> %{http_code}\n" --max-time 10 "$URL/api/health" || echo "  unreachable"
}

case "${1:-}" in
  down) down ;;
  up) up ;;
  status) status ;;
  *) echo "usage: $0 {down|up|status}" >&2; exit 2 ;;
esac
