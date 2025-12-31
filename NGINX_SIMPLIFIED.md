# CineStream Nginx Configuration - Simplified

## Summary of Changes

The `deploy.sh` script has been significantly simplified:

### What Was Changed
1. **Removed Over 1,100 Lines of Duplicate Code**
   - File reduced from 5,464 lines to 4,320 lines
   - Removed duplicate `enable_internet_access()` functions
   - Removed complex welcome page disabling logic
   - Removed redundant nginx configuration code

2. **Simplified `configure_nginx_localhost()` Function**
   - **Before**: ~1,200+ lines with complex logic for:
     - Welcome page disabling across multiple directories
     - Python scripts for nginx.conf parsing
     - Complex SSL redirection logic
     - Duplicate config file checks
   - **After**: ~100 lines with clean, straightforward configuration

### New Standard Nginx Configuration

The simplified configuration creates `/etc/nginx/conf.d/cinestream.conf` with:

```nginx
# CineStream - Simple Network Access Configuration
upstream cinestream_backend {
    ip_hash;  # Sticky sessions for load balancing
    server 127.0.0.1:8001;
    server 127.0.0.1:8002;
    server 127.0.0.1:8003;
    server 127.0.0.1:8004;
    server 127.0.0.1:8005;
    server 127.0.0.1:8006;
    server 127.0.0.1:8007;
    server 127.0.0.1:8008;
    server 127.0.0.1:8009;
    server 127.0.0.1:8010;
    server 127.0.0.1:8011;
    server 127.0.0.1:8012;
    server 127.0.0.1:8013;
    server 127.0.0.1:8014;
    server 127.0.0.1:8015;
    server 127.0.0.1:8016;
    server 127.0.0.1:8017;
    server 127.0.0.1:8018;
    server 127.0.0.1:8019;
    server 127.0.0.1:8020;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;  # Responds to any IP or hostname
    
    # Main application
    location / {
        proxy_pass http://cinestream_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # Health check
    location /health {
        access_log off;
        return 200 "CineStream OK\n";
        add_header Content-Type text/plain;
    }
}
```

### How to Use

**Run the simplified deployment:**
```bash
sudo ./deploy.sh fix-localhost
```

This will:
1. Detect your CineStream installation
2. Create a clean, standard nginx configuration
3. Remove conflicting default configurations
4. Test and restart nginx
5. Verify that nginx is listening on port 80

**Expected Output:**
```
[INFO] Configuring Nginx for localhost/network access...
[INFO] Creating simple nginx configuration...
[INFO] Backend: 20 instances starting at port 8001
[SUCCESS] Nginx configuration created: /etc/nginx/conf.d/cinestream.conf
[INFO] Removing conflicting default configurations...
[INFO] Testing nginx configuration...
[SUCCESS] Configuration test passed
[INFO] Restarting nginx...
[SUCCESS] Nginx is running and listening on port 80

✓ CineStream is now accessible at:
  - http://localhost/
  - http://127.0.0.1/
  - http://<your-server-ip>/

To enable internet access: sudo ./deploy.sh enable-internet-access
```

### Access Your Application

After deployment, you can access CineStream from:

1. **On the server itself:**
   - `http://localhost/`
   - `http://127.0.0.1/`

2. **From other devices on your local network:**
   - `http://192.168.x.x/` (your server's IP address)
   - Find your server IP: `ip addr show` or `hostname -I`

3. **Enable internet access** (requires firewall configuration):
   ```bash
   sudo ./deploy.sh enable-internet-access
   ```

### Benefits of the Simplification

1. **Easier to Understand**: Standard nginx configuration that any nginx user can read
2. **Easier to Debug**: No complex Python scripts or multi-step welcome page disabling
3. **More Reliable**: Fewer moving parts = fewer points of failure
4. **Standard Approach**: Uses nginx best practices
5. **Network Ready**: `server_name _;` catches all incoming requests to any IP or hostname

### Configuration Files

- **Main config**: `/etc/nginx/conf.d/cinestream.conf`
- **Disabled configs**: 
  - `/etc/nginx/sites-enabled/default` (removed)
  - `/etc/nginx/conf.d/default.conf` (removed)
  - `/etc/nginx/conf.d/localhost.conf` (renamed to `.disabled`)

### Troubleshooting

**If you cannot access the website from another machine on your local network:**

1. **Check if firewall is configured:**
   ```bash
   # For firewalld (Arch/CachyOS)
   sudo firewall-cmd --list-all
   
   # Should show http and https services allowed
   # If not, run:
   sudo ./deploy.sh enable-internet-access
   ```

2. **Check if nginx is listening on all interfaces (not just localhost):**
   ```bash
   sudo ss -tlnp | grep :80
   # Should show: 0.0.0.0:80 or *:80 (not 127.0.0.1:80)
   ```

3. **Check nginx status:**
   ```bash
   sudo systemctl status nginx
   ```

4. **Test nginx configuration:**
   ```bash
   sudo nginx -t
   ```

5. **Check nginx error log:**
   ```bash
   sudo tail -20 /var/log/nginx/error.log
   ```

6. **Find your server's IP address:**
   ```bash
   ip addr show | grep "inet " | grep -v 127.0.0.1
   # Or:
   hostname -I
   ```

7. **Test from the server itself:**
   ```bash
   curl http://localhost
   curl http://127.0.0.1
   ```

8. **Test from another machine:**
   ```bash
   # Replace with your server's IP
   curl http://192.168.x.x
   ```

**If firewall is blocking access:**

The `fix-localhost` command now automatically configures the firewall. If you still have issues, run:

```bash
sudo ./deploy.sh enable-internet-access
```

This will:
- Configure firewall to allow HTTP/HTTPS
- Verify nginx is listening on all interfaces
- Check that the configuration accepts all IPs

### Domain Configuration (Optional)

If you want to use a domain name later:

```bash
# Set domain
sudo ./deploy.sh set-domain yourdomain.com

# Install SSL certificate
sudo ./deploy.sh install-ssl yourdomain.com
```

This will create a separate domain-specific configuration that coexists with the network access configuration.

