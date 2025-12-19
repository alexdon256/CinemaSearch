# CineStream: High-Concurrency AI-Powered Movie Aggregator

**Version:** Final Release (v21.0)  
**Target OS:** Clear Linux OS (Intel Architecture)  
**Date:** December 19, 2025

## Overview

CineStream is a high-performance, localized movie showtime aggregation platform that leverages **Artificial Intelligence (Claude)** to dynamically discover and scrape cinema schedules on-demand. The system is architected for extreme concurrency using a shared-nothing parallel process model.

## Key Features

- 🎬 **AI-Powered Scraping**: Uses Claude AI to discover and extract cinema showtimes automatically
- 🌍 **Multi-Language Support**: Full localization for Ukrainian (UA), English (EN), and Russian (RU)
- ⚡ **High Concurrency**: 12 parallel worker processes per application for maximum throughput
- 🔒 **Enterprise Security**: SSL/TLS encryption, secure environment variables, MongoDB authentication
- 🎨 **Modern UI**: Professional, responsive design with donation integration
- 📊 **Visitor Analytics**: Built-in visitor counter with MongoDB persistence
- 🔄 **Automated Refresh**: Daily background jobs to keep data fresh

## Architecture Highlights

### Shared-Nothing Parallel Model

- **12 Independent Processes**: Each application runs as 12 separate OS processes
- **Sticky Sessions**: Nginx uses `ip_hash` to route users to the same backend process
- **GIL Bypass**: Each process has its own Python interpreter, bypassing the GIL
- **Fault Isolation**: One crashed process doesn't affect others

### Multi-Site Multi-Tenancy

- **Complete Isolation**: Each application has its own directory, virtual environment, and systemd services
- **Domain-Based Routing**: Nginx routes traffic based on domain name
- **Scalable**: Deploy multiple independent applications on the same server

## Quick Start

### 1. Initialize Server

```bash
sudo ./deploy.sh init-server
```

This installs:
- Clear Linux updates
- Python 3, Nginx, Git, Node.js
- MongoDB (manually installed)
- Claude CLI tools

### 2. Configure Domain

Before deploying, ensure your DNS A record points to your server:

```
Type: A
Name: example.com (or subdomain)
Value: YOUR_SERVER_IP
```

See [docs/DOMAINS.md](docs/DOMAINS.md) for detailed DNS configuration.

### 3. Deploy Application

```bash
sudo ./deploy.sh add-site \
  https://github.com/username/movie-app.git \
  movies.example.com \
  movie_app \
  8001 \
  12
```

The script will prompt for:
- MongoDB connection string
- Anthropic API key
- Flask secret key

### 4. Access Your Site

Visit `https://movies.example.com` - SSL certificate is automatically provisioned!

## Project Structure

```
.
├── deploy.sh                 # Master deployment script
├── requirements.txt          # Python dependencies
├── src/                      # Application source code
│   ├── main.py              # Web application entry point
│   ├── core/
│   │   ├── agent.py         # Claude AI agent wrapper
│   │   └── lock.py          # Concurrency locking
│   ├── scripts/
│   │   ├── init_db.py       # Database schema initialization
│   │   └── daily_refresh.py # Daily background job
│   └── templates/
│       └── index.html       # Frontend template
├── docs/
│   ├── SETUP.md             # Server setup guide
│   ├── SITES.md             # Site management guide
│   ├── DOMAINS.md           # Domain configuration guide
│   └── ARCHITECTURE.md      # System architecture documentation
└── README.md                # This file
```

## Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[SETUP.md](docs/SETUP.md)**: Complete server initialization guide
- **[SITES.md](docs/SITES.md)**: How to add, edit, and remove sites
- **[DOMAINS.md](docs/DOMAINS.md)**: DNS configuration and SSL setup
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)**: System design and data flow

## Deployment Commands

### Initialize Server
```bash
sudo ./deploy.sh init-server
```

### Add Site
```bash
sudo ./deploy.sh add-site <repo_url> <domain_name> <app_name> [start_port] [process_count]
```

### Edit Site
```bash
sudo ./deploy.sh edit-site <app_name>
```

### Remove Site
```bash
sudo ./deploy.sh remove-site <app_name>
```

### Start All Services
```bash
sudo ./deploy.sh start-all
```

### Stop All Services
```bash
sudo ./deploy.sh stop-all
```

### Enable Auto-Start on Boot
```bash
sudo ./deploy.sh enable-autostart
```

### Check System Status
```bash
sudo ./deploy.sh status
```

## Requirements

### Server Requirements

- **OS**: Clear Linux OS (Intel Architecture)
- **RAM**: Minimum 2GB (4GB+ recommended)
- **Storage**: 10GB+ free space
- **Network**: Public IP address with ports 80 and 443 open

### Software Dependencies

- Python 3.8+
- MongoDB 7.0+
- Nginx 1.18+
- Node.js 16+ (for Claude CLI)

All dependencies are automatically installed by `deploy.sh init-server`.

## Environment Variables

Each application requires a `.env` file with:

```bash
MONGO_URI=mongodb://user:pass@127.0.0.1:27017/movie_db?authSource=admin
ANTHROPIC_API_KEY=sk-ant-api03-...
SECRET_KEY=your-secret-key-here

# Optional: Claude model selection
# Options: haiku (default, cheapest/fastest), sonnet (more capable)
CLAUDE_MODEL=haiku
```

These are configured interactively during `add-site`.

### Model Comparison

| Model | Cost | Speed | Best For |
|-------|------|-------|----------|
| `haiku` (default) | $0.25/$1.25 per 1M tokens | Fastest | Structured tasks, JSON extraction |
| `sonnet` | $3/$15 per 1M tokens | Balanced | Complex reasoning if needed |

## Database Schema

### Collections

1. **`locations`**: Cities and their scraping status
2. **`showtimes`**: Movie showtimes with TTL (90 days)
3. **`stats`**: Visitor counter and statistics

See `src/scripts/init_db.py` for schema details.

## Localization

The platform supports three languages:

- **Ukrainian (UA)**: Повна підтримка української мови
- **English (EN)**: Full English language support
- **Russian (RU)**: Полная поддержка русского языка

Users can switch languages via the header selector. Language preference is stored in session.

## Security Features

- ✅ SSL/TLS encryption (Let's Encrypt)
- ✅ Secure environment variable storage
- ✅ MongoDB authentication support
- ✅ Process isolation
- ✅ Firewall-ready configuration
- ✅ Security headers (HSTS, X-Frame-Options, etc.)

## Performance

- **Concurrency**: 12 processes per application
- **Throughput**: Handles thousands of concurrent requests
- **Caching**: In-memory caching per worker process
- **Database**: Optimized indexes and TTL for automatic cleanup

## Monitoring

### View Logs

```bash
# Application logs
sudo journalctl -u movie_app@*.service -f

# Nginx logs
sudo tail -f /var/log/nginx/access.log

# MongoDB logs
sudo tail -f /opt/mongodb/logs/mongod.log
```

### Check Status

```bash
# Service status
sudo systemctl status movie_app@8001.service

# Process count
sudo systemctl list-units | grep movie_app
```

## Troubleshooting

### Common Issues

1. **SSL Certificate Fails**: Check DNS propagation (see [DOMAINS.md](docs/DOMAINS.md))
2. **Processes Won't Start**: Check `.env` file and MongoDB connection
3. **Nginx Errors**: Run `sudo nginx -t` to validate configuration

See individual documentation files for detailed troubleshooting guides.

## Contributing

This is a production-ready deployment system. When contributing:

1. Test changes on a development server
2. Update documentation for any new features
3. Ensure backward compatibility
4. Follow Clear Linux best practices

## License

This project is provided as-is for deployment purposes.

## Support

For deployment issues:

1. Check the relevant documentation file
2. Review logs: `sudo journalctl -xe`
3. Verify DNS and network connectivity
4. Check MongoDB and Nginx status

## Acknowledgments

- **Claude AI** by Anthropic for intelligent web scraping
- **Clear Linux** for the lightweight, performant OS
- **Let's Encrypt** for free SSL certificates
- **MongoDB** for flexible document storage

---

**Built with ❤️ for high-performance movie aggregation**

