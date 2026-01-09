# Trigger.dev Self-Hosted Setup

This repository contains Docker Compose configurations for self-hosting Trigger.dev, a powerful workflow automation platform. The setup includes all necessary services: web application, PostgreSQL database, Redis, ElectricSQL, ClickHouse, Docker registry, MinIO object storage, and supervisor components.

## Deployment Options

| Option | Use Case | Location |
|--------|----------|----------|
| **Single Server** | Small to medium workloads, simple setup | `docker-compose.yaml` (root) |
| **Distributed Workers** | High concurrency (1000+), horizontal scaling | [`distributed/`](./distributed/) folder |
| **External Databases** | Use Coolify's managed databases | `docker-compose.external-dbs.yaml` |

### Need High Concurrency?

For workloads requiring 1000+ concurrent tasks, use the **distributed setup** in the [`distributed/`](./distributed/) folder. This allows you to:

- Run workers on multiple servers
- Scale horizontally as needed
- Keep all workers managed by a single webapp

See [`distributed/README.md`](./distributed/README.md) for detailed setup instructions.

## Quick Start with Coolify v4

### Initial Setup

1. **Create New Project**: Go to Coolify v4 > Projects > New > Public GitHub
2. **Repository URL**: `https://github.com/essamamdani/coolify-trigger-v4.git`
3. **Build Settings**: Select "Build" > "docker-compose"
4. **Click Next**
5. **Add Ports**:
   - Web App: `:3000` (use Coolify generated URL or custom domain)
   - Registry: `:5000` (use Coolify generated URL or custom domain)
6. **Deploy** the application

### Post-Deployment Configuration

After the first deployment, you need to update the network configuration:

1. **Find Network Name**: In your Coolify project, locate the generated network name (it will be something like `project-xxx-net`)
2. **Update Environment**: Add to your `.env` file:
   ```
   DOCKER_RUNNER_NETWORKS=your-generated-network-name
   ```
3. **Redeploy** the application

### Security Setup (Required)

**Before going to production, update the registry credentials:**

1. **Generate new password file**:
   ```bash
   docker run --rm --entrypoint htpasswd httpd:2 -Bbn your-username your-secure-password > registry/auth.htpasswd
   ```

2. **Update environment variables** in Coolify:
   ```
   REGISTRY_USERNAME=your-username
   REGISTRY_PASSWORD=your-secure-password
   ```

3. **Redeploy** to apply security changes

## Services Overview

- **Web App**: Main Trigger.dev application (Port 3000)
- **PostgreSQL**: Primary database
- **Redis**: Caching and session storage
- **ElectricSQL**: Real-time database synchronization
- **ClickHouse**: Analytics and event storage
- **Registry**: Private Docker registry for deployments (Port 5000)
- **MinIO**: Object storage for packages and assets
- **Supervisor**: Manages worker execution and Docker operations

## Security Configuration

### Registry Authentication

The Docker registry uses HTTP Basic Authentication with default credentials that are **not secure** for production use.

**Default Settings:**
- Registry URL: `localhost:5000` (internal) or your Coolify domain
- Username: `trigger`
- Password: `very-secure-indeed`

### ⚠️ Important Security Notice

**You MUST change these default credentials before deploying to production!**

The default password `very-secure-indeed` is clearly insecure. To update the registry authentication:

1. Create the auth directory if it doesn't exist:
   ```bash
   mkdir -p registry
   ```

2. Generate a new password file using Docker:
   ```bash
   docker run \
     --entrypoint htpasswd \
     httpd:2 -Bbn your-username your-secure-password > registry/htpasswd
   ```

   On Windows, ensure correct encoding:
   ```powershell
   docker run --rm --entrypoint htpasswd httpd:2 -Bbn your-username your-secure-password | Set-Content -Encoding ASCII registry/htpasswd
   ```

   Replace `your-username` and `your-secure-password` with your desired credentials.

3. Update your environment variables to match:
   - `REGISTRY_USERNAME`: Set to your chosen username
   - `REGISTRY_PASSWORD`: Set to your secure password

4. Restart the registry service

For more information about Docker registry authentication, see the [official Docker Registry documentation](https://docs.docker.com/registry/configuration/#auth).

## Environment Variables

Coolify automatically generates all required `SERVICE_*` environment variables. You can optionally customize the following variables in your `.env` file (see `.env-example` for defaults):

- `POSTGRES_DB`: PostgreSQL database name (default: trigger)
- `REGISTRY_NAMESPACE`: Docker registry namespace (default: trigger)
- `NODE_MAX_OLD_SPACE_SIZE`: Node.js memory limit in MB (default: 1024)
- `TRIGGER_TELEMETRY_DISABLED`: Disable telemetry (default: 0)
- `INTERNAL_OTEL_TRACE_LOGGING_ENABLED`: Enable internal tracing logs (default: 0)

### ⚠️ Critical Security Variables

**These registry credentials are exposed to the public and MUST be changed before production deployment:**

- `REGISTRY_USERNAME`: Registry username (default: `trigger`) - **Change this!**
- `REGISTRY_PASSWORD`: Registry password (default: `very-secure-indeed`) - **Change this!**

Update these in your `.env` file and regenerate the `registry/auth.htpasswd` file as described in the Security Configuration section above.

## Networking

All services communicate through the `trigger-net` Docker network. The setup is designed to work behind Coolify's reverse proxy.

## Volumes

The following persistent volumes are used:
- `postgres-data`: PostgreSQL data
- `redis-data`: Redis data
- `clickhouse-data`: ClickHouse data
- `minio-data`: MinIO data
- `shared-data`: Shared data between webapp and supervisor
- `registry-data`: Docker registry storage

## Health Checks

All services include health checks to ensure proper startup and monitoring.

## Automatic Backups (Optional)

The setup includes optional backup services for PostgreSQL and Redis that can upload to any S3-compatible storage (AWS S3, MinIO, Backblaze B2, etc.).

### Enabling Backups

Backups are controlled by the `BACKUP_ENABLED` environment variable. To enable them:

1. Set `BACKUP_ENABLED=true` in your environment variables
2. Configure the S3 settings below
3. Redeploy

When disabled (default), the backup containers will start but remain idle (no resources consumed beyond minimal memory).

### Required Environment Variables

When backups are enabled, you must configure these S3 settings:

```env
# Enable backups
BACKUP_ENABLED=true

# S3 Configuration (Required for backups)
BACKUP_S3_ENDPOINT=https://s3.amazonaws.com      # S3-compatible endpoint URL
BACKUP_S3_BUCKET=my-backups                       # Bucket name
BACKUP_S3_ACCESS_KEY_ID=your-access-key          # S3 access key
BACKUP_S3_SECRET_ACCESS_KEY=your-secret-key      # S3 secret key
BACKUP_S3_REGION=us-east-1                        # S3 region (default: us-east-1)
```

### Backup Path Structure

Backups are automatically organized by your `DOCKER_RUNNER_NETWORKS` value:

```
s3://{BACKUP_S3_BUCKET}/{DOCKER_RUNNER_NETWORKS}/postgres/
s3://{BACKUP_S3_BUCKET}/{DOCKER_RUNNER_NETWORKS}/redis/
```

Example: If `DOCKER_RUNNER_NETWORKS=my-coolify-network`, backups appear at:
- `s3://my-backups/my-coolify-network/postgres/`
- `s3://my-backups/my-coolify-network/redis/`

### Optional Configuration

```env
# PostgreSQL Backup Settings
BACKUP_POSTGRES_SCHEDULE=0 2 * * *               # Cron schedule (default: daily at 2:00 AM)
BACKUP_POSTGRES_KEEP_DAYS=60                      # Retention in days (default: 60)

# Redis Backup Settings
BACKUP_REDIS_SCHEDULE=0 3 * * *                  # Cron schedule (default: daily at 3:00 AM)
BACKUP_REDIS_KEEP_DAYS=60                         # Retention in days (default: 60)
```

### Backup Schedule Format

The schedule uses standard cron format: `minute hour day month weekday`

Examples:
- `0 2 * * *` - Daily at 2:00 AM
- `0 */6 * * *` - Every 6 hours
- `0 2 * * 0` - Weekly on Sunday at 2:00 AM
- `0 2 1 * *` - Monthly on the 1st at 2:00 AM

### Using with MinIO (Local S3)

You can use the included MinIO service as your backup destination:

```env
BACKUP_ENABLED=true
BACKUP_S3_ENDPOINT=http://minio:9000
BACKUP_S3_BUCKET=backups
BACKUP_S3_ACCESS_KEY_ID=admin
BACKUP_S3_SECRET_ACCESS_KEY=${SERVICE_PASSWORD_MINIO}
BACKUP_S3_REGION=us-east-1
```

Note: You'll need to create the `backups` bucket in MinIO first.

### Manual Backup

To trigger an immediate backup (requires `BACKUP_ENABLED=true`):

```bash
# PostgreSQL
docker compose exec postgres-backup /backup.sh

# Redis
docker compose exec redis-backup /backup.sh
```

## Deployment with External Databases

If you want to use Coolify's native database resources (with built-in backup support), use the `docker-compose.external-dbs.yaml` file instead.

### Why Use External Databases?

- **Native Coolify Backups**: Each database gets automatic backup support via Coolify's S3 integration
- **Independent Scaling**: Scale databases separately from application services
- **Better Monitoring**: Individual health monitoring per database in Coolify UI
- **Easier Upgrades**: Update databases independently without redeploying the entire stack

### Setup Steps

1. **Deploy Databases as Coolify Resources**:
   - Go to Coolify > Resources > New > Database
   - Create the following databases:
     - **PostgreSQL 17** (enable `wal_level=logical` in settings)
     - **Redis 7**
     - **ClickHouse**
   - Create a MinIO service:
     - Go to Resources > New > Service > search "MinIO"

2. **Get Connection Strings**:
   After deploying each database, copy their connection URLs from Coolify.

3. **Deploy Application Stack**:
   - Create new resource from this repo
   - Select `docker-compose.external-dbs.yaml` as the compose file
   - Configure the following environment variables:

### Required Environment Variables

```env
# PostgreSQL (from Coolify PostgreSQL resource)
DATABASE_URL=postgresql://postgres:PASSWORD@postgres-uuid.internal:5432/trigger?schema=public&sslmode=disable
DIRECT_URL=postgresql://postgres:PASSWORD@postgres-uuid.internal:5432/trigger?schema=public&sslmode=disable

# Redis (from Coolify Redis resource)
REDIS_HOST=redis-uuid.internal
REDIS_PORT=6379
REDIS_PASSWORD=your-redis-password
REDIS_TLS_DISABLED=true

# ClickHouse (from Coolify ClickHouse resource)
CLICKHOUSE_URL=http://default:PASSWORD@clickhouse-uuid.internal:8123

# MinIO (from Coolify MinIO service)
OBJECT_STORE_BASE_URL=http://minio-uuid.internal:9000
OBJECT_STORE_ACCESS_KEY_ID=admin
OBJECT_STORE_SECRET_ACCESS_KEY=your-minio-password

# Application secrets (Coolify auto-generates these)
SERVICE_PASSWORD_SESSION=...
SERVICE_PASSWORD_MAGIC=...
SERVICE_PASSWORD_ENCRYPTION=...
SERVICE_PASSWORD_MANAGEDWORKER=...
SERVICE_PASSWORD_REGISTRY=...

# Registry and network settings
SERVICE_URL_TRIGGER=https://your-trigger-domain.com
SERVICE_FQDN_REGISTRY=registry.your-domain.com
SERVICE_URL_REGISTRY=https://registry.your-domain.com
REGISTRY_USERNAME=trigger
REGISTRY_PASSWORD=your-secure-password
DOCKER_RUNNER_NETWORKS=your-coolify-network
```

### Configuring Backups

Once databases are deployed as Coolify resources:

1. Go to **Settings** > **S3 Storages** in Coolify
2. Add your S3-compatible storage (AWS S3, MinIO, etc.)
3. For each database resource, go to **Backups** tab
4. Configure backup schedule and S3 destination

### Services in External DB Mode

| Service | Description |
|---------|-------------|
| trigger | Main Trigger.dev application |
| electric | ElectricSQL sync service |
| registry | Docker registry for deployments |
| supervisor | Worker supervisor |
| docker-proxy | Docker socket proxy |

## Local Development

### Running Locally

For local development, you can run:
```bash
docker-compose up -d
```

Monitor logs with:
```bash
docker-compose logs -f
```

### Deploying to Your Registry

Once your registry is running, you can deploy Trigger.dev workflows to it:

1. **Login to your registry**:
   ```bash
   docker login -u your-username -p 'your-secure-password' registry-domain-name
   ```

2. **Deploy using Trigger.dev CLI**:
   ```bash
   npx trigger.dev@latest deploy
   ```

This will build and deploy your workflows to your self-hosted Trigger.dev registry.

## Support

For issues specific to Trigger.dev, visit the [Trigger.dev documentation](https://trigger.dev/docs) or [GitHub repository](https://github.com/triggerdotdev/trigger.dev).