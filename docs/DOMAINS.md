# Domain Configuration Guide

This guide explains how to configure domain names for your CineStream deployments. Proper DNS configuration is **critical** for SSL certificate provisioning and Nginx routing.

## Overview

Before running `deploy.sh add-site`, you must:

1. **Point DNS A Record** to your server's public IP address
2. **Wait for DNS Propagation** (can take up to 48 hours, typically 1-24 hours)
3. **Verify DNS Resolution** before running `add-site`

## Step 1: Get Your Server's Public IP

### Find Your Public IP

```bash
# Method 1: Using curl
curl ifconfig.me

# Method 2: Using dig
dig +short myip.opendns.com @resolver1.opendns.com

# Method 3: Check server network config
ip addr show
```

**Note**: This should be your **public/external IP**, not a private IP (192.168.x.x or 10.x.x.x).

## Step 2: Configure DNS A Record

### For Root Domain (example.com)

Create an **A Record** in your DNS provider's control panel:

```
Type: A
Name: @ (or leave blank, or "example.com")
Value: YOUR_SERVER_IP
TTL: 3600 (or default)
```

### For Subdomain (movies.example.com)

Create an **A Record**:

```
Type: A
Name: movies (or "movies.example.com")
Value: YOUR_SERVER_IP
TTL: 3600 (or default)
```

### Common DNS Providers

#### Cloudflare

1. Log in to Cloudflare Dashboard
2. Select your domain
3. Go to **DNS** → **Records**
4. Click **Add record**
5. Select **A** type
6. Enter name (or @ for root)
7. Enter IP address
8. Click **Save**

#### Namecheap

1. Log in to Namecheap
2. Go to **Domain List** → **Manage**
3. Navigate to **Advanced DNS**
4. Click **Add New Record**
5. Select **A Record**
6. Enter host (or @ for root)
7. Enter IP address
8. Click **Save**

#### GoDaddy

1. Log in to GoDaddy
2. Go to **My Products** → **DNS**
3. Click **Add** under **A Records**
4. Enter name (or @ for root)
5. Enter value (IP address)
6. Click **Save**

#### Google Domains

1. Log in to Google Domains
2. Click **DNS** in left sidebar
3. Scroll to **Custom resource records**
4. Add **A** record:
   - Name: @ or subdomain
   - IPv4 address: YOUR_SERVER_IP
5. Click **Add**

## Step 3: Verify DNS Propagation

### Check DNS Resolution

Before running `add-site`, verify DNS is pointing correctly:

```bash
# Check A record
dig +short example.com A

# Or using nslookup
nslookup example.com

# Or using host
host example.com
```

Expected output should show your server's IP address.

### Online DNS Checkers

Use these tools to check propagation globally:

- [whatsmydns.net](https://www.whatsmydns.net/)
- [dnschecker.org](https://dnschecker.org/)
- [mxtoolbox.com](https://mxtoolbox.com/DNSLookup.aspx)

**Important**: Wait until DNS shows your server IP in **all regions** before proceeding.

## Step 4: Handling Multiple Domains

### Root Domain vs. www Subdomain

The deployment script automatically handles both:

- `example.com` (root domain)
- `www.example.com` (www subdomain)

When you enter `example.com` as the domain name, the script configures Nginx for both.

### Multiple Subdomains

For different applications on different subdomains:

```bash
# App 1
sudo ./deploy.sh add-site <repo> movies.example.com movie_app 8001 12

# App 2
sudo ./deploy.sh add-site <repo> blog.example.com blog_app 8013 12
```

Each subdomain needs its own **A Record** pointing to the same IP.

### Same Domain, Different Ports

If you need multiple apps on the same domain but different paths:

This requires manual Nginx configuration. The deployment script is designed for one app per domain.

## Step 5: SSL Certificate Provisioning

### Automatic SSL with Let's Encrypt

The `add-site` command automatically:

1. Installs `certbot` (if not present)
2. Obtains SSL certificate via Let's Encrypt
3. Configures Nginx with SSL
4. Sets up automatic renewal

### SSL Certificate Requirements

For Let's Encrypt to work:

- ✅ DNS A record must point to server IP
- ✅ Port 80 must be accessible (for HTTP-01 challenge)
- ✅ Domain must be publicly resolvable
- ✅ No firewall blocking port 80

### Troubleshooting SSL

If SSL certificate fails:

1. **Check DNS**: `dig example.com` should return your IP
2. **Check Port 80**: `curl -I http://example.com` should connect
3. **Check Firewall**: Ensure port 80 is open
4. **Manual Certificate**: Run manually:
   ```bash
   sudo certbot certonly --nginx -d example.com -d www.example.com
   ```

### SSL Certificate Renewal

Certificates auto-renew via systemd timer. Check status:

```bash
sudo systemctl status certbot.timer
```

Renew manually if needed:

```bash
sudo certbot renew
```

## Step 6: Domain Input Format

### Correct Format

When running `add-site`, use:

```bash
# Root domain
sudo ./deploy.sh add-site <repo> example.com app_name

# Subdomain
sudo ./deploy.sh add-site <repo> movies.example.com app_name

# With www (handled automatically)
sudo ./deploy.sh add-site <repo> example.com app_name
# This configures both example.com AND www.example.com
```

### Incorrect Format

❌ Don't include protocol:
```
https://example.com  # WRONG
```

❌ Don't include trailing slash:
```
example.com/  # WRONG
```

❌ Don't include path:
```
example.com/app  # WRONG
```

## DNS Propagation Timeline

### Typical Propagation Times

- **Minimum**: 5 minutes (for some providers)
- **Average**: 1-4 hours
- **Maximum**: 48 hours (rare)

### Factors Affecting Propagation

1. **TTL Value**: Lower TTL = faster updates
2. **DNS Provider**: Some propagate faster than others
3. **Geographic Location**: Different regions may see changes at different times
4. **DNS Caching**: Local DNS caches may delay updates

### Best Practice

**Wait at least 1 hour** after creating DNS records before running `add-site`. Use DNS checkers to verify propagation globally.

## Common Issues

### Issue: DNS Not Resolving

**Symptoms**: `dig example.com` returns nothing or wrong IP

**Solutions**:
1. Verify A record in DNS provider
2. Check TTL hasn't expired
3. Wait longer for propagation
4. Clear local DNS cache: `sudo systemd-resolve --flush-caches`

### Issue: SSL Certificate Fails

**Symptoms**: Certbot error during `add-site`

**Solutions**:
1. Verify DNS: `dig example.com` must return your IP
2. Check port 80: `sudo netstat -tulpn | grep :80`
3. Check firewall: `sudo firewall-cmd --list-all`
4. Verify domain is publicly accessible: `curl http://example.com`

### Issue: Wrong IP in DNS

**Symptoms**: Domain points to old server IP

**Solutions**:
1. Update A record in DNS provider
2. Wait for propagation
3. Verify with: `dig example.com`

### Issue: Subdomain Not Working

**Symptoms**: Root domain works, subdomain doesn't

**Solutions**:
1. Verify subdomain A record exists
2. Check Nginx config includes subdomain
3. Verify SSL certificate includes subdomain

## Testing Domain Configuration

### Before Running `add-site`

Run these checks:

```bash
# 1. Check DNS resolution
dig +short example.com A

# 2. Check HTTP connectivity
curl -I http://example.com

# 3. Check port 80 is open
sudo netstat -tulpn | grep :80

# 4. Verify firewall allows HTTP
sudo firewall-cmd --list-services | grep http
```

All checks should pass before proceeding.

## Security Considerations

### DNS Security

- Use **DNSSEC** if available from your provider
- Use **strong TTL values** (3600 seconds recommended)
- Monitor DNS changes for unauthorized modifications

### SSL/TLS Security

- Let's Encrypt certificates are valid for **90 days**
- Auto-renewal is configured automatically
- Use **TLS 1.2+** only (configured in Nginx)

## Next Steps

After DNS is configured:

1. **Verify DNS Propagation** (wait 1-24 hours)
2. **Run `add-site`** command
3. **Monitor SSL Certificate** provisioning
4. **Test Website** accessibility

## Additional Resources

- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [DNS Propagation Checker](https://www.whatsmydns.net/)
- [Clear Linux Network Configuration](https://docs.clearlinux.org/latest/guides/network/network-config.html)

