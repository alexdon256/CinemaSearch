# CineStream: High-Concurrency AI-Powered Movie Aggregator

**Version:** Final Release (v21.0)  
**Target OS:** CachyOS (Arch-based, Intel Architecture)  
**Date:** December 19, 2025

## Overview

CineStream is a high-performance, localized movie showtime aggregation platform that leverages **Artificial Intelligence (Google Gemini)** to dynamically discover and scrape cinema schedules on-demand. The system is architected for extreme concurrency using a shared-nothing parallel process model.

## Key Features

- 🎬 **AI-Powered Scraping**: Uses Google Gemini AI to discover and extract cinema showtimes automatically with step-by-step approach
- 🎯 **Incremental Scraping**: Intelligently scrapes only missing date ranges, reducing API token usage by up to 93%
- 📦 **Movie-Centric Data Model**: Efficient structure that stores movie images once per movie, not per showtime
- 🌍 **Multi-Language Support**: Full localization for Ukrainian (UA), English (EN), and Russian (RU)
- ⚡ **High Concurrency**: 12 parallel worker processes per application for maximum throughput
- 🔒 **Enterprise Security**: SSL/TLS encryption, secure environment variables, MongoDB authentication
- 🎨 **Modern UI**: Professional, responsive design with donation integration
- 📊 **Visitor Analytics**: Built-in visitor counter with MongoDB persistence
- 🔄 **On-Demand Scraping**: Data is scraped on-demand when users request showtimes
- 🚀 **Auto-Start on Boot**: All services configured to start automatically on system boot

## Architecture Highlights

### Shared-Nothing Parallel Model

- **12 Independent Processes**: Each application runs as 12 separate OS processes
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
- System package updates
- Python 3, Nginx, Git, Node.js, Go
- yay (AUR helper) - automatically installed if not present
- MongoDB (via yay/AUR - mongodb-bin package)
- Google Gemini API dependencies
- CPU affinity management
- Automatically deploys the first application (cinestream)

### Cleanup and Redeployment

To remove all CineStream components for redeployment:

```bash
# Remove all components (preserves MongoDB and Nginx)
sudo ./deploy.sh uninit-server

# Remove all components including MongoDB and Nginx
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

### 3. Deploy Additional Applications (Optional)

You can deploy multiple applications/websites on the same server:

```bash
# Deploy a new application with a custom name
sudo ./deploy.sh deploy-app myapp

# Each app gets its own:
# - Directory: /var/www/<app-name>/
# - Port range (automatically assigned)
# - Nginx configuration
# - Domain configuration
```

**Port Assignment:**
- First app (`cinestream`): ports 8001-8012
- Second app (`myapp`): ports 8013-8024
- Third app: ports 8025-8036
- And so on...

### 4. Domain Configuration

After deploying your application, configure a domain name:

```bash
# Set domain (app name is auto-detected if only one app exists)
sudo ./deploy.sh set-domain <domain>

# Or specify the app name explicitly
sudo ./deploy.sh set-domain <domain> <app-name>

# Example: Configure movies.example.com for cinestream app
sudo ./deploy.sh set-domain movies.example.com

# Example: Configure blog.example.com for myapp
sudo ./deploy.sh set-domain blog.example.com myapp
```

This command will:
- Auto-detect your application (or use specified app name)
- Update the application's `.deploy_config` with the domain
- Generate Nginx configuration with upstream backend (20 processes)
- Configure HTTP (port 80) with HTTPS redirect
- Configure HTTPS (port 443) with SSL placeholders
- Test and reload Nginx

**Next steps after setting domain:**
1. Point DNS A record to your server's IP address
2. Wait for DNS propagation (1-48 hours)
3. Install SSL certificate: `sudo ./deploy.sh install-ssl <domain>`

**Note:** 
- **Localhost access**: The first app (`cinestream`) is accessible via `http://localhost/cinestream/` for local testing. The root path (`/`) automatically redirects to `/cinestream/`.
- **Domain access**: When a domain is configured, the application is served at the root path (e.g., `https://movies.example.com/`) with no subpath.

## Project Structure

```
.
├── deploy.sh                 # Master deployment script
├── requirements.txt          # Python dependencies
├── src/                      # Application source code
│   ├── main.py              # Web application entry point
│   ├── core/
│   │   ├── agent.py         # Gemini AI agent wrapper
│   │   └── lock.py          # Concurrency locking
│   ├── scripts/
│   │   └── init_db.py       # Database schema initialization
│   └── templates/
│       └── index.html       # Frontend template
├── docs/
│   ├── SETUP.md             # Server setup guide
│   ├── MULTIPLE_APPS.md     # Guide for deploying multiple applications
│   ├── SITES.md             # Service management guide
│   ├── ARCHITECTURE.md      # System architecture documentation
│   ├── SCRAPING_STRATEGY.md # Detailed scraping strategy documentation
│   ├── DOMAINS.md           # Domain configuration and SSL setup
│   ├── SECURITY.md          # Security configuration
│   ├── CPU_AFFINITY.md      # CPU affinity configuration
│   └── SSH_TROUBLESHOOTING.md # SSH connectivity troubleshooting
└── README.md                # This file
```

## Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[SETUP.md](docs/SETUP.md)**: Complete server initialization guide
- **[SITES.md](docs/SITES.md)**: Service management and monitoring
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)**: System design and data flow
- **[SCRAPING_STRATEGY.md](docs/SCRAPING_STRATEGY.md)**: Detailed scraping strategy documentation
- **[CPU_AFFINITY.md](docs/CPU_AFFINITY.md)**: CPU affinity configuration
- **[SSH_TROUBLESHOOTING.md](docs/SSH_TROUBLESHOOTING.md)**: SSH connectivity troubleshooting

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

This configures Nginx to route the domain to your application's 12 worker processes (app name is auto-detected or can be specified).

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

- **OS**: CachyOS (Arch-based, Intel Architecture)
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
GOOGLE_API_KEY=your-api-key-here
# Alternative: GEMINI_API_KEY=your-api-key-here
SECRET_KEY=your-secret-key-here

# Optional: Gemini model selection
# Options: flash (default, cheapest/fastest), pro (more capable)
GEMINI_MODEL=flash
```

Note: The `deploy.sh` script does not create or manage application deployments. You must deploy applications manually and configure them to work with the initialized server infrastructure.

These should be configured in your application's `.env` file.

### Model Comparison

| Model | Cost | Speed | Best For |
|-------|------|-------|----------|
| `flash` (default) | $0.15/$0.60 per 1M tokens | Fastest | Structured tasks, JSON extraction, web scraping |
| `pro` | $1.25/$10.00 per 1M tokens | Balanced | Complex reasoning if needed |

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

### Step-by-Step Scraping Strategy

The system uses a decomposed approach for efficient scraping:

1. **Find Theaters**: One query to discover all cinema websites in the city
2. **Find Movies**: One query to discover all movies currently playing
3. **Scrape Movie-by-Movie**: For each movie, scrape day-by-day across all theaters
   - One query per movie per day
   - Continues until 2 weeks ahead or no movies found
   - Automatically extends if movies have showtimes beyond initial range

**Benefits**:
- More focused queries (better accuracy)
- Lower token usage per query
- Better error handling (can retry individual steps)
- Automatic date extension tracking

### Incremental Scraping

The system intelligently determines what date range to scrape:
- If 2 weeks of data exists: Only scrapes missing days
- If data is missing: Scrapes from latest date to 2 weeks ahead
- If no data: Scrapes full 2-week range
- **Automatic Extension**: If last showtime is 5 days out, next search extends to maintain 2-week coverage

This optimization significantly reduces API token usage while maintaining complete data coverage.

See [SCRAPING_STRATEGY.md](docs/SCRAPING_STRATEGY.md) for detailed documentation.

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

1. **Processes Won't Start**: Check `.env` file and MongoDB connection
2. **Nginx Errors**: Run `sudo nginx -t` to validate configuration
3. **MongoDB Connection Issues**: Verify MongoDB is running and check connection string

See individual documentation files for detailed troubleshooting guides.

## Contributing

This is a production-ready deployment system. When contributing:

1. Test changes on a development server
2. Update documentation for any new features
3. Ensure backward compatibility
4. Follow Arch Linux best practices

## License

This project is provided as-is for deployment purposes.

## Support

For deployment issues:

1. Check the relevant documentation file
2. Review logs: `sudo journalctl -xe`
3. Verify DNS and network connectivity
4. Check MongoDB and Nginx status

## Acknowledgments

- **Google Gemini AI** for intelligent web scraping with step-by-step approach
- **CachyOS** for the optimized, performant Arch-based OS
- **Let's Encrypt** for free SSL certificates
- **MongoDB** for flexible document storage

---

**Built with ❤️ for high-performance movie aggregation**

