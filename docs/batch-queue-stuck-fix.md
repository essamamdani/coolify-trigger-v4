# Batch Queue Stuck in PROCESSING — Diagnosis & Fix Guide

## The Problem

Batches created with `batchTriggerAndWait` get sealed but child runs are never created. The batch stays in `PROCESSING` status forever. In the Trigger.dev dashboard, you'll see a batch with 0 completed items out of N expected.

This affected ~0.06% of batches (2 out of 3,170 over 24h) in our deployment.

---

## How Batch Processing Works

Trigger.dev v4 uses a 2-phase batch API:

1. **Phase 1**: `POST /api/v3/batches` — creates `BatchTaskRun` record + stores metadata in Redis
2. **Phase 2**: `POST /api/v3/batches/:id/items` — streams items via NDJSON, enqueues to Redis BatchQueue, seals batch

The BatchQueue is built on top of **FairQueue**, a Redis-based fair scheduling system using Deficit Round-Robin (DRR). It has these Redis structures:

| Redis Key | Type | Purpose |
|-----------|------|---------|
| `engine:batch:master:{shardId}` | Sorted Set | Master queue tracking all batches with pending items |
| `engine:batch:queue:env:{envId}:batch:{batchId}` | Sorted Set | Per-batch queue of items to process |
| `engine:batch:drr:deficit` | Hash | DRR deficit counters per tenant |
| `engine:batch:concurrency:tenant:{envId}` | Set | Active concurrency tokens (semaphore) |

### Built-in Safety: Visibility Timeout

The FairQueue has a **visibility timeout** mechanism that protects against most crashes:

- **Timeout**: 60 seconds (hardcoded in `internal-packages/run-engine/src/batch-queue/index.ts:150`)
- **Reclaim loop**: Checks every 5 seconds for timed-out messages (`packages/redis-worker/src/fair-queue/index.ts:134`)
- **On reclaim**: The message is re-added to the queue AND its concurrency token is released (`fair-queue/index.ts:1355-1366`)

This means: **if the webapp crashes while processing a batch item, after ~60 seconds the message is automatically reclaimed and the concurrency slot is freed.** Most failures self-heal.

### Idempotency

Batch item processing is idempotent. The `BatchCompletionTracker` uses `SADD` on a per-item processed set to prevent double-counting. If a message is reclaimed and reprocessed, the completion counter won't be incremented twice.

---

## Root Cause: The Edge Case

There is one specific scenario where the visibility timeout safety net fails.

In `completeMessage()` (`packages/redis-worker/src/fair-queue/index.ts:1079-1084`), two Redis operations happen sequentially but **not atomically**:

```
Step 1: visibilityManager.complete(messageId)  → removes message from in-flight tracking
Step 2: concurrencyManager.release(messageId)  → removes concurrency token (SREM)
```

**If Step 1 succeeds but Step 2 fails** (Redis connection drop, timeout, or process crash between the two calls):

1. The message is **no longer in the in-flight set** → the reclaim loop can't find it
2. The concurrency token is **still in the concurrency set** → permanently leaked
3. With `BATCH_CONCURRENCY_LIMIT_DEFAULT=1` (the default), the single slot is occupied → **ALL batch processing for that environment is permanently blocked**

This is a race condition window between two non-atomic Redis operations. It's narrow but given enough traffic, it will eventually occur.

### Why `BATCH_CONCURRENCY_LIMIT_DEFAULT=1` Is Dangerous

The default of 1 means a single leaked token causes total blockage. With a higher limit (e.g., 10):
- A single leaked token uses 1 of 10 slots
- 9 slots remain active for batch processing
- The system continues working despite the leak
- The leaked token persists but doesn't cause visible impact

---

## Prevention (Applied)

### Docker-Compose Env Vars

Added to all docker-compose files (`docker-compose.yaml`, `docker-compose.external-dbs.yaml`, `distributed/webapp/docker-compose.yaml`) in the `trigger` service:

```yaml
# Batch Queue - Prevention for stuck batches
BATCH_CONCURRENCY_LIMIT_DEFAULT: 10
BATCH_QUEUE_CONSUMER_COUNT: 5
BATCH_QUEUE_CONSUMER_INTERVAL_MS: 100
BATCH_QUEUE_SHARD_COUNT: 2
```

| Env Var | Default | Our Value | Why |
|---------|---------|-----------|-----|
| `BATCH_CONCURRENCY_LIMIT_DEFAULT` | `1` | `10` | A single leaked token no longer blocks all processing. 9 slots remain. |
| `BATCH_QUEUE_CONSUMER_COUNT` | `3` | `5` | More consumers for faster batch item pickup. Total = WEB_CONCURRENCY (6) x 5 = 30. |
| `BATCH_QUEUE_CONSUMER_INTERVAL_MS` | `50` | `100` | Balanced polling with more consumers. Reduces Redis pressure. |
| `BATCH_QUEUE_SHARD_COUNT` | `1` | `2` | Master queue distributed across 2 shards. Stale entries in one shard don't block the other. |

---

## All Batch-Related Env Vars

From Trigger.dev source (`apps/webapp/app/env.server.ts`):

### Batch Queue (FairQueue)

| Env Var | Default | Description |
|---------|---------|-------------|
| `BATCH_CONCURRENCY_LIMIT_DEFAULT` | `1` | Max concurrent batch items per environment. **Keep above 1.** |
| `BATCH_QUEUE_CONSUMER_COUNT` | `3` | Number of consumer loops per worker process |
| `BATCH_QUEUE_CONSUMER_INTERVAL_MS` | `50` | Polling interval per consumer (ms) |
| `BATCH_QUEUE_DRR_QUANTUM` | `25` | Items credited per environment per DRR round |
| `BATCH_QUEUE_MAX_DEFICIT` | `100` | Max accumulated DRR deficit (prevents starvation) |
| `BATCH_QUEUE_SHARD_COUNT` | `1` | Number of master queue shards |
| `BATCH_QUEUE_MASTER_QUEUE_LIMIT` | `1000` | Max queues fetched per consumer iteration |
| `BATCH_QUEUE_WORKER_QUEUE_ENABLED` | `true` | Enable two-stage processing via worker queue |
| `BATCH_QUEUE_WORKER_QUEUE_TIMEOUT_SECONDS` | `10` | Worker queue blocking pop timeout |
| `BATCH_QUEUE_GLOBAL_RATE_LIMIT` | none | Max items/second across all consumers |

### Batch Trigger Worker

| Env Var | Default | Description |
|---------|---------|-------------|
| `BATCH_TRIGGER_WORKER_ENABLED` | `true` | Enable batch trigger worker |
| `BATCH_TRIGGER_WORKER_CONCURRENCY_WORKERS` | `2` | Number of worker processes |
| `BATCH_TRIGGER_WORKER_CONCURRENCY_TASKS_PER_WORKER` | `10` | Tasks per worker |
| `BATCH_TRIGGER_WORKER_CONCURRENCY_LIMIT` | `20` | Global concurrency limit |
| `BATCH_TRIGGER_WORKER_POLL_INTERVAL` | `1000` | Poll interval (ms) |
| `BATCH_TRIGGER_PROCESS_JOB_VISIBILITY_TIMEOUT_MS` | `300000` | Visibility timeout for trigger jobs (5 min) |

### Batch API Limits

| Env Var | Default | Description |
|---------|---------|-------------|
| `MAX_BATCH_V2_TRIGGER_ITEMS` | `500` | Max items in v2 batch trigger |
| `MAX_BATCH_AND_WAIT_V2_TRIGGER_ITEMS` | `500` | Max items in batch trigger and wait |
| `STREAMING_BATCH_MAX_ITEMS` | `1000` | Max items in streaming batch (Phase 2) |
| `STREAMING_BATCH_ITEM_MAXIMUM_SIZE` | `3145728` | Max size per item (3MB) |
| `BATCH_TASK_PAYLOAD_MAXIMUM_SIZE` | `1000000` | Max batch payload (1MB) |
| `BATCH_RATE_LIMIT_MAX` | `1200` | Rate limit max tokens |
| `BATCH_RATE_LIMIT_REFILL_RATE` | `100` | Rate limit refill rate |
| `BATCH_RATE_LIMIT_REFILL_INTERVAL` | `10s` | Rate limit refill interval |

### Internal (Hardcoded, Not Configurable)

| Setting | Value | Source |
|---------|-------|--------|
| Visibility timeout | 60 seconds | `batch-queue/index.ts:150` |
| Reclaim interval | 5 seconds | `fair-queue/index.ts:134` |
| Cooloff threshold | 5 empty polls | `batch-queue/index.ts:153` |
| Cooloff period | 5 seconds | `batch-queue/index.ts:155` |

---

## How to Detect Stuck Batches

### Quick Check (SQL)

```sql
SELECT id, status, "createdAt", "runCount", "completedCount"
FROM "BatchTaskRun"
WHERE status = 'PROCESSING'
AND "updatedAt" < NOW() - INTERVAL '15 minutes';
```

If this returns rows, you have stuck batches.

### Check Redis for Leaked Tokens

```bash
ssh root@your-server-ip

# Check concurrency token count (should be 0 when idle, always < BATCH_CONCURRENCY_LIMIT_DEFAULT)
docker exec redis-your-service-uuid redis-cli SCARD engine:batch:concurrency:tenant:your-environment-id

# List the actual tokens (for investigation)
docker exec redis-your-service-uuid redis-cli SMEMBERS engine:batch:concurrency:tenant:your-environment-id
```

### Check Master Queue for Stale Entries

```bash
# Count entries in master queue (across shards)
docker exec redis-your-service-uuid redis-cli ZCARD engine:batch:master:0
docker exec redis-your-service-uuid redis-cli ZCARD engine:batch:master:1

# List first 20 entries
docker exec redis-your-service-uuid redis-cli ZRANGE engine:batch:master:0 0 19
```

Cross-reference batch IDs with the DB — if they're `COMPLETED` in the DB but still in the master queue, they're stale.

### Automated Monitoring

Use the monitoring script at `scripts/monitor-batch-queue.sh` (see below) via cron:

```bash
# Run every 5 minutes
*/5 * * * * /path/to/scripts/monitor-batch-queue.sh >> /var/log/batch-monitor.log 2>&1
```

---

## How to Fix It (If It Happens Again)

### Step 1: Clean Stale Redis State

```bash
ssh root@your-server-ip

docker exec redis-your-service-uuid redis-cli <<'EOF'
# Remove leaked concurrency tokens
DEL engine:batch:concurrency:tenant:your-environment-id

# Reset env concurrency counter
DEL engine:batch:env_concurrency:your-environment-id

# Clean up master queue shards (webapp re-populates on restart)
DEL engine:batch:master:0
DEL engine:batch:master:1

# Reset DRR deficit counters (re-initialized on restart)
DEL engine:batch:drr:deficit
EOF
```

> **Note**: Replace `your-environment-id` with your environment ID if different.
> Find it with: `SELECT id FROM "RuntimeEnvironment" LIMIT 10;`

### Step 2: Fix Stuck Batches in DB

```sql
-- Find stuck batches
SELECT id, status, "createdAt", "runCount"
FROM "BatchTaskRun"
WHERE status = 'PROCESSING'
AND "updatedAt" < NOW() - INTERVAL '15 minutes';

-- Mark them as COMPLETED (replace IDs with actual stuck batch IDs)
UPDATE "BatchTaskRun"
SET status = 'COMPLETED', "updatedAt" = NOW(), "completedAt" = NOW()
WHERE id IN ('STUCK_BATCH_ID_1', 'STUCK_BATCH_ID_2');

-- Complete their BATCH waitpoints so parent runs can continue
UPDATE "Waitpoint"
SET status = 'COMPLETED', "completedAt" = NOW(), "outputIsError" = true
WHERE "idempotencyKey" IN ('STUCK_BATCH_ID_1', 'STUCK_BATCH_ID_2')
  AND type = 'BATCH';
```

### Step 3: Restart Webapp

Restart from the Coolify dashboard (the CLI token is read-only):

1. Go to https://your-coolify-instance.example.com
2. Navigate to the webapp service (`your-webapp-service-uuid`)
3. Click Restart

This re-initializes all BatchQueue consumers with clean Redis state.

### Step 4: Verify

```bash
# Redis concurrency should be empty
ssh root@your-server-ip 'docker exec redis-your-service-uuid redis-cli SCARD engine:batch:concurrency:tenant:your-environment-id'
# Expected: 0
```

```sql
-- No stuck batches
SELECT COUNT(*) FROM "BatchTaskRun"
WHERE status = 'PROCESSING'
AND "updatedAt" < NOW() - INTERVAL '15 minutes';
-- Expected: 0
```

Trigger a test batch to confirm child runs are created and complete.

---

## Source Code References

Key files in the [Trigger.dev repo](https://github.com/triggerdotdev/trigger.dev):

| File | What It Does |
|------|-------------|
| `apps/webapp/app/env.server.ts` (lines 531-965) | All batch-related env vars and defaults |
| `packages/redis-worker/src/fair-queue/index.ts` | FairQueue: message lifecycle, completeMessage (line 1053), reclaim loop (line 1342) |
| `packages/redis-worker/src/fair-queue/concurrency.ts` | Concurrency limiter: reserve (SADD, line 285), release (SREM, line 103) |
| `packages/redis-worker/src/fair-queue/visibility.ts` | Visibility timeout: reclaim timed-out messages (line 379) |
| `internal-packages/run-engine/src/batch-queue/index.ts` | BatchQueue: consumer loop (line 614), handleMessage (line 692), config (line 141) |
| `internal-packages/run-engine/src/batch-queue/completionTracker.ts` | Idempotent completion tracking, cleanup |
| `apps/webapp/app/v3/runEngineHandlers.server.ts` (lines 645-805) | processItemCallback: creates TaskRun records |

---

## Infrastructure Quick Reference

Fill in your own values:

| Resource | How to Find |
|----------|-------------|
| Webapp server | Your Coolify server IP (SSH: `root@<ip>`) |
| Coolify dashboard | Your Coolify instance URL |
| Webapp service UUID | Coolify dashboard → service settings |
| Worker service UUID | Coolify dashboard → service settings |
| Redis container | `docker ps \| grep redis` on your server |
| Postgres container | `docker ps \| grep postgres` on your server |
| Environment ID | `SELECT id FROM "RuntimeEnvironment" LIMIT 10;` in Postgres |
