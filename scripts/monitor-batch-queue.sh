#!/bin/bash
# Monitor and auto-fix stuck batch queue processing.
#
# Detects leaked concurrency tokens in Redis and stuck batches in Postgres.
# When --auto-fix is enabled, performs SURGICAL cleanup: only affects the
# specific stuck batch IDs, not global Redis state.
#
# Usage:
#   ./scripts/monitor-batch-queue.sh              # Check only
#   ./scripts/monitor-batch-queue.sh --auto-fix   # Check and auto-fix stuck batches
#
# Environment variables (set in .env.monitor, see .env.monitor.example):
#   MONITOR_SERVER               - SSH target (e.g. root@your-server-ip)
#   MONITOR_REDIS_CONTAINER      - Redis container name
#   MONITOR_POSTGRES_CONTAINER   - Postgres container name
#   MONITOR_POSTGRES_DB          - Database name (default: trigger)
#   MONITOR_ENV_ID               - Trigger.dev RuntimeEnvironment ID
#   MONITOR_CONCURRENCY_LIMIT    - Must match BATCH_CONCURRENCY_LIMIT_DEFAULT (default: 10)
#   MONITOR_SHARD_COUNT          - Must match BATCH_QUEUE_SHARD_COUNT (default: 2)
#   MONITOR_STUCK_THRESHOLD_MIN  - Minutes before a batch is considered stuck (default: 15)
#
# Cron example (every 5 minutes):
#   */5 * * * * /path/to/scripts/monitor-batch-queue.sh --auto-fix >> /var/log/batch-monitor.log 2>&1

set -euo pipefail

# ─── Load .env if present ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env.monitor"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

# ─── Configuration from environment ─────────────────────────────────────────
SERVER="${MONITOR_SERVER:?'MONITOR_SERVER is required (e.g. root@your-server-ip)'}"
REDIS_CONTAINER="${MONITOR_REDIS_CONTAINER:?'MONITOR_REDIS_CONTAINER is required'}"
POSTGRES_CONTAINER="${MONITOR_POSTGRES_CONTAINER:?'MONITOR_POSTGRES_CONTAINER is required'}"
POSTGRES_DB="${MONITOR_POSTGRES_DB:-trigger}"
ENV_ID="${MONITOR_ENV_ID:?'MONITOR_ENV_ID is required (RuntimeEnvironment ID)'}"
CONCURRENCY_LIMIT="${MONITOR_CONCURRENCY_LIMIT:-10}"
STUCK_THRESHOLD_MINUTES="${MONITOR_STUCK_THRESHOLD_MIN:-15}"
SHARD_COUNT="${MONITOR_SHARD_COUNT:-2}"

SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2"

AUTO_FIX=false
if [[ "${1:-}" == "--auto-fix" ]]; then
  AUTO_FIX=true
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ─── Helper: SSH with timeout ───────────────────────────────────────────────
run_ssh() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$SERVER" "$@"
}

# ─── Check Redis concurrency tokens ─────────────────────────────────────────
CONCURRENCY_COUNT=$(run_ssh \
  "docker exec $REDIS_CONTAINER redis-cli SCARD engine:batch:concurrency:tenant:$ENV_ID" 2>/dev/null || echo "ERROR")

if [[ "$CONCURRENCY_COUNT" == "ERROR" ]]; then
  echo "[$TIMESTAMP] ERROR: Could not connect to Redis"
  exit 1
fi

# ─── Get stuck batch IDs from Postgres (single query, fixes TOCTOU) ─────────
STUCK_IDS_RAW=$(run_ssh \
  "docker exec -i $POSTGRES_CONTAINER psql -U postgres -d $POSTGRES_DB -t -A \
  -c \"SELECT id FROM \\\"BatchTaskRun\\\" WHERE status = 'PROCESSING' AND \\\"updatedAt\\\" < NOW() - INTERVAL '$STUCK_THRESHOLD_MINUTES minutes';\"" 2>/dev/null || echo "ERROR")

if [[ "$STUCK_IDS_RAW" == "ERROR" ]]; then
  echo "[$TIMESTAMP] ERROR: Could not connect to Postgres"
  exit 1
fi

# Remove empty lines, derive count from the single query result
STUCK_IDS_RAW=$(echo "$STUCK_IDS_RAW" | sed '/^$/d')
if [[ -n "$STUCK_IDS_RAW" ]]; then
  STUCK_COUNT=$(echo "$STUCK_IDS_RAW" | wc -l | tr -d '[:space:]')
else
  STUCK_COUNT=0
fi

# Trim whitespace
CONCURRENCY_COUNT=$(echo "$CONCURRENCY_COUNT" | tr -d '[:space:]')

# ─── Check master queue sizes ────────────────────────────────────────────────
MASTER_QUEUE_TOTAL=0
for ((shard=0; shard<SHARD_COUNT; shard++)); do
  SHARD_SIZE=$(run_ssh \
    "docker exec $REDIS_CONTAINER redis-cli ZCARD engine:batch:master:$shard" 2>/dev/null || echo "0")
  SHARD_SIZE=$(echo "$SHARD_SIZE" | tr -d '[:space:]')
  MASTER_QUEUE_TOTAL=$((MASTER_QUEUE_TOTAL + SHARD_SIZE))
done

# ─── Report ──────────────────────────────────────────────────────────────────
echo "[$TIMESTAMP] Batch Queue Health Check"
echo "  Concurrency tokens: $CONCURRENCY_COUNT / $CONCURRENCY_LIMIT"
echo "  Stuck batches (>$STUCK_THRESHOLD_MINUTES min): $STUCK_COUNT"
echo "  Master queue entries: $MASTER_QUEUE_TOTAL"

# ─── Evaluate health ────────────────────────────────────────────────────────
NEEDS_FIX=false

if [[ "$STUCK_COUNT" -gt 0 && "$CONCURRENCY_COUNT" -ge "$CONCURRENCY_LIMIT" ]]; then
  echo "  STATUS: CRITICAL - Concurrency at limit AND stuck batches detected"
  NEEDS_FIX=true
elif [[ "$STUCK_COUNT" -gt 0 ]]; then
  echo "  STATUS: WARNING - Stuck batches detected (concurrency not at limit)"
elif [[ "$CONCURRENCY_COUNT" -ge "$CONCURRENCY_LIMIT" ]]; then
  echo "  STATUS: WARNING - Concurrency at limit (no stuck batches yet)"
else
  echo "  STATUS: OK"
fi

# ─── Auto-fix if enabled ────────────────────────────────────────────────────
if [[ "$NEEDS_FIX" == "true" && "$AUTO_FIX" == "true" ]]; then
  if [[ -z "$STUCK_IDS_RAW" ]]; then
    echo "[$TIMESTAMP] AUTO-FIX: No stuck batch IDs found, skipping"
  else
    # Build comma-separated quoted list for SQL IN clause
    ID_LIST=$(echo "$STUCK_IDS_RAW" | sed "s/^/'/;s/$/'/" | paste -sd,)

    echo "[$TIMESTAMP] AUTO-FIX: Fixing $STUCK_COUNT stuck batches: $ID_LIST"

    # Step 1: Fix Postgres FIRST (in a single transaction)
    run_ssh "docker exec -i $POSTGRES_CONTAINER psql -U postgres -d $POSTGRES_DB -c \"
      BEGIN;
      UPDATE \\\"BatchTaskRun\\\"
        SET status = 'COMPLETED', \\\"updatedAt\\\" = NOW(), \\\"completedAt\\\" = NOW()
        WHERE id IN ($ID_LIST) AND status = 'PROCESSING';
      UPDATE \\\"Waitpoint\\\"
        SET status = 'COMPLETED', \\\"completedAt\\\" = NOW(), \\\"outputIsError\\\" = true
        WHERE \\\"idempotencyKey\\\" IN ($ID_LIST) AND type = 'BATCH' AND status != 'COMPLETED';
      COMMIT;
    \"" 2>/dev/null

    echo "[$TIMESTAMP] AUTO-FIX: Postgres updated (transactional)"

    # Step 2: Surgical Redis cleanup — only remove tokens for stuck batch IDs
    # Get the actual concurrency token members to find ones matching stuck batches
    TOKENS=$(run_ssh \
      "docker exec $REDIS_CONTAINER redis-cli SMEMBERS engine:batch:concurrency:tenant:$ENV_ID" 2>/dev/null || echo "")

    if [[ -n "$TOKENS" ]]; then
      # Remove only tokens that contain stuck batch IDs
      REMOVED=0
      while IFS= read -r token; do
        [[ -z "$token" ]] && continue
        while IFS= read -r stuck_id; do
          [[ -z "$stuck_id" ]] && continue
          if [[ "$token" == *"$stuck_id"* ]]; then
            run_ssh "docker exec $REDIS_CONTAINER redis-cli SREM engine:batch:concurrency:tenant:$ENV_ID '$token'" 2>/dev/null
            REMOVED=$((REMOVED + 1))
            break
          fi
        done <<< "$STUCK_IDS_RAW"
      done <<< "$TOKENS"
      echo "[$TIMESTAMP] AUTO-FIX: Removed $REMOVED concurrency tokens from Redis"
    fi

    # Step 3: Remove stuck batch entries from master queue shards (surgical ZREM)
    for ((shard=0; shard<SHARD_COUNT; shard++)); do
      while IFS= read -r stuck_id; do
        [[ -z "$stuck_id" ]] && continue
        # Master queue members are formatted as env:{envId}:batch:{batchId}
        run_ssh "docker exec $REDIS_CONTAINER redis-cli ZREM engine:batch:master:$shard 'env:$ENV_ID:batch:$stuck_id'" 2>/dev/null
      done <<< "$STUCK_IDS_RAW"
    done

    echo "[$TIMESTAMP] AUTO-FIX: Cleaned master queue entries for stuck batches"

    # Step 4: Clean up per-batch queues for stuck batches
    while IFS= read -r stuck_id; do
      [[ -z "$stuck_id" ]] && continue
      run_ssh "docker exec $REDIS_CONTAINER redis-cli DEL 'engine:batch:queue:env:$ENV_ID:batch:$stuck_id'" 2>/dev/null
    done <<< "$STUCK_IDS_RAW"

    echo "[$TIMESTAMP] AUTO-FIX: Complete. Fixed $STUCK_COUNT stuck batches."
  fi
elif [[ "$NEEDS_FIX" == "true" ]]; then
  echo "[$TIMESTAMP] Run with --auto-fix to automatically clean up"
fi
