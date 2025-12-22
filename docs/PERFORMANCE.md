# Performance Analysis

## Architecture Overview

- **10 Python Worker Processes**: Each running Flask with `threaded=True`
- **Nginx Reverse Proxy**: Load balancing with `ip_hash` (sticky sessions)
- **MongoDB Database**: Optimized with indexes on all query fields
- **CPU Affinity**: E-cores (6-13) for Python workers, P-cores (0-5) for MongoDB/Nginx

## Request Flow

```
User Request → Nginx (P-cores) → Python Worker (E-cores) → MongoDB (P-cores) → Response
```

## Endpoint Performance Analysis

### 1. `/` (Index Page)

**Operations:**
- 1 MongoDB query: `db.locations.find({'status': 'fresh'}).limit(50)` (indexed on `status`)
- Template rendering with Jinja2
- Session handling

**Estimated Response Time:**
- MongoDB query: **2-5ms** (indexed, small result set)
- Template rendering: **5-10ms**
- Total: **7-15ms per request**

**Throughput per Worker:**
- With `threaded=True`, each worker can handle multiple concurrent requests
- Conservative estimate: **50-100 requests/second per worker** (assuming 10-20ms response time)

### 2. `/api/showtimes` (Showtimes API)

**Operations:**
- 1 MongoDB query: `db.locations.find_one({'city_name': city_name})` (indexed on `city_name`)
- 1 MongoDB query: `db.movies.find({'city_id': city_name})` (indexed on `city_id`)
- In-memory filtering (past showtimes, format, language)
- In-memory sorting by `start_time`
- JSON serialization (datetime to ISO string conversion)

**Estimated Response Time:**
- Location lookup: **1-3ms** (indexed, single document)
- Movies query: **3-10ms** (indexed, depends on number of movies per city)
- In-memory processing: **5-20ms** (depends on showtime count: 100-1000 showtimes)
- JSON serialization: **2-5ms**
- Total: **11-38ms per request** (typical: 15-25ms)

**Throughput per Worker:**
- Conservative estimate: **25-50 requests/second per worker** (assuming 20-40ms response time)

### 3. `/api/scrape/status/<city_name>` (Scrape Status)

**Operations:**
- 1 MongoDB query: `db.locks.find_one({'city_id': city_name})` (indexed)
- JSON serialization

**Estimated Response Time:**
- Lock lookup: **1-3ms** (indexed, single document)
- JSON serialization: **<1ms**
- Total: **2-4ms per request**

**Throughput per Worker:**
- Very fast: **100-200 requests/second per worker**

## Aggregate Performance Estimate

### Per Worker Process

| Endpoint | Response Time | Requests/Second (per worker) |
|----------|---------------|-------------------------------|
| `/` (index) | 7-15ms | 50-100 req/s |
| `/api/showtimes` | 15-25ms | 25-50 req/s |
| `/api/scrape/status` | 2-4ms | 100-200 req/s |

**Mixed Workload (typical):**
- 50% index page requests
- 40% showtimes API requests
- 10% status requests

**Weighted Average:**
- Average response time: ~15ms
- Average throughput: **40-60 requests/second per worker**

### System-Wide Performance (10 Workers)

**Total System Capacity:**
- **400-600 requests/second** (mixed workload)
- **500-1000 requests/second** (index page only)
- **250-500 requests/second** (showtimes API only)
- **1000-2000 requests/second** (status checks only)

**Realistic Production Estimate:**
- **300-500 requests/second** sustained throughput
- **500-800 requests/second** peak capacity
- **1000+ requests/second** burst capacity (short duration)

## Bottlenecks and Optimization Opportunities

### Current Bottlenecks

1. **MongoDB Query Performance**
   - ✅ **Optimized**: All queries use indexes
   - ✅ **Optimized**: Connection pooling handled by pymongo
   - ⚠️ **Potential**: Large result sets (1000+ showtimes) may slow down in-memory processing

2. **In-Memory Processing**
   - ⚠️ **Current**: Filtering and sorting done in Python
   - 💡 **Optimization**: Could push filtering to MongoDB aggregation pipeline
   - 💡 **Optimization**: Could cache frequently accessed city data

3. **JSON Serialization**
   - ⚠️ **Current**: Datetime conversion happens per request
   - 💡 **Optimization**: Could pre-serialize common responses

4. **Template Rendering**
   - ✅ **Optimized**: Simple templates, minimal logic
   - 💡 **Optimization**: Could add template caching

### Optimization Recommendations

1. **Add Response Caching**
   - Cache showtimes API responses for 30-60 seconds
   - Cache index page for 5-10 seconds
   - Use Redis or in-memory cache per worker

2. **MongoDB Aggregation Pipeline**
   - Push filtering and sorting to MongoDB
   - Reduce data transfer and in-memory processing
   - Estimated improvement: 20-30% faster responses

3. **Connection Pooling**
   - Ensure MongoDB connection pool is properly sized
   - Default pymongo pool size: 100 connections
   - With 10 workers, should be sufficient

4. **Static Asset Optimization**
   - Ensure Nginx serves static files directly
   - Add caching headers for images/CSS/JS
   - Use CDN for movie poster images

## Scalability

### Vertical Scaling (More Processes)

- Current: 10 processes
- Can increase to: 20-30 processes (limited by E-cores: 8 cores)
- With hyperthreading: Up to 16 logical cores on E-cores
- **Estimated capacity with 20 processes: 800-1000 requests/second**

### Horizontal Scaling (More Servers)

- Add more servers behind load balancer
- Each server: 10 processes = 400-600 req/s
- **2 servers: 800-1200 req/s**
- **3 servers: 1200-1800 req/s**
- **5 servers: 2000-3000 req/s**

### Database Scaling

- Current: Single MongoDB instance
- Can add: MongoDB replica set for read scaling
- Can add: MongoDB sharding for write scaling
- **Read replicas: 2-3x read capacity**

## Performance Testing Recommendations

### Load Testing Tools

1. **Apache Bench (ab)**
   ```bash
   ab -n 10000 -c 100 https://your-domain.com/
   ```

2. **wrk**
   ```bash
   wrk -t12 -c400 -d30s https://your-domain.com/
   ```

3. **Locust** (Python-based)
   - More realistic user behavior simulation
   - Can test multiple endpoints simultaneously

### Metrics to Monitor

1. **Response Times**
   - P50 (median): Should be < 20ms
   - P95: Should be < 50ms
   - P99: Should be < 100ms

2. **Throughput**
   - Requests per second
   - Concurrent connections
   - Error rate (< 0.1%)

3. **Resource Usage**
   - CPU utilization (should be < 70% on E-cores)
   - Memory usage per worker
   - MongoDB connection pool usage
   - Network I/O

4. **Database Performance**
   - Query execution time
   - Index hit rate (should be > 95%)
   - Connection pool utilization

## Real-World Performance Expectations

### Typical Production Load

- **Small site**: 10-50 requests/second
- **Medium site**: 50-200 requests/second
- **Large site**: 200-500 requests/second
- **Very large site**: 500-1000+ requests/second

### Current System Capacity

**Conservative Estimate:**
- **300-500 requests/second** sustained
- **500-800 requests/second** peak
- **1000+ requests/second** burst (short duration)

**This capacity should handle:**
- Small to medium-sized movie showtime aggregation sites
- Up to 100,000+ page views per day
- Up to 10,000+ concurrent users (with proper caching)

## Conclusion

The current architecture with 10 worker processes provides excellent performance for a movie showtime aggregation platform. With proper indexing, connection pooling, and efficient data structures, the system can handle **300-500 requests/second** sustained throughput, which is sufficient for most use cases.

For higher traffic, consider:
1. Adding response caching (Redis or in-memory)
2. Optimizing MongoDB queries with aggregation pipelines
3. Horizontal scaling (multiple servers)
4. Database read replicas for read-heavy workloads


