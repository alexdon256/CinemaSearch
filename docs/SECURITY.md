# Security Configuration Guide

This document describes the comprehensive security measures implemented in the CineStream deployment system.

## Overview

The deployment script (`deploy.sh`) automatically configures multiple layers of security to protect your server from various attack vectors.

## Security Layers

### 1. Firewall Configuration

The system automatically configures a firewall using one of the following (in order of preference):

#### Firewalld (Preferred)
- **Default Zone**: `drop` (deny by default)
- **Allowed Services**:
  - SSH (port 22)
  - HTTP (port 80)
  - HTTPS (port 443)
- **Rate Limiting**: 
  - HTTP: 25 requests/minute per IP
  - HTTPS: 25 requests/minute per IP
- **Blocked**: Unnecessary services (dhcpv6-client, mdns)

#### UFW (Alternative)
- **Default Policies**: 
  - Incoming: Deny
  - Outgoing: Allow
- **Allowed Ports**: 22 (SSH), 80 (HTTP), 443 (HTTPS)
- **Rate Limiting**: SSH limited to prevent brute force

#### iptables (Fallback)
- **Default Policies**: DROP for INPUT/FORWARD, ACCEPT for OUTPUT
- **Allowed**: Loopback, established/related connections, SSH (rate limited), HTTP, HTTPS
- **SSH Protection**: Max 4 connections per 60 seconds per IP

### 2. Fail2ban Intrusion Prevention

Automatically installed and configured to protect against:
- **SSH Brute Force**: Bans after 3 failed attempts for 2 hours
- **Nginx HTTP Auth**: Monitors authentication failures
- **Nginx Rate Limiting**: Bans after 10 violations
- **Bot Detection**: Bans after 2 suspicious requests

**Configuration**: `/etc/fail2ban/jail.local`

### 3. System Kernel Hardening

Kernel parameters configured in `/etc/sysctl.d/99-security-hardening.conf`:

- **IP Spoofing Protection**: Reverse path filtering enabled
- **ICMP Protection**: Redirects ignored, ping broadcasts ignored
- **Source Routing**: Disabled
- **SYN Flood Protection**: TCP SYN cookies enabled
- **Connection Limits**: Max SYN backlog = 2048
- **IP Forwarding**: Disabled (unless needed)
- **Logging**: Suspicious packets logged

### 4. Nginx Security Configuration

#### Global Security Settings (`/etc/nginx/conf.d/security.conf`)

- **Rate Limiting Zones**:
  - `general_limit`: 10 requests/second
  - `api_limit`: 5 requests/second
  - `strict_limit`: 2 requests/second
- **Connection Limiting**: Per-IP connection limits
- **Server Tokens**: Hidden (no version disclosure)
- **Timeouts**: Configured to prevent slowloris attacks
  - Client body: 10s
  - Client header: 10s
  - Keepalive: 5s
  - Send: 10s
- **Buffer Sizes**: Limited to prevent buffer overflow
- **Method Restrictions**: Only GET, HEAD, POST, OPTIONS allowed
- **File Access Blocking**: Blocks access to `.env`, `.git`, `.htaccess`, etc.
- **Hidden Files**: Blocks access to files starting with `.`

#### Per-Site Security Headers

Each site configuration includes:

- **X-Frame-Options**: `SAMEORIGIN` (prevents clickjacking)
- **X-Content-Type-Options**: `nosniff` (prevents MIME sniffing)
- **X-XSS-Protection**: `1; mode=block` (enables XSS filter)
- **Referrer-Policy**: `strict-origin-when-cross-origin`
- **Permissions-Policy**: Restricts geolocation, microphone, camera
- **Content-Security-Policy**: Restricts resource loading to prevent XSS

#### Rate Limiting Per Location

- **Main Site (`/`)**: 
  - 10 requests/second (burst: 20)
  - 10 connections per IP
- **API Endpoints (`/api/`)**: 
  - 5 requests/second (burst: 10)
  - 5 connections per IP
  - Shorter timeouts (30s)

### 5. SSL/TLS Security

- **Protocols**: TLS 1.2 and TLS 1.3 only
- **Ciphers**: High-security ciphers only
- **HSTS**: Strict Transport Security enabled (1 year max-age)
- **Certificate Management**: Automatic renewal via certbot

### 6. MongoDB Security

- **Network Binding**: Only listens on `127.0.0.1` (localhost)
- **Authentication**: Supported via MONGO_URI configuration
- **Logging**: Disabled (no log files created)
- **Connection Limits**: Max 1000 incoming connections

### 7. Application Security

- **Process Isolation**: Each worker runs in separate process
- **File Permissions**: `.env` files are 600 (owner read/write only)
- **Network**: Workers listen on localhost only
- **Secrets**: API keys stored in `.env`, never committed to git
- **Sessions**: Signed with SECRET_KEY

## Security Features Summary

| Feature | Protection Against | Status |
|---------|-------------------|--------|
| Firewall | Unauthorized access, port scanning | ✅ Enabled |
| Fail2ban | Brute force attacks, automated bots | ✅ Enabled |
| Rate Limiting | DDoS, request flooding | ✅ Enabled |
| Security Headers | XSS, clickjacking, MIME sniffing | ✅ Enabled |
| SSL/TLS | Man-in-the-middle attacks | ✅ Enabled |
| Kernel Hardening | IP spoofing, SYN floods | ✅ Enabled |
| MongoDB Binding | Unauthorized database access | ✅ Enabled |
| Process Isolation | Process-level attacks | ✅ Enabled |

## Monitoring Security

### Check Firewall Status

```bash
# Firewalld
sudo firewall-cmd --list-all

# UFW
sudo ufw status verbose

# iptables
sudo iptables -L -n -v
```

### Check Fail2ban Status

```bash
# Status
sudo fail2ban-client status

# Check specific jails
sudo fail2ban-client status sshd
sudo fail2ban-client status nginx-http-auth
```

### Check Banned IPs

```bash
# Fail2ban
sudo fail2ban-client status sshd | grep "Banned IP"

# Firewall
sudo firewall-cmd --list-rich-rules
```

### Monitor Nginx Rate Limiting

Rate limiting is configured but logging is disabled. To monitor, you would need to temporarily enable logging or use external monitoring tools.

## Manual Security Adjustments

### Adjust Rate Limits

Edit `/etc/nginx/conf.d/security.conf`:

```nginx
# Increase general limit
limit_req_zone $binary_remote_addr zone=general_limit:10m rate=20r/s;

# Increase API limit
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
```

Then reload Nginx:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

### Adjust Fail2ban Settings

Edit `/etc/fail2ban/jail.local`:

```ini
[sshd]
maxretry = 5        # Increase from 3
bantime = 3600      # 1 hour (in seconds)
findtime = 600      # 10 minutes
```

Then restart fail2ban:
```bash
sudo systemctl restart fail2ban
```

### Whitelist IP Addresses

#### Firewalld
```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="YOUR_IP" accept'
sudo firewall-cmd --reload
```

#### UFW
```bash
sudo ufw allow from YOUR_IP
```

#### Fail2ban
Edit `/etc/fail2ban/jail.local`:
```ini
[sshd]
ignoreip = 127.0.0.1/8 ::1 YOUR_IP
```

## Security Best Practices

1. **Keep System Updated**: Run `sudo pacman -Syu` regularly
2. **Use Strong Passwords**: For MongoDB authentication if enabled
3. **SSH Key Authentication**: Disable password authentication for SSH
4. **Regular Backups**: Backup `.env` files and MongoDB data
5. **Monitor Logs**: Check fail2ban and firewall logs regularly
6. **Review Security Headers**: Adjust CSP if needed for your application
7. **SSL Certificate Renewal**: Automatic via certbot, but monitor expiration

## Troubleshooting

### Firewall Blocking Legitimate Traffic

```bash
# Check firewall rules
sudo firewall-cmd --list-all

# Temporarily allow IP
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="IP" accept'
sudo firewall-cmd --reload
```

### Rate Limiting Too Strict

Edit `/etc/nginx/conf.d/security.conf` and increase limits, then:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

### Fail2ban Blocking Legitimate Users

```bash
# Unban IP
sudo fail2ban-client set sshd unbanip IP_ADDRESS

# Whitelist IP in jail.local
```

### Nginx Security Headers Causing Issues

Edit the site configuration in `/etc/nginx/conf.d/` and adjust or remove problematic headers.

## Additional Resources

- [Arch Linux Security](https://wiki.archlinux.org/title/Security)
- [Nginx Security Headers](https://nginx.org/en/docs/http/ngx_http_headers_module.html)
- [Fail2ban Documentation](https://www.fail2ban.org/wiki/index.php/Main_Page)
- [Firewalld Documentation](https://firewalld.org/documentation/)

---

**Note**: Security is a continuous process. Regularly review and update your security configuration based on your specific needs and threat landscape.

