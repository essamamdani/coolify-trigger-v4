# Trigger.dev Self-Hosted Setup

This repository contains a Docker Compose configuration for self-hosting Trigger.dev, a powerful workflow automation platform. The setup includes all necessary services: web application, PostgreSQL database, Redis, ElectricSQL, ClickHouse, Docker registry, MinIO object storage, and supervisor components.

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

After the first deployment, you need to configure **three critical settings** for the setup to work properly:

#### 1. Network Configuration (Required)
1. **Find Network Name**: After deployment, in your Coolify project:
   - Go to your project dashboard
   - Look for the **services** section showing your containers
   - You'll see a network ID like `xc324534265fdsfsfdfgfd4` in the services list
   - **Copy this network ID** (it's the long alphanumeric string)

2. **Add Environment Variable**: In Coolify, go to your project → Environment Variables → Add:
   ```
   DOCKER_RUNNER_NETWORKS=xc324534265fdsfsfdfgfd4
   ```
   (Replace with your actual network ID)

## Support

For issues specific to Trigger.dev, visit the [Trigger.dev documentation](https://trigger.dev/docs) or [GitHub repository](https://github.com/triggerdotdev/trigger.dev).

