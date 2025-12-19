# System Architecture Documentation

This document provides a comprehensive overview of the CineStream system architecture, including design decisions, data flow, and component interactions.

## Table of Contents

1. [High-Level Architecture](#high-level-architecture)
2. [Shared-Nothing Parallel Model](#shared-nothing-parallel-model)
3. [Multi-Site Multi-Tenancy](#multi-site-multi-tenancy)
4. [AI Agent Layer](#ai-agent-layer)
5. [Data Flow](#data-flow)
6. [Concurrency Control](#concurrency-control)
7. [Database Schema](#database-schema)
8. [Deployment Architecture](#deployment-architecture)

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ HTTPS (443)
                         │
         ┌───────────────▼────────────────┐
         │         Nginx                  │
         │    (Reverse Proxy + SSL)       │
         │    Sticky Sessions (ip_hash)   │
         └───────────────┬────────────────┘
                         │
         ┌───────────────┴────────────────┐
         │                                 │
    ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
    │Worker 1 │  │Worker 2 │  │Worker 3 │  ...  │Worker 24│
    │:8001    │  │:8002    │  │:8003    │       │:8024    │
    └────┬────┘  └────┬────┘  └────┬────┘       └────┬────┘
         │            │            │                  │
         └────────────┴────────────┴──────────────────┘
                         │
         ┌───────────────▼────────────────┐
         │      MongoDB Database          │
         │  (locations, showtimes, stats) │
         └────────────────────────────────┘
                         │
         ┌───────────────▼────────────────┐
         │    Claude AI API (Anthropic)   │
         │    (On-Demand Scraping)        │
         └────────────────────────────────┘
```

## Shared-Nothing Parallel Model

### Design Rationale

The system uses a **shared-nothing architecture** to maximize CPU utilization and bypass Python's Global Interpreter Lock (GIL).

### Key Characteristics

- **24 Independent Processes**: Each application runs as 24 separate OS processes
- **Unique Port Binding**: Each process binds to a unique port (8001-8024)
- **No Shared Memory**: Processes communicate only via MongoDB
- **Stateless Workers**: Each process is independent and can be restarted individually

### Process Lifecycle

```
Process Startup:
1. Load .env file
2. Connect to MongoDB
3. Bind to assigned port
4. Start Flask application
5. Listen for requests

Request Handling:
1. Receive request from Nginx
2. Process request (with caching)
3. Query/update MongoDB if needed
4. Return response to Nginx

Process Shutdown:
1. Gracefully close connections
2. Clean up resources
3. Exit
```

### Benefits

- **High Concurrency**: 24 processes can handle 24x more concurrent requests
- **Fault Isolation**: One crashed process doesn't affect others
- **Horizontal Scaling**: Easy to add more processes
- **GIL Bypass**: Each process has its own Python interpreter

## Multi-Site Multi-Tenancy

### Isolation Strategy

Each application is completely isolated:

```
/var/www/
├── movie_app/
│   ├── .env              (Isolated secrets)
│   ├── venv/             (Isolated Python environment)
│   ├── src/              (Isolated source code)
│   └── static/           (Isolated static files)
│
├── blog_app/
│   ├── .env
│   ├── venv/
│   └── src/
│
└── shop_app/
    ├── .env
    ├── venv/
    └── src/
```

### Nginx Routing

Nginx routes traffic based on `server_name`:

```nginx
server {
    server_name movies.example.com;
    # Routes to movie_app backend
}

server {
    server_name blog.example.com;
    # Routes to blog_app backend
}
```

### Resource Management

- **Port Ranges**: Each app uses non-overlapping port ranges
- **Database**: Each app can use separate database or collections
- **Systemd Services**: Each app has its own service files

## AI Agent Layer

### Distributed Agent Model

Every worker process can spawn its own AI agent:

```
Request → Worker Process → ClaudeAgent → Claude API → Response
```

### Agent Characteristics

- **Ephemeral**: Created per-request, destroyed after completion
- **Stateless**: No history or context retention
- **Independent**: Each agent operates in isolation
- **Parallel**: Multiple agents can run simultaneously

### Scraping Workflow

```
1. User requests showtimes for "Kyiv"
2. Worker checks MongoDB for fresh data
3. If stale/missing:
   a. Acquire lock (atomic MongoDB operation)
   b. Spawn ClaudeAgent
   c. Agent searches web for cinema websites
   d. Agent extracts showtimes
   e. Agent validates links
   f. Store results in MongoDB
   g. Release lock
4. Return showtimes to user
```

### Agent Prompt Structure

The agent receives a structured prompt:

```
Task: Scrape showtimes for city "X"
Requirements:
- Find official cinema websites
- Extract future showtimes only
- Validate purchase links
- Return structured JSON
```

## Data Flow

### User Request Flow

```
1. User visits https://movies.example.com
   ↓
2. Nginx receives HTTPS request
   ↓
3. Nginx uses ip_hash to select backend (e.g., Worker 5 :8005)
   ↓
4. Worker 5 processes request:
   - Checks session for language preference
   - Queries MongoDB for locations
   - Returns HTML with showtimes
   ↓
5. User clicks "Kyiv" city
   ↓
6. JavaScript sends AJAX request to /api/scrape
   ↓
7. Worker 5 (same worker due to sticky session):
   - Checks MongoDB lock status
   - If not locked, acquires lock
   - Spawns ClaudeAgent
   - Agent scrapes web
   - Stores results in MongoDB
   - Releases lock
   ↓
8. Returns success response
   ↓
9. Frontend fetches showtimes from /api/showtimes
   ↓
10. Displays showtimes to user
```

### Daily Refresh Flow

```
1. Systemd timer triggers at 06:00 AM
   ↓
2. daily_refresh.py script runs
   ↓
3. For each city in locations collection:
   a. Acquire lock
   b. Spawn ClaudeAgent
   c. Scrape fresh data
   d. Update MongoDB
   e. Release lock
   ↓
4. Log results
```

## Concurrency Control

### Locking Mechanism

Uses MongoDB atomic operations to prevent duplicate scraping:

```python
# Atomic lock acquisition
db.locations.update_one(
    {
        'city_name': 'Kyiv',
        'status': {'$ne': 'processing'}
    },
    {
        '$set': {'status': 'processing'}
    }
)
```

### Lock States

- **`fresh`**: Data is current, no scraping needed
- **`processing`**: Scraping in progress, other requests wait
- **`stale`**: Data is old, needs refresh

### Lock Timeout

Locks automatically expire after 5 minutes to prevent deadlocks:

```python
LOCK_TIMEOUT = 300  # 5 minutes
```

### Request Queuing

If a city is being scraped:

1. First request: Acquires lock, starts scraping
2. Concurrent requests: Receive `202 Accepted` status
3. Frontend polls: Checks status every 5 seconds
4. When complete: Lock released, data available

## Database Schema

### Collections Overview

#### `locations` Collection

```javascript
{
  _id: ObjectId("..."),
  city_name: {
    en: "Kyiv",
    ua: "Київ",
    ru: "Киев"
  },
  geo: {
    type: "Point",
    coordinates: [30.5234, 50.4501]  // [longitude, latitude]
  },
  status: "fresh" | "processing" | "stale",
  last_updated: ISODate("2025-12-19T10:00:00Z")
}
```

**Indexes**:
- `geo` (2dsphere) - For distance queries
- `status` - For filtering by status
- `city_name` (unique) - For lookups

#### `showtimes` Collection

```javascript
{
  _id: ObjectId("..."),
  cinema_id: "Multiplex",
  cinema_name: "Multiplex",
  movie: {
    en: "Avatar 2",
    ua: "Аватар 2",
    ru: "Аватар 2"
  },
  start_time: ISODate("2025-12-20T18:00:00Z"),
  format: "3D",
  price: "150 UAH",
  buy_link: "https://cinema.com/tickets/12345",
  language: "Ukrainian",
  created_at: ISODate("2025-12-19T10:00:00Z")
}
```

**Indexes**:
- `{cinema_id: 1, start_time: 1}` - For cinema queries
- `start_time` - For time-based queries
- `created_at` (TTL: 90 days) - Auto-delete old data

#### `stats` Collection

```javascript
{
  _id: "visitor_counter",
  count: 12345,
  created_at: ISODate("2025-12-19T10:00:00Z")
}
```

## Deployment Architecture

### Systemd Services

Each process runs as a systemd service:

```ini
[Unit]
Description=Movie App Web Worker (Port 8001)
After=network.target mongodb.service

[Service]
Type=simple
ExecStart=/var/www/movie_app/venv/bin/python /var/www/movie_app/src/main.py --port 8001
Restart=always
```

### Nginx Configuration

```nginx
upstream movie_app_backend {
    ip_hash;  # Sticky sessions
    server 127.0.0.1:8001;
    server 127.0.0.1:8002;
    # ... up to 8024
}

server {
    listen 443 ssl;
    server_name movies.example.com;
    
    location / {
        proxy_pass http://movie_app_backend;
    }
}
```

### SSL/TLS

- **Certificate**: Let's Encrypt (auto-renewed)
- **Protocols**: TLS 1.2, TLS 1.3
- **Ciphers**: High-security ciphers only
- **HSTS**: Enabled with 1-year max-age

## Performance Characteristics

### Scalability

- **Vertical**: Add more processes per app (edit-site)
- **Horizontal**: Deploy multiple apps (add-site)
- **Database**: MongoDB sharding (future enhancement)

### Caching Strategy

- **In-Memory**: Each worker caches frequently accessed data
- **Sticky Sessions**: Same user → same worker (cache hit)
- **TTL**: Showtimes expire after 90 days

### Resource Usage

- **Memory**: ~50-100 MB per worker process
- **CPU**: Minimal when idle, spikes during AI scraping
- **Network**: Moderate (API calls to Claude)

## Security Considerations

### Isolation

- **Process Isolation**: Each worker runs in separate process
- **File Permissions**: `.env` files are 600 (owner read/write only)
- **Network**: Workers listen on localhost only

### Authentication

- **MongoDB**: Supports authentication (configured via MONGO_URI)
- **API Keys**: Stored in `.env`, never committed to git
- **Sessions**: Signed with SECRET_KEY

### SSL/TLS

- **End-to-End Encryption**: HTTPS for all external traffic
- **Certificate Management**: Automatic renewal via certbot
- **Security Headers**: HSTS, X-Frame-Options, etc.

## Monitoring and Observability

### Logs

- **Application**: `journalctl -u movie_app@*.service`
- **Nginx**: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`
- **MongoDB**: `/opt/mongodb/logs/mongod.log`

### Metrics

Key metrics to monitor:

- **Request Rate**: Requests per second per worker
- **Response Time**: P50, P95, P99 latencies
- **Error Rate**: 5xx errors per minute
- **Lock Contention**: How often locks are acquired
- **AI API Usage**: Claude API calls per hour

## Future Enhancements

### Potential Improvements

1. **Redis Caching**: Add Redis for shared cache
2. **Load Balancing**: Replace ip_hash with more sophisticated LB
3. **Database Sharding**: Shard MongoDB for scale
4. **CDN Integration**: Serve static assets via CDN
5. **Monitoring**: Add Prometheus/Grafana
6. **Auto-Scaling**: Dynamic process scaling based on load

## Conclusion

The CineStream architecture is designed for:

- **High Concurrency**: 24 processes handle thousands of requests
- **Reliability**: Process isolation prevents cascading failures
- **Scalability**: Easy to add more apps or processes
- **Maintainability**: Clear separation of concerns

For deployment instructions, see:
- [SETUP.md](SETUP.md) - Server initialization
- [SITES.md](SITES.md) - Site management
- [DOMAINS.md](DOMAINS.md) - Domain configuration

