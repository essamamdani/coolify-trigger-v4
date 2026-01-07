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

## Support

For issues specific to Trigger.dev, visit the [Trigger.dev documentation](https://trigger.dev/docs) or [GitHub repository](https://github.com/triggerdotdev/trigger.dev).
