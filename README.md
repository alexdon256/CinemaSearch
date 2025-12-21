# CineStream: High-Concurrency AI-Powered Movie Aggregator

**Version:** Final Release (v21.0)  
**Target OS:** Clear Linux OS (Intel Architecture)  
**Date:** December 19, 2025

## Overview

CineStream is a high-performance, localized movie showtime aggregation platform that leverages **Artificial Intelligence (Claude)** to dynamically discover and scrape cinema schedules on-demand. The system is architected for extreme concurrency using a shared-nothing parallel process model.

## Key Features

- 🎬 **AI-Powered Scraping**: Uses Claude AI to discover and extract cinema showtimes automatically
- 🎯 **Incremental Scraping**: Intelligently scrapes only missing date ranges, reducing API token usage by up to 93%
- 📦 **Movie-Centric Data Model**: Efficient structure that stores movie images once per movie, not per showtime
- 🌍 **Multi-Language Support**: Full localization for Ukrainian (UA), English (EN), and Russian (RU)
- ⚡ **High Concurrency**: 10 parallel worker processes per application for maximum throughput
- 🔒 **Enterprise Security**: SSL/TLS encryption, secure environment variables, MongoDB authentication
- 🎨 **Modern UI**: Professional, responsive design with donation integration
- 📊 **Visitor Analytics**: Built-in visitor counter with MongoDB persistence
- 🔄 **Automated Refresh**: Daily background jobs to keep data fresh

## Architecture Highlights

### Shared-Nothing Parallel Model

- **10 Independent Processes**: Each application runs as 10 separate OS processes
- **Sticky Sessions**: Nginx uses `ip_hash` to route users to the same backend process
- **GIL Bypass**: Each process has its own Python interpreter, bypassing the GIL
- **Fault Isolation**: One crashed process doesn't affect others

### Server Infrastructure

- **Service Management**: Centralized management of MongoDB, Nginx, and application services
- **CPU Affinity**: Optimized CPU core assignment for performance
- **Auto-Start**: All services configured to start automatically on boot

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
- CPU affinity management

### Cleanup and Redeployment

To remove all CineStream components for redeployment:

```bash
# Remove all components (preserves MongoDB)
sudo ./deploy.sh uninit-server

# Remove all components including MongoDB
sudo ./deploy.sh uninit-server yes
```

### 2. Server Management

```bash
# Check system status
sudo ./deploy.sh status

# Start all services
sudo ./deploy.sh start-all

# Stop all services
sudo ./deploy.sh stop-all

# Clean up everything (for redeployment)
sudo ./deploy.sh uninit-server
```

### 3. Domain Configuration

After deploying your application, configure a domain name:

```bash
# Set domain (app name is auto-detected)
sudo ./deploy.sh set-domain <domain>

# Example: Configure movies.example.com
sudo ./deploy.sh set-domain movies.example.com
```

This command will:
- Auto-detect your application
- Update the application's `.deploy_config` with the domain
- Generate Nginx configuration with upstream backend (10 processes)
- Configure HTTP (port 80) with HTTPS redirect
- Configure HTTPS (port 443) with SSL placeholders
- Test and reload Nginx

**Next steps after setting domain:**
1. Point DNS A record to your server's IP address
2. Wait for DNS propagation (1-48 hours)
3. Install SSL certificate: `sudo ./deploy.sh install-ssl <domain>`

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
│   ├── SITES.md             # Service management guide
│   ├── ARCHITECTURE.md      # System architecture documentation
│   └── CPU_AFFINITY.md      # CPU affinity configuration
└── README.md                # This file
```

## Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[SETUP.md](docs/SETUP.md)**: Complete server initialization guide
- **[SITES.md](docs/SITES.md)**: Service management and monitoring
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)**: System design and data flow
- **[CPU_AFFINITY.md](docs/CPU_AFFINITY.md)**: CPU affinity configuration

## Deployment Commands

### Initialize Server
```bash
sudo ./deploy.sh init-server
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

### Configure Domain

```bash
sudo ./deploy.sh set-domain <domain>
```

Example:
```bash
sudo ./deploy.sh set-domain movies.example.com
```

This configures Nginx to route the domain to your application's 10 worker processes (app name is auto-detected).

### Install SSL Certificate

After setting a domain and ensuring DNS is configured, install an SSL certificate:

```bash
sudo ./deploy.sh install-ssl <domain>
```

Example:
```bash
sudo ./deploy.sh install-ssl movies.example.com
```

This command will:
- Install certbot if needed
- Verify DNS is pointing to your server
- Request SSL certificate from Let's Encrypt
- Automatically update Nginx configuration with SSL paths
- Enable HTTPS with security headers
- Set up automatic certificate renewal

**Requirements:**
- DNS A record must point to your server's IP
- Port 80 must be accessible from the internet
- Domain must be publicly resolvable

### Uninitialize Server (Cleanup)
```bash
# Remove all CineStream components (preserves MongoDB)
sudo ./deploy.sh uninit-server

# Remove all components including MongoDB
sudo ./deploy.sh uninit-server yes
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

Applications deployed on the server require a `.env` file with:

```bash
MONGO_URI=mongodb://user:pass@127.0.0.1:27017/movie_db?authSource=admin
ANTHROPIC_API_KEY=sk-ant-api03-...
SECRET_KEY=your-secret-key-here

# Optional: Claude model selection
# Options: haiku (default, cheapest/fastest), sonnet (more capable)
CLAUDE_MODEL=haiku
```

Note: The `deploy.sh` script does not create or manage application deployments. You must deploy applications manually and configure them to work with the initialized server infrastructure.

These should be configured in your application's `.env` file.

### Model Comparison

| Model | Cost | Speed | Best For |
|-------|------|-------|----------|
| `haiku` (default) | $0.25/$1.25 per 1M tokens | Fastest | Structured tasks, JSON extraction |
| `sonnet` | $3/$15 per 1M tokens | Balanced | Complex reasoning if needed |

## Database Schema

### Collections

1. **`locations`**: Cities and their scraping status
2. **`movies`**: Movies with theaters and showtimes, organized by movie (TTL: 90 days)
   - Structure: Each movie document contains theaters array, each theater contains showtimes array
   - Benefits: Movie images stored once per movie, reduces token usage in API responses
3. **`stats`**: Visitor counter and statistics

### Data Structure

The system uses a **movie-centric** data model:
- **Movies** are top-level documents (one per movie per city)
- Each movie contains an array of **theaters** showing it
- Each theater contains an array of **showtimes**
- This structure eliminates duplicate movie images and reduces API token usage

### Incremental Scraping

The system intelligently determines what date range to scrape:
- If 2 weeks of data exists: Only scrapes the missing day (day 14)
- If data is missing: Scrapes from latest date to 2 weeks ahead
- If no data: Scrapes full 2-week range

This optimization significantly reduces API token usage while maintaining complete data coverage.

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

- **Concurrency**: 10 processes per application
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

1. **Processes Won't Start**: Check `.env` file and MongoDB connection
2. **Nginx Errors**: Run `sudo nginx -t` to validate configuration
3. **MongoDB Connection Issues**: Verify MongoDB is running and check connection string

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

