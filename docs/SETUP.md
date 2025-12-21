# Server Setup Guide

This guide walks you through the initial setup of your Clear Linux server for CineStream deployment.

## Prerequisites

- **Clear Linux OS** installed on Intel architecture
- **Root access** (sudo privileges)
- **Internet connection** for downloading packages and MongoDB
- **Public IP address** (for domain name resolution)

## Server Cleanup and Redeployment

### Uninitializing the Server

If you need to completely remove all CineStream components (for redeployment or testing), use:

```bash
sudo ./deploy.sh uninit-server
```

This will remove:
- All deployed sites and applications
- All systemd services
- All Nginx configurations
- CPU affinity configurations
- CineStream systemd targets and timers
- Log files

**MongoDB is preserved by default** to prevent accidental data loss. To also remove MongoDB:

```bash
sudo ./deploy.sh uninit-server yes
```

This will prompt for additional confirmations before deleting:
- MongoDB data directory
- MongoDB installation

After uninitializing, you can run `init-server` again to start fresh.

## Step 1: Initial Server Preparation

### 1.1 Update Clear Linux

Ensure your system is up to date:

```bash
sudo swupd update
```

### 1.2 Initialize the Server

Run the master deployment script to initialize the server:

```bash
sudo ./deploy.sh init-server
```

This command will:

1. **Update Clear Linux OS** using `swupd update`
2. **Install Required Bundles:**
   - `python3-basic` - Python 3 runtime
   - `nginx` - Web server and reverse proxy
   - `git` - Version control
   - `openssh-server` - SSH access
   - `dev-utils` - Development utilities
   - `sysadmin-basic` - System administration tools
   - `nodejs-basic` - Node.js runtime (for Claude CLI)

3. **Install MongoDB Manually:**
   - Downloads MongoDB 7.0.0 from official source
   - Extracts to `/opt/mongodb`
   - Creates data directory at `/opt/mongodb/data`
   - Creates log directory at `/opt/mongodb/logs`
   - Sets up systemd service (`mongodb.service`)
   - Creates `mongodb` user for security

4. **Install Claude CLI:**
   - Installs `@anthropic-ai/claude-code` globally via NPM

5. **Create Directory Structure:**
   - Creates `/var/www` directory for web applications
   - Sets up Nginx configuration directories

6. **Start Services:**
   - Enables and starts MongoDB
   - Enables and starts Nginx

7. **Configure Auto-Start:**
   - Creates CineStream master startup target
   - Ensures all services start automatically on system boot
   - Coordinates startup order (MongoDB → Nginx → Apps)

### 1.3 Verify Installation

Check that services are running:

```bash
# Check MongoDB
sudo systemctl status mongodb.service

# Check Nginx
sudo systemctl status nginx.service

# Test MongoDB connection
/opt/mongodb/bin/mongo --eval "db.version()"
```

Expected output should show MongoDB version and Nginx running.

## Step 2: Manual MongoDB Configuration (Optional)

If you need to configure MongoDB authentication or other settings:

### 2.1 Access MongoDB Shell

```bash
/opt/mongodb/bin/mongo
```

### 2.2 Create Admin User (Recommended for Production)

```javascript
use admin
db.createUser({
  user: "admin",
  pwd: "your-secure-password",
  roles: [ { role: "userAdminAnyDatabase", db: "admin" } ]
})
```

### 2.3 Enable Authentication

Edit MongoDB configuration (if needed):

```bash
sudo nano /opt/mongodb/bin/mongod.conf
```

Add authentication settings and restart:

```bash
sudo systemctl restart mongodb.service
```

## Step 3: Firewall Configuration

Ensure ports are open:

```bash
# Allow HTTP (port 80)
sudo firewall-cmd --permanent --add-service=http

# Allow HTTPS (port 443)
sudo firewall-cmd --permanent --add-service=https

# Allow SSH (port 22)
sudo firewall-cmd --permanent --add-service=ssh

# Reload firewall
sudo firewall-cmd --reload
```

## Step 4: Verify Server Readiness

Run a quick check:

```bash
# Check Python version
python3 --version

# Check Nginx version
nginx -v

# Check MongoDB
/opt/mongodb/bin/mongod --version

# Check Node.js
node --version
```

## Troubleshooting

### MongoDB Won't Start

1. Check logs: `sudo journalctl -u mongodb.service`
2. Verify data directory permissions: `ls -la /opt/mongodb/data`
3. Check disk space: `df -h`

### Nginx Won't Start

1. Check configuration: `sudo nginx -t`
2. Check logs: `sudo journalctl -u nginx.service`
3. Verify port 80/443 are not in use: `sudo netstat -tulpn | grep -E ':(80|443)'`

### Package Installation Fails

1. Update Clear Linux: `sudo swupd update`
2. Check internet connectivity: `ping google.com`
3. Verify bundle names: `swupd search <bundle-name>`

## Next Steps

After completing server initialization:

1. **Deploy Your Application** - Deploy your application manually or through your own deployment process
2. **Manage Services** - See [SITES.md](SITES.md) for service management
3. **Review Architecture** - See [ARCHITECTURE.md](ARCHITECTURE.md)
4. **CPU Affinity** - See [CPU_AFFINITY.md](CPU_AFFINITY.md) for CPU configuration details

## Security Considerations

- **Change default passwords** for MongoDB admin user
- **Configure firewall** to restrict access
- **Set up SSH key authentication** instead of passwords
- **Regular updates**: Run `sudo swupd update` regularly
- **Monitor logs**: Check `/opt/mongodb/logs/mongod.log` and Nginx logs regularly

## Support

For issues specific to Clear Linux, consult:
- [Clear Linux Documentation](https://docs.clearlinux.org/)
- MongoDB logs: `/opt/mongodb/logs/mongod.log`
- System logs: `sudo journalctl -xe`

