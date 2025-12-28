# Multiple Applications Guide

This guide explains how to deploy and manage multiple applications/websites on the same CineStream server.

## Overview

The CineStream deployment system supports running multiple independent applications on a single server. Each application is completely isolated with its own:

- Directory structure (`/var/www/<app-name>/`)
- Python virtual environment
- Environment variables (`.env` file)
- Port range (automatically assigned)
- Nginx configuration
- Domain configuration
- Systemd services

## Deploying Multiple Applications

### Deploy Your First Application

The first application is automatically deployed during `init-server`:

```bash
sudo ./deploy.sh init-server
```

This creates the `cinestream` app at `/var/www/cinestream/` with ports 8001-8020.

### Deploy Additional Applications

To deploy additional applications:

```bash
# Deploy a new application
sudo ./deploy.sh deploy-app myapp

# Deploy another application
sudo ./deploy.sh deploy-app blogapp
```

**What happens:**
1. Creates application directory: `/var/www/<app-name>/`
2. Copies application source code
3. Creates Python virtual environment
4. Installs Python dependencies
5. Creates `.env` file template
6. Creates `.deploy_config` with automatic port assignment
7. Creates systemd services for all worker processes
8. Starts all processes

### Port Assignment

Ports are automatically assigned to avoid conflicts:

- **First app** (`cinestream`): Ports 8001-8020 (20 processes)
- **Second app** (`myapp`): Ports 8021-8040 (20 processes)
- **Third app** (`blogapp`): Ports 8041-8060 (20 processes)
- And so on...

Each app uses 20 ports by default (configurable in `.deploy_config`).

## Configuring Domains

### Set Domain for an Application

```bash
# Auto-detect app (if only one exists)
sudo ./deploy.sh set-domain movies.example.com

# Specify app explicitly
sudo ./deploy.sh set-domain blog.example.com myapp
```

**What this does:**
- Updates the app's `.deploy_config` with the domain
- Generates Nginx configuration: `/etc/nginx/conf.d/<app-name>.conf`
- Configures HTTP → HTTPS redirect
- Configures HTTPS with SSL placeholders
- Tests and reloads Nginx

### Multiple Domains Example

```bash
# Configure domain for first app
sudo ./deploy.sh set-domain movies.example.com cinestream

# Configure domain for second app
sudo ./deploy.sh set-domain blog.example.com myapp

# Configure domain for third app
sudo ./deploy.sh set-domain shop.example.com shopapp
```

Each domain will route to its respective application.

## Managing Applications

### Check Status of All Apps

```bash
sudo ./deploy.sh status
```

This shows:
- All deployed applications
- Domain configuration for each
- Running processes count
- Port ranges
- Service user
- Auto-start status

### Start/Stop All Applications

```bash
# Start all apps
sudo ./deploy.sh start-all

# Stop all apps
sudo ./deploy.sh stop-all
```

### Start/Stop Specific App

```bash
# Start specific app's processes
sudo systemctl start myapp@*.service

# Stop specific app's processes
sudo systemctl stop myapp@*.service

# Restart specific app
sudo systemctl restart myapp@*.service
```

## Application Isolation

### Directory Structure

Each application has its own isolated directory:

```
/var/www/
├── cinestream/
│   ├── .env                    # App-specific environment variables
│   ├── .deploy_config          # Deployment configuration
│   ├── venv/                   # Python virtual environment
│   ├── src/                    # Application source code
│   └── static/                 # Static files
│
├── myapp/
│   ├── .env
│   ├── .deploy_config
│   ├── venv/
│   └── src/
│
└── blogapp/
    ├── .env
    ├── .deploy_config
    ├── venv/
    └── src/
```

### Configuration Files

Each app has its own `.deploy_config`:

```bash
# /var/www/cinestream/.deploy_config
APP_NAME=cinestream
START_PORT=8001
PROCESS_COUNT=20
DOMAIN_NAME="movies.example.com"

# /var/www/myapp/.deploy_config
APP_NAME=myapp
START_PORT=8021
PROCESS_COUNT=20
DOMAIN_NAME="blog.example.com"
```

### Environment Variables

Each app has its own `.env` file with isolated configuration:

```bash
# Edit app-specific .env
sudo nano /var/www/cinestream/.env
sudo nano /var/www/myapp/.env
```

### Nginx Configuration

Each app gets its own Nginx config file:

- `/etc/nginx/conf.d/cinestream.conf`
- `/etc/nginx/conf.d/myapp.conf`
- `/etc/nginx/conf.d/blogapp.conf`

Nginx routes traffic based on `server_name` in each config.

## Shared Resources

### MongoDB

All applications share the same MongoDB instance but can use different databases:

```bash
# App 1 uses: mongodb://127.0.0.1:27017/movie_db
# App 2 uses: mongodb://127.0.0.1:27017/blog_db
# App 3 uses: mongodb://127.0.0.1:27017/shop_db
```

Configure in each app's `.env` file.

### Nginx

All applications share the same Nginx instance. Nginx routes traffic based on domain names configured in each app's config file.

### System Resources

- **CPU**: All apps share CPU cores (with affinity optimization)
- **Memory**: Each app uses its own memory (isolated processes)
- **Network**: All apps share the same network interface

## Best Practices

### 1. Use Descriptive App Names

```bash
# Good
sudo ./deploy.sh deploy-app movies
sudo ./deploy.sh deploy-app blog
sudo ./deploy.sh deploy-app shop

# Avoid
sudo ./deploy.sh deploy-app app1
sudo ./deploy.sh deploy-app app2
```

### 2. Configure Domains Immediately

After deploying an app, configure its domain:

```bash
sudo ./deploy.sh deploy-app myapp
sudo ./deploy.sh set-domain myapp.example.com myapp
```

### 3. Monitor Resource Usage

Check resource usage per app:

```bash
# Check process count
sudo ./deploy.sh status

# Check memory usage
ps aux | grep -E "(cinestream|myapp|blogapp)" | grep "main.py"

# Check port usage
sudo ss -tln | grep -E ':(8001|8021|8041)'
```

### 4. Update Apps Independently

Each app can be updated independently:

```bash
# Update specific app
cd /var/www/myapp
git pull
./venv/bin/pip install -r requirements.txt
sudo systemctl restart myapp@*.service
```

## Troubleshooting

### Port Conflicts

If you see port conflicts, check assigned ports:

```bash
# Check .deploy_config files
cat /var/www/*/.deploy_config | grep START_PORT

# Check what's listening
sudo ss -tln | grep -E ':(8001|8021|8041)'
```

### Service Not Starting

Check app-specific logs:

```bash
# Check logs for specific app
sudo journalctl -u myapp@8021.service -n 50

# Check all processes for an app
sudo systemctl status myapp@*.service
```

### Domain Not Routing

Verify Nginx configuration:

```bash
# Check Nginx configs
ls -la /etc/nginx/conf.d/

# Test Nginx config
sudo nginx -t

# Check if domain is configured
grep -r "server_name" /etc/nginx/conf.d/
```

## Example: Deploying Three Applications

```bash
# 1. Initialize server (creates cinestream app)
sudo ./deploy.sh init-server

# 2. Configure first app's domain
sudo ./deploy.sh set-domain movies.example.com cinestream

# 3. Deploy second app
sudo ./deploy.sh deploy-app blogapp
sudo ./deploy.sh set-domain blog.example.com blogapp

# 4. Deploy third app
sudo ./deploy.sh deploy-app shopapp
sudo ./deploy.sh set-domain shop.example.com shopapp

# 5. Install SSL for all domains
sudo ./deploy.sh install-ssl movies.example.com
sudo ./deploy.sh install-ssl blog.example.com
sudo ./deploy.sh install-ssl shop.example.com

# 6. Check status
sudo ./deploy.sh status
```

**Result:**
- `movies.example.com` → cinestream app (ports 8001-8020)
- `blog.example.com` → blogapp (ports 8021-8040)
- `shop.example.com` → shopapp (ports 8041-8060)

All three apps running independently on the same server!

