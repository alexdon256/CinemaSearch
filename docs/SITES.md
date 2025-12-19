# Site Management Guide

This guide explains how to manage individual websites using the CineStream deployment script.

## Adding a New Site

### Prerequisites

Before adding a site, ensure:

1. **Domain Name is Configured** - DNS A record points to your server IP (see [DOMAINS.md](DOMAINS.md))
2. **Repository is Accessible** - Git repository URL is valid and accessible
3. **Server is Initialized** - `deploy.sh init-server` has been run

### Command Syntax

```bash
sudo ./deploy.sh add-site <repo_url> <domain_name> <app_name> [start_port] [process_count]
```

### Parameters

- **`repo_url`**: Git repository URL (HTTPS or SSH)
- **`domain_name`**: Fully qualified domain name (e.g., `example.com`)
- **`app_name`**: Internal application name (e.g., `movie_app`)
- **`start_port`**: Starting port number (default: `8001`)
- **`process_count`**: Number of worker processes (default: `12`)

### Example

```bash
sudo ./deploy.sh add-site \
  https://github.com/username/movie-app.git \
  movies.example.com \
  movie_app \
  8001 \
  12
```

### Interactive Configuration

During site addition, the script will prompt for:

1. **MONGO_URI**: MongoDB connection string
   ```
   mongodb://user:pass@127.0.0.1:27017/movie_db?authSource=admin
   ```

2. **ANTHROPIC_API_KEY**: Claude API key
   ```
   sk-ant-api03-...
   ```

3. **SECRET_KEY**: Flask session secret key
   ```
   (random secure string)
   ```

These values are saved to `/var/www/<app_name>/.env` with restricted permissions (600).

### What Happens During `add-site`

1. **Repository Cloning**: Clones source code to `/var/www/<app_name>/src`
2. **Virtual Environment**: Creates Python venv at `/var/www/<app_name>/venv`
3. **Dependencies**: Installs packages from `requirements.txt`
4. **Environment Variables**: Creates `.env` file with secrets
5. **Database Initialization**: Runs `scripts/init_db.py` to create schema
6. **Systemd Services**: Generates service files for each worker process
7. **Nginx Configuration**: Creates reverse proxy config with SSL
8. **SSL Certificate**: Obtains Let's Encrypt certificate
9. **Process Startup**: Starts all worker processes
10. **Daily Timer**: Sets up 06:00 AM refresh job

### Directory Structure Created

```
/var/www/<app_name>/
├── .env                    # Environment variables (secrets)
├── .deploy_config          # Deployment metadata
├── venv/                   # Python virtual environment
├── src/                    # Cloned source code
│   ├── main.py
│   ├── core/
│   └── scripts/
└── static/                 # Static assets (if any)
```

## Editing an Existing Site

### Command Syntax

```bash
sudo ./deploy.sh edit-site <app_name>
```

### What You Can Change

- **Domain Name**: Update DNS and SSL certificate
- **Start Port**: Change port range for worker processes
- **Process Count**: Scale up or down the number of workers

### Example

```bash
sudo ./deploy.sh edit-site movie_app
```

The script will:
1. Show current configuration
2. Prompt for new values (press Enter to keep current)
3. Stop old processes
4. Regenerate configurations
5. Start new processes

### Scaling Processes

To increase from 12 to 24 processes:

```bash
sudo ./deploy.sh edit-site movie_app
# When prompted: Enter new process count: 48
```

**Note**: Ensure port range doesn't conflict with other applications.

## Removing a Site

### Command Syntax

```bash
sudo ./deploy.sh remove-site <app_name>
```

### Example

```bash
sudo ./deploy.sh remove-site movie_app
```

### Safety Confirmation

The script requires typing `yes` to confirm deletion:

```
WARNING: This will permanently delete movie_app and all its data!
Are you sure? Type 'yes' to confirm: yes
```

### What Gets Removed

1. **All Worker Processes**: Stops and disables all systemd services
2. **Daily Timer**: Stops and removes refresh timer
3. **Systemd Files**: Removes service and timer files
4. **Nginx Config**: Removes site configuration
5. **Application Files**: Deletes `/var/www/<app_name>/` directory
6. **SSL Certificate**: Certificate remains but is unused

**Warning**: This action is **irreversible**. All application data, logs, and configurations are permanently deleted.

## Managing Services

### Start All Services

```bash
sudo ./deploy.sh start-all
```

Starts:
- MongoDB
- Nginx
- All application worker processes
- All daily refresh timers

### Stop All Services

```bash
sudo ./deploy.sh stop-all
```

Stops all services gracefully.

### Enable Auto-Start on Boot

```bash
sudo ./deploy.sh enable-autostart
```

Ensures all services (MongoDB, Nginx, and all apps) start automatically when the server boots. This is also done automatically during `init-server` and `add-site`.

### Check System Status

```bash
sudo ./deploy.sh status
```

Shows the status of all services including:
- Core services (MongoDB, Nginx)
- Auto-start status
- Application processes running/total
- Daily refresh timer status

### Individual Service Management

You can also manage individual services:

```bash
# Start a specific process
sudo systemctl start movie_app@8001.service

# Stop a specific process
sudo systemctl stop movie_app@8001.service

# Check status
sudo systemctl status movie_app@8001.service

# View logs
sudo journalctl -u movie_app@8001.service -f
```

## Monitoring and Logs

### View Application Logs

```bash
# All processes for an app
sudo journalctl -u "movie_app@*" -f

# Specific process
sudo journalctl -u movie_app@8001.service -f

# Last 100 lines
sudo journalctl -u movie_app@8001.service -n 100
```

### View Nginx Logs

```bash
# Access logs
sudo tail -f /var/log/nginx/access.log

# Error logs
sudo tail -f /var/log/nginx/error.log
```

### Check Process Status

```bash
# List all running processes
sudo systemctl list-units | grep movie_app

# Check if processes are listening
sudo netstat -tulpn | grep -E ':(8001|8002|8003)'
```

## Environment Variables

### Updating Environment Variables

Edit the `.env` file:

```bash
sudo nano /var/www/movie_app/.env
```

After editing, restart processes:

```bash
sudo systemctl restart movie_app@*.service
```

### Required Variables

- `MONGO_URI`: MongoDB connection string
- `ANTHROPIC_API_KEY`: Claude API key
- `SECRET_KEY`: Flask session secret

## Daily Refresh Job

Each site has a daily refresh timer that runs at 06:00 AM.

### Check Timer Status

```bash
sudo systemctl status movie_app-refresh.timer
```

### Manually Trigger Refresh

```bash
sudo systemctl start movie_app-refresh.service
```

### View Refresh Logs

```bash
sudo journalctl -u movie_app-refresh.service
```

## Troubleshooting

### Site Won't Start

1. Check environment variables: `cat /var/www/<app_name>/.env`
2. Check MongoDB connection: Test MONGO_URI
3. Check logs: `sudo journalctl -u <app_name>@*.service`
4. Verify port availability: `sudo netstat -tulpn | grep <port>`

### SSL Certificate Issues

1. Check DNS: `dig <domain_name>`
2. Verify Nginx config: `sudo nginx -t`
3. Check certbot logs: `sudo journalctl -u certbot`
4. Renew manually: `sudo certbot renew`

### Processes Keep Restarting

1. Check application logs for errors
2. Verify Python dependencies: `source /var/www/<app_name>/venv/bin/activate && pip list`
3. Test application manually: `python /var/www/<app_name>/src/main.py --port 8001`

## Best Practices

1. **Use Descriptive App Names**: Choose clear, unique names
2. **Port Management**: Keep track of port ranges to avoid conflicts
3. **Regular Backups**: Backup `/var/www/<app_name>/.env` and database
4. **Monitor Resources**: Watch CPU and memory usage
5. **Update Regularly**: Keep dependencies and OS updated
6. **Log Rotation**: Configure log rotation for long-running services

## Next Steps

- Configure domains: [DOMAINS.md](DOMAINS.md)
- Understand architecture: [ARCHITECTURE.md](ARCHITECTURE.md)
- Review setup: [SETUP.md](SETUP.md)

