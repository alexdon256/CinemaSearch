# Service Management Guide

This guide explains how to manage services and monitor the CineStream server infrastructure.

**Note:** This guide covers server infrastructure management only. Application deployment and site management are handled separately.

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

Ensures all services (MongoDB, Nginx, and all apps) start automatically when the server boots. This is also done automatically during `init-server`.

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

You can manage individual services using systemd:

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

Applications may have daily refresh timers that run at 06:00 AM (if configured).

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

### Application Won't Start

1. Check environment variables: `cat /var/www/<app_name>/.env`
2. Check MongoDB connection: Test MONGO_URI
3. Check logs: `sudo journalctl -u <app_name>@*.service`
4. Verify port availability: `sudo netstat -tulpn | grep <port>`
5. Verify application is properly deployed and configured

### Nginx Issues

1. Verify Nginx config: `sudo nginx -t`
2. Check Nginx logs: `sudo tail -f /var/log/nginx/error.log`
3. Reload Nginx: `sudo systemctl reload nginx`

### Processes Keep Restarting

1. Check application logs for errors
2. Verify Python dependencies: `source /var/www/<app_name>/venv/bin/activate && pip list`
3. Test application manually: `python /var/www/<app_name>/src/main.py --port 8001`

## Best Practices

1. **Monitor Resources**: Watch CPU and memory usage
2. **Update Regularly**: Keep dependencies and OS updated
3. **Log Rotation**: Configure log rotation for long-running services
4. **Regular Backups**: Backup `/var/www/<app_name>/.env` and database
5. **Monitor Logs**: Regularly check application and system logs

## Next Steps

- Understand architecture: [ARCHITECTURE.md](ARCHITECTURE.md)
- Review setup: [SETUP.md](SETUP.md)
- CPU affinity configuration: [CPU_AFFINITY.md](CPU_AFFINITY.md)
