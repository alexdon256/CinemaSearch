# Complete Server Setup Guide

This guide provides step-by-step instructions to set up and configure your CineStream server from scratch to a fully working production deployment.

## Prerequisites

Before starting, ensure you have:

- **Clear Linux OS** installed on Intel architecture
- **Root access** (sudo privileges)
- **Internet connection** for downloading packages and MongoDB
- **Public IP address** (for domain name resolution)
- **Domain name** (optional, but required for HTTPS)
- **Anthropic API key** (for Claude AI scraping)

## Complete Setup Steps

### Step 1: Initialize Server Infrastructure

This step installs all required system packages and services.

```bash
# Navigate to your project directory
cd /path/to/CinemaSearch

# Initialize the server (installs MongoDB, Nginx, Python, etc.)
sudo ./deploy.sh init-server
```

**What this does:**
- Updates Clear Linux OS
- Installs Python 3, Nginx, Git, Node.js, and other required bundles
- Downloads and installs MongoDB 7.0.0
- Installs Claude CLI tools
- Creates directory structure (`/var/www`)
- Configures CPU affinity management
- **Automatically deploys application:**
  - Copies application files to `/var/www/cinestream`
  - Creates Python virtual environment
  - Installs all Python dependencies
  - Creates `.env` file template (with auto-generated SECRET_KEY)
  - Creates `.deploy_config` file
  - Initializes database (if API key is configured)
  - Creates systemd services for 10 worker processes
  - Starts all application processes
  - Configures firewall (ports 80 and 443)
- Starts MongoDB and Nginx services
- Sets up auto-start configuration

**Expected output:** You should see success messages for each component, including application deployment.

**Important:** The `.env` file is created with a template. You **must** update the `ANTHROPIC_API_KEY` before the application will work properly.

**Verify installation:**
```bash
# Check MongoDB is running
sudo systemctl status mongodb.service

# Check Nginx is running
sudo systemctl status nginx.service

# Check application processes
sudo ./deploy.sh status

# Test MongoDB connection
/opt/mongodb/bin/mongosh --eval "db.version()"
```

---

### Step 2: Configure Environment Variables

Update the `.env` file with your Anthropic API key.

```bash
# Edit .env file
sudo nano /var/www/cinestream/.env
```

**Update the following:**
- `ANTHROPIC_API_KEY` - Get from https://console.anthropic.com/
- `MONGO_URI` - Only if MongoDB authentication is enabled

**The file already contains:**
- Auto-generated `SECRET_KEY` (secure, no need to change)
- Default `MONGO_URI` (works without authentication)
- Default `CLAUDE_MODEL=haiku` (fastest/cheapest option)

**After updating, restart services:**
```bash
# Restart all application processes to load new .env
sudo systemctl restart cinestream@*.service

# Verify processes are running
sudo ./deploy.sh status
```

**If database wasn't initialized (because API key was missing), initialize it now:**
```bash
cd /var/www/cinestream
# Clear Linux requires using venv Python directly (not system Python)
./venv/bin/python src/scripts/init_db.py
```

**Note:** Clear Linux requires all Python code to run in a virtual environment. The deploy script automatically configures all systemd services to use the venv Python (`$APP_DIR/venv/bin/python`). When running commands manually, always use the venv Python directly.

---

### Step 3: Configure Domain

Set up Nginx to route your domain to the application.

```bash
# Set domain (app name is auto-detected)
sudo ./deploy.sh set-domain movies.example.com
```

**What this does:**
- Auto-detects your application (`cinestream`)
- Updates `.deploy_config` with domain name
- Generates Nginx configuration with upstream backend (10 processes)
- Configures HTTP (port 80) with HTTPS redirect:
  - Domain-specific HTTP server block redirects to HTTPS
  - Catch-all HTTP server block handles IP address and other hostname requests
  - Supports both IPv4 and IPv6
  - Preserves Let's Encrypt ACME challenge path for certificate renewal
- Configures HTTPS (port 443) with SSL placeholders
- Tests and reloads Nginx

**Verify Nginx configuration:**
```bash
sudo nginx -t
sudo systemctl status nginx.service
```

**HTTP to HTTPS Redirect Behavior:**
- All HTTP requests to your domain automatically redirect to HTTPS (301 permanent redirect)
- HTTP requests to your server's IP address also redirect to HTTPS using your configured domain
- Let's Encrypt ACME challenges are allowed on HTTP (required for certificate renewal)
- Both IPv4 and IPv6 are supported
- Full URL paths and query parameters are preserved in redirects

**Test the redirect:**
```bash
# Should redirect to HTTPS
curl -I http://movies.example.com

# Should also redirect (if accessing by IP)
curl -I http://YOUR_SERVER_IP
```

---

### Step 4: Configure DNS

Point your domain to your server's IP address.

1. **Get your server's public IP:**
   ```bash
   curl ifconfig.me
   ```

2. **Configure DNS A Record:**
   - Log in to your DNS provider (Cloudflare, Namecheap, GoDaddy, etc.)
   - Create an **A Record**:
     - **Type**: A
     - **Name**: `movies` (or `@` for root domain)
     - **Value**: Your server's IP address
     - **TTL**: 3600 (or default)

3. **Wait for DNS propagation:**
   - Typically takes 1-24 hours (can be up to 48 hours)
   - Check propagation: https://www.whatsmydns.net/

4. **Verify DNS is working:**
   ```bash
   dig +short movies.example.com A
   # Should return your server's IP
   ```

---

### Step 5: Install SSL Certificate

Once DNS is propagated, install the SSL certificate.

```bash
# Install SSL certificate
sudo ./deploy.sh install-ssl movies.example.com
```

**What this does:**
- Installs certbot if needed
- Verifies DNS is pointing to your server
- Requests SSL certificate from Let's Encrypt
- Automatically updates Nginx configuration with SSL paths
- Enables HTTPS with security headers (HSTS, TLS 1.2/1.3)
- Sets up automatic certificate renewal

**Note:** The HTTP to HTTPS redirect is already configured before SSL installation. After installing SSL, the redirect will work fully and HTTPS will be accessible.

**Expected output:** You should see success messages and certificate paths.

**Verify SSL:**
```bash
# Check certificate
sudo certbot certificates

# Test HTTPS
curl -I https://movies.example.com
```

---

### Step 6: Enable Auto-Start

Ensure all services start automatically on boot.

```bash
# Enable auto-start for all services
sudo ./deploy.sh enable-autostart
```

**What this does:**
- Ensures CPU affinity management is installed and enabled
- Enables MongoDB and Nginx to start on boot
- Enables all 10 worker processes to start on boot
- Enables CPU affinity timer (runs every 5 minutes)
- Enables master startup target

**Verify auto-start:**
```bash
# Check what's enabled
sudo systemctl list-unit-files | grep -E '(mongodb|nginx|cinestream)'

# Check CPU affinity timer
sudo systemctl status cinestream-cpu-affinity.timer
```

---

### Step 6.5: System Optimization (Optional but Recommended)

The `init-server` command automatically optimizes the system, but you can re-run optimizations or apply them separately:

```bash
# Optimize system for web server + MongoDB workload
sudo ./deploy.sh optimize-system
```

**What this does:**
- **Swap Configuration**: Sets `vm.swappiness=1` (minimal swap usage for database)
- **Filesystem**: Adds `noatime` mount option (disables last access time updates)
- **Kernel Parameters**: Optimizes TCP settings for high concurrency
  - Increases connection limits (`somaxconn=4096`)
  - Optimizes TCP buffers and timeouts
  - Increases file descriptor limits (65536)
- **MongoDB Performance**: 
  - Configures WiredTiger cache (50% of RAM, max 32GB)
  - Enables compression (Snappy)
  - Optimizes connection pools
  - Creates `/opt/mongodb/mongod.conf` with performance settings
- **Transparent Hugepages**: Disables for MongoDB (MongoDB requirement)
- **I/O Scheduler**: Optimizes for SSD (uses `none` or `mq-deadline` scheduler)
- **Readahead**: Sets optimal readahead for MongoDB data device

**Note:** Some optimizations require a reboot to take full effect. The script will warn you about this.

**Verify optimizations:**
```bash
# Check swappiness
cat /proc/sys/vm/swappiness  # Should be 1

# Check kernel parameters
sysctl net.core.somaxconn  # Should be 4096

# Check MongoDB config
cat /opt/mongodb/mongod.conf

# Check transparent hugepages (should be never)
cat /sys/kernel/mm/transparent_hugepage/enabled
```

---

### Step 7: Verify Everything Works

Test the complete setup.

```bash
# 1. Check all services are running
sudo ./deploy.sh status

# 2. Test local access
curl http://localhost:8001

# 3. Test HTTP redirect (if domain is configured)
curl -I http://movies.example.com  # Should return 301 redirect to HTTPS

# 4. Test HTTPS (after SSL is installed)
curl https://movies.example.com

# 5. Check MongoDB connection
/opt/mongodb/bin/mongosh movie_db --eval "db.stats()"

# 6. Check CPU affinity
ps -eo pid,cmd,psr | grep -E '(mongod|nginx|main.py)'
```

**Expected results:**
- All 10 processes running on ports 8001-8010
- MongoDB running on P-cores (0-5)
- Nginx running on P-cores (0-5)
- Python workers running on E-cores (6-13)
- Website accessible via domain with HTTPS

---

## Quick Reference: Complete Command Sequence

Here's the complete sequence of commands for a fresh setup:

```bash
# 1. Initialize server (automatically deploys application)
sudo ./deploy.sh init-server

# 2. Configure environment variables
sudo nano /var/www/cinestream/.env  # Update ANTHROPIC_API_KEY
sudo systemctl restart cinestream@*.service

# 3. Initialize database (if not done automatically)
cd /var/www/cinestream
source venv/bin/activate
python src/scripts/init_db.py
deactivate

# 4. Configure domain
sudo ./deploy.sh set-domain movies.example.com

# 5. Configure DNS (in your DNS provider's panel)
# Point A record to your server's IP

# 6. Install SSL (after DNS propagates)
sudo ./deploy.sh install-ssl movies.example.com

# 7. Enable auto-start (if not already enabled)
sudo ./deploy.sh enable-autostart

# 8. Re-apply system optimizations (optional, already done in init-server)
sudo ./deploy.sh optimize-system
```

---

## Troubleshooting

### MongoDB Won't Start

```bash
# Check logs
sudo journalctl -u mongodb.service -n 50

# Check permissions
ls -la /opt/mongodb/data

# Check disk space
df -h

# Restart MongoDB
sudo systemctl restart mongodb.service
```

### Nginx Won't Start

```bash
# Test configuration
sudo nginx -t

# Check logs
sudo journalctl -u nginx.service -n 50

# Check if ports are in use
sudo netstat -tulpn | grep -E ':(80|443)'

# Reload Nginx
sudo systemctl reload nginx.service
```

### Application Processes Won't Start

```bash
# Check environment variables
cat /var/www/cinestream/.env

# Check logs
sudo journalctl -u cinestream@8001.service -n 50

# Test manually
cd /var/www/cinestream
source venv/bin/activate
python src/main.py --port 8001
```

### HTTP to HTTPS Redirect Not Working

```bash
# Check Nginx configuration
sudo nginx -t

# Check if HTTP server block exists
sudo grep -A 10 "listen 80" /etc/nginx/conf.d/cinestream.conf

# Test redirect manually
curl -I http://movies.example.com  # Should return 301

# Check Nginx logs
sudo tail -f /var/log/nginx/cinestream_error.log

# Reload Nginx
sudo systemctl reload nginx.service
```

### SSL Certificate Installation Fails

```bash
# Check DNS
dig +short movies.example.com A

# Check port 80 is accessible
curl -I http://movies.example.com

# Check firewall
sudo firewall-cmd --list-services

# Try manual installation
sudo certbot certonly --webroot -w /var/www/html -d movies.example.com
```

### CPU Affinity Not Working

```bash
# Check CPU affinity service
sudo systemctl status cinestream-cpu-affinity.service

# Check timer
sudo systemctl status cinestream-cpu-affinity.timer

# Manually set affinity
sudo /usr/local/bin/cinestream-set-cpu-affinity.sh all

# Check process affinity
taskset -p $(pgrep -f "main.py.*--port")
```

---

## Server Cleanup and Redeployment

If you need to start over:

```bash
# Remove all CineStream components (preserves MongoDB)
sudo ./deploy.sh uninit-server

# Or remove everything including MongoDB
sudo ./deploy.sh uninit-server yes
```

After cleanup, you can run `init-server` again to start fresh.

---

## System Optimization

The deployment script includes comprehensive system optimization for web server + MongoDB workloads. These optimizations are automatically applied during `init-server`, but can be re-applied or run separately:

### Available Optimizations

**Run optimization:**
```bash
sudo ./deploy.sh optimize-system
```

**Optimizations include:**
- **Memory Management**: Low swappiness (1), optimized dirty ratios
- **Filesystem**: `noatime` mount option for better I/O performance
- **Network**: TCP tuning for high concurrency (4096 connections, optimized buffers)
- **MongoDB**: WiredTiger cache sizing, compression, connection pools
- **Kernel**: Transparent hugepages disabled, I/O scheduler optimization
- **File Descriptors**: Increased limits (65536) for web server workloads

**When to re-run:**
- After system memory changes
- After MongoDB version updates
- If you notice performance degradation
- After major system updates

**Note:** Some optimizations (like `noatime` in `/etc/fstab`) require a reboot to take full effect.

## Next Steps

After completing setup:

1. **Monitor Services**: Use `sudo ./deploy.sh status` regularly
2. **Check Logs**: Monitor application and system logs
3. **Update Regularly**: Run `sudo swupd update` for OS updates
4. **Backup**: Regularly backup `.env` file and MongoDB data
5. **Optimize**: Re-run `optimize-system` after major changes
6. **Review Documentation**: 
   - [ARCHITECTURE.md](ARCHITECTURE.md) - System design
   - [CPU_AFFINITY.md](CPU_AFFINITY.md) - CPU configuration
   - [SITES.md](SITES.md) - Service management
   - [PERFORMANCE.md](PERFORMANCE.md) - Performance analysis

---

## Security Considerations

- **Change default passwords** for MongoDB (if authentication is enabled)
- **Use strong SECRET_KEY** in `.env` file
- **Keep `.env` file secure** (permissions 600)
- **Configure firewall** to restrict access
- **Set up SSH key authentication** instead of passwords
- **Regular updates**: Run `sudo swupd update` regularly
- **Monitor logs**: Check MongoDB and Nginx logs regularly

---

## Support

For issues:
- Check logs: `sudo journalctl -xe`
- MongoDB logs: `/opt/mongodb/logs/mongod.log`
- Nginx logs: `/var/log/nginx/error.log`
- Application logs: `sudo journalctl -u cinestream@*.service`
- [Clear Linux Documentation](https://docs.clearlinux.org/)
