# Network Access Troubleshooting Guide

If you cannot access CineStream from another machine on your local network, follow these steps:

## Quick Fix

Run this command on your server to ensure firewall and nginx are properly configured:

```bash
sudo ./deploy.sh fix-localhost
```

This will:
1. Configure nginx to listen on all interfaces
2. Configure firewall to allow HTTP (port 80)
3. Verify everything is working

## Manual Troubleshooting Steps

### 1. Check if Nginx is Listening on All Interfaces

```bash
# Check what nginx is listening on
sudo ss -tlnp | grep :80

# Should show: 0.0.0.0:80 (all interfaces) or *:80
# If it shows 127.0.0.1:80, nginx is only listening on localhost
```

**If nginx is only listening on 127.0.0.1:80:**
- Check `/etc/nginx/conf.d/cinestream.conf` - it should have `listen 80 default_server;`
- Restart nginx: `sudo systemctl restart nginx`

### 2. Check Firewall Configuration

#### For Firewalld (most common on Arch/CachyOS):

```bash
# Check if firewalld is running
sudo systemctl status firewalld

# Check if HTTP service is allowed
sudo firewall-cmd --list-services

# Should show: ssh http https

# If HTTP is missing, add it:
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload

# Verify it's added
sudo firewall-cmd --list-services
```

#### For UFW:

```bash
# Check UFW status
sudo ufw status

# Should show: 80/tcp ALLOW

# If port 80 is not allowed, add it:
sudo ufw allow 80/tcp

# Verify
sudo ufw status
```

#### For iptables (direct):

```bash
# Check iptables rules
sudo iptables -L -n | grep 80

# Should show: ACCEPT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:80
```

### 3. Find Your Server's IP Address

```bash
# Method 1: Using ip command
ip -4 addr show | grep inet | grep -v 127.0.0.1

# Method 2: Using hostname
hostname -I

# Method 3: Using ifconfig (if installed)
ifconfig | grep "inet " | grep -v 127.0.0.1
```

### 4. Test from the Server Itself

```bash
# Test localhost
curl -I http://localhost/

# Test using server IP
curl -I http://<your-server-ip>/

# Both should return HTTP 200 or 301/302
```

### 5. Test from Another Machine

From another machine on the same network:

```bash
# Test if you can reach the server
ping <your-server-ip>

# Test if port 80 is open
telnet <your-server-ip> 80
# Or use: nc -zv <your-server-ip> 80

# Test HTTP access
curl -I http://<your-server-ip>/
# Or open in browser: http://<your-server-ip>/
```

### 6. Check Nginx Configuration

```bash
# Test nginx configuration
sudo nginx -t

# Check nginx error log
sudo tail -20 /var/log/nginx/error.log

# Check nginx access log
sudo tail -20 /var/log/nginx/access.log
```

### 7. Check if Another Service is Using Port 80

```bash
# Check what's using port 80
sudo lsof -i :80
# Or: sudo ss -tlnp | grep :80
```

### 8. Common Issues and Solutions

#### Issue: "Connection refused" from another machine
- **Cause**: Firewall blocking port 80
- **Solution**: Run `sudo ./deploy.sh fix-localhost` or manually configure firewall (see step 2)

#### Issue: "Connection timed out" from another machine
- **Cause**: Router firewall or nginx not listening on all interfaces
- **Solution**: 
  1. Check nginx is listening on 0.0.0.0:80 (not 127.0.0.1:80)
  2. Check router firewall settings (if applicable)

#### Issue: Works on localhost but not from network
- **Cause**: Nginx only listening on localhost
- **Solution**: Ensure nginx config has `listen 80 default_server;` (not `listen 127.0.0.1:80;`)

#### Issue: Firewall rules not persisting after reboot
- **Cause**: Firewall service not enabled
- **Solution**: 
  ```bash
  # For firewalld
  sudo systemctl enable firewalld
  sudo systemctl start firewalld
  
  # For UFW
  sudo ufw enable
  ```

## Quick Diagnostic Script

Run this on your server to get a full diagnostic:

```bash
echo "=== Nginx Status ==="
sudo systemctl status nginx --no-pager | head -10

echo ""
echo "=== Nginx Listening ==="
sudo ss -tlnp | grep :80

echo ""
echo "=== Firewall Status ==="
if command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --list-services
elif command -v ufw &> /dev/null; then
    sudo ufw status
else
    sudo iptables -L -n | grep -E "80|http"
fi

echo ""
echo "=== Server IP Address ==="
ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1

echo ""
echo "=== Test Local Access ==="
curl -I http://localhost/ 2>&1 | head -1
```

## Still Not Working?

1. **Check router settings**: Some routers have client isolation that prevents devices from talking to each other
2. **Check Windows Firewall**: If testing from Windows, ensure Windows Firewall allows the connection
3. **Check SELinux**: If SELinux is enabled, it might be blocking nginx:
   ```bash
   sudo setsebool -P httpd_can_network_connect 1
   ```
4. **Check nginx error logs**: `sudo tail -50 /var/log/nginx/error.log`
5. **Try accessing from server's own IP**: `curl http://<server-ip>/` from the server itself

## Enable Full Internet Access

Once local network access is working, to enable access from the internet:

```bash
sudo ./deploy.sh enable-internet-access
```

This will:
- Configure firewall for internet access
- Verify nginx is listening on all interfaces
- Set up proper security rules

