# Distributed Trigger.dev Setup

This folder contains Docker Compose configurations for deploying Trigger.dev across multiple servers, enabling horizontal scaling of workers for high-concurrency workloads.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│              COOLIFY SERVER 1 (WEBAPP)                      │
│  trigger │ postgres │ redis │ clickhouse │ electric │ etc  │
└─────────────────────────────────────────────────────────────┘
                              │
              TRIGGER_API_URL (HTTPS)
                              │
     ┌────────────────────────┼────────────────────────┐
     ▼                        ▼                        ▼
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│ COOLIFY      │      │ COOLIFY      │      │ COOLIFY      │
│ SERVER 2     │      │ SERVER 3     │      │ SERVER N     │
│ (Worker)     │      │ (Worker)     │      │ (Worker)     │
│              │      │              │      │              │
│ supervisor   │      │ supervisor   │      │ supervisor   │
│ docker-proxy │      │ docker-proxy │      │ docker-proxy │
└──────────────┘      └──────────────┘      └──────────────┘
```

- **Webapp Server**: Hosts the Trigger.dev dashboard, API, and all databases
- **Worker Servers**: Execute tasks by connecting to the webapp via `TRIGGER_API_URL`

## Prerequisites

- Multiple servers added to Coolify
- Network connectivity between servers (workers must reach webapp and registry URLs)
- Docker and Docker Compose on all servers

## Folder Structure

```
distributed/
├── README.md           # This file
├── webapp/
│   ├── docker-compose.yaml   # Webapp + databases (deploy on main server)
│   └── .env-example          # Environment template
└── worker/
    ├── docker-compose.yaml   # Workers only (deploy on additional servers)
    └── .env-example          # Environment template
```

## Deployment Steps

### Step 1: Deploy Webapp (Main Server)

1. **Create service in Coolify**:
   - Go to your Coolify project
   - Add new resource from this Git repository
   - Set **Base Directory** to `distributed/webapp`
   - Select Docker Compose as build pack

2. **Configure ports**:
   - Webapp: `:3000` (assign domain, e.g., `trigger.yourdomain.com`)
   - Registry: `:5000` (assign domain, e.g., `registry.yourdomain.com`)

3. **Set environment variables**:
   - Copy from `distributed/webapp/.env-example`
   - Update `DOCKER_RUNNER_NETWORKS` after first deploy
   - **Change registry credentials before production!**

4. **Deploy** and wait for all services to be healthy

5. **Get the worker token**:
   ```bash
   # SSH into the webapp server or use Coolify terminal
   docker logs <trigger-container-name> 2>&1 | grep -A15 "Worker Token"
   ```

   The token looks like: `tr_wgt_fgfAEjsTmvl4lowBLTbP7Xo563UlnVa206mr9uW6`

6. **Note down these values** for worker setup:
   - `TRIGGER_API_URL`: `https://trigger.yourdomain.com`
   - `DOCKER_REGISTRY_URL`: `https://registry.yourdomain.com`
   - `TRIGGER_WORKER_TOKEN`: (from step 5)
   - `MANAGED_WORKER_SECRET`: (Coolify's `SERVICE_PASSWORD_MANAGEDWORKER`)
   - `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`

### Step 2: Deploy Workers (Additional Servers)

For each worker server:

1. **Add server to Coolify** (if not already added)

2. **Create service in Coolify**:
   - Add new resource from this Git repository
   - Set **Base Directory** to `distributed/worker`
   - Select Docker Compose as build pack

3. **Set environment variables** (from Step 1):
   ```env
   TRIGGER_API_URL=https://trigger.yourdomain.com
   TRIGGER_WORKER_TOKEN=tr_wgt_xxxxxxxxxxxxx
   MANAGED_WORKER_SECRET=<same-as-webapp>
   DOCKER_REGISTRY_URL=https://registry.yourdomain.com
   REGISTRY_USERNAME=trigger
   REGISTRY_PASSWORD=<your-registry-password>
   DOCKER_RUNNER_NETWORKS=<coolify-network-on-this-server>
   ```

4. **Deploy** the worker

5. **Verify connection**:
   - Open Trigger.dev dashboard
   - Navigate to Settings > Workers
   - The new worker should appear as connected

6. **Repeat** for each additional worker server

### Step 3: Test the Setup

1. Deploy a simple task to your Trigger.dev project
2. Trigger multiple runs simultaneously
3. Check the dashboard to verify tasks are distributed across workers
4. Monitor logs on each worker:
   ```bash
   docker logs <supervisor-container-name> -f
   ```

## Scaling Guide

### Resource Requirements

For `small-1x` machine preset (0.5 vCPU, 0.5GB RAM per task):

| Server Specs | Concurrent Tasks | Workers for 1000 Concurrency |
|--------------|------------------|------------------------------|
| 16 vCPU / 32GB RAM | ~32 tasks | ~32 servers |
| 32 vCPU / 64GB RAM | ~64 tasks | ~16 servers |
| 64 vCPU / 128GB RAM | ~128 tasks | ~8 servers |
| 96 vCPU / 192GB RAM | ~192 tasks | ~6 servers |

**Note**: Leave 20% headroom for system overhead.

### Performance Tuning

Adjust these settings in worker `.env` based on server capacity:

```env
# More parallel dequeue operations (higher throughput)
DEQUEUE_CONSUMER_COUNT=10

# More jobs per dequeue cycle
DEQUEUE_RUN_COUNT=50

# Faster polling (more responsive, higher CPU)
DEQUEUE_INTERVAL_MS=500
```

## Troubleshooting

### Worker not connecting

1. **Check network connectivity**:
   ```bash
   curl -v https://trigger.yourdomain.com/healthcheck
   ```

2. **Verify worker token**:
   - Token must match exactly (no extra whitespace)
   - Check webapp logs if token was regenerated

3. **Check supervisor logs**:
   ```bash
   docker logs <supervisor-container> -f
   ```

### Tasks not running on workers

1. **Verify registry access**:
   ```bash
   docker login -u trigger registry.yourdomain.com
   ```

2. **Check `MANAGED_WORKER_SECRET`** matches between webapp and workers

3. **Verify network name**:
   - `DOCKER_RUNNER_NETWORKS` must match the actual Coolify network on each server

### High latency between workers

- Ensure workers are in the same region/datacenter
- Consider using private networking between servers
- Adjust `DEQUEUE_INTERVAL_MS` for responsiveness vs. resource usage

## Security Considerations

1. **Use HTTPS** for all URLs (webapp, registry)
2. **Change default registry credentials** before production
3. **Use private networking** between webapp and workers if possible
4. **Keep `MANAGED_WORKER_SECRET` secure** - it's used for worker authentication

## Updating

To update Trigger.dev:

1. **Webapp**: Redeploy the webapp service (databases will persist)
2. **Workers**: Redeploy each worker service

Workers will automatically reconnect after restart.
