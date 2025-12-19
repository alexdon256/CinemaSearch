#!/usr/bin/env python3
"""
Daily Background Refresh Job
Runs at 06:00 AM daily to refresh data for all active cities
"""

import os
import sys

# Add parent directory to path so we can import core modules
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from datetime import datetime
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure
from dotenv import load_dotenv
from core.agent import ClaudeAgent
from core.lock import acquire_lock, release_lock

# Load environment variables
load_dotenv()

MONGO_URI = os.getenv('MONGO_URI')
if not MONGO_URI:
    print("ERROR: MONGO_URI environment variable is required")
    sys.exit(1)

try:
    client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
    client.server_info()
    # Extract database name from URI or use default
    from urllib.parse import urlparse
    parsed = urlparse(MONGO_URI)
    db_name = parsed.path.lstrip('/').split('?')[0] if parsed.path else 'movie_db'
    db = client[db_name] if db_name else client.movie_db
except ConnectionFailure as e:
    print(f"ERROR: Failed to connect to MongoDB: {e}")
    sys.exit(1)

def refresh_all_cities():
    """Refresh data for all active cities"""
    print(f"[{datetime.utcnow()}] Starting daily refresh job...")
    
    # Get all cities that have been scraped before
    cities = db.locations.find({})
    cities_list = list(cities)
    
    if not cities_list:
        print("No cities found to refresh")
        return
    
    print(f"Found {len(cities_list)} cities to refresh")
    
    agent = ClaudeAgent()
    success_count = 0
    error_count = 0
    
    for city_doc in cities_list:
        city_name = city_doc.get('city_name')
        if not city_name:
            continue
        
        print(f"Refreshing {city_name}...")
        
        # Try to acquire lock
        if not acquire_lock(db, city_name):
            print(f"  ⚠ Skipping {city_name} (already processing)")
            continue
        
        try:
            # Scrape city
            result = agent.scrape_city_showtimes(city_name)
            
            if result.get('success'):
                # Update location status
                db.locations.update_one(
                    {'city_name': city_name},
                    {
                        '$set': {
                            'status': 'fresh',
                            'last_updated': datetime.utcnow()
                        }
                    }
                )
                
                # Insert new showtimes (delete old ones first)
                if result.get('showtimes'):
                    # Add city_id to each showtime
                    for st in result['showtimes']:
                        st['city_id'] = city_name
                    # Delete old showtimes for this city
                    db.showtimes.delete_many({'city_id': city_name})
                    # Insert new showtimes
                    db.showtimes.insert_many(result['showtimes'])
                    print(f"  ✓ Inserted {len(result['showtimes'])} showtimes")
                
                release_lock(db, city_name, 'fresh')
                success_count += 1
            else:
                release_lock(db, city_name, 'stale')
                print(f"  ✗ Error: {result.get('error', 'Unknown error')}")
                error_count += 1
                
        except Exception as e:
            release_lock(db, city_name, 'stale')
            print(f"  ✗ Exception: {e}")
            error_count += 1
    
    print()
    print("=" * 60)
    print(f"Daily refresh completed:")
    print(f"  Success: {success_count}")
    print(f"  Errors: {error_count}")
    print("=" * 60)

if __name__ == '__main__':
    refresh_all_cities()

