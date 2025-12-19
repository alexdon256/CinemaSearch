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
from core.lock import acquire_lock, release_lock, get_lock_info

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
        
        # Extract city, state, country from document
        city = city_doc.get('city', '')
        state = city_doc.get('state', '')
        country = city_doc.get('country', '')
        
        # Fallback: parse from city_name if fields not present
        if not city or not country:
            parts = city_name.split(', ')
            if len(parts) >= 2:
                city = parts[0]
                if len(parts) == 3:
                    state = parts[1]
                    country = parts[2]
                else:
                    country = parts[1]
        
        if not country:
            print(f"  ⚠ Skipping {city_name} (missing country)")
            continue
        
        print(f"Refreshing {city_name}...")
        
        # Check if on-demand scraping is in progress (don't override user requests)
        lock_info = get_lock_info(db, city_name)
        if lock_info and lock_info.get('source') == 'on-demand':
            print(f"  ⚠ Skipping {city_name} (on-demand scraping in progress - will retry later)")
            continue
        
        # Try to acquire lock (daily refresh has lower priority)
        if not acquire_lock(db, city_name, lock_source='daily-refresh', priority=False):
            print(f"  ⚠ Skipping {city_name} (already processing)")
            continue
        
        try:
            # Scrape city with state and country
            result = agent.scrape_city_showtimes(city, country, state)
            
            if result.get('success'):
                # Extract location components from result
                result_city = result.get('city', city_name)
                result_state = result.get('state', '')
                result_country = result.get('country', '')
                
                # Build location identifier
                if result_state:
                    location_id = f"{result_city}, {result_state}, {result_country}"
                else:
                    location_id = f"{result_city}, {result_country}"
                
                # Update location status
                db.locations.update_one(
                    {'city_name': location_id},
                    {
                        '$set': {
                            'city': result_city,
                            'state': result_state,
                            'country': result_country,
                            'status': 'fresh',
                            'last_updated': datetime.utcnow()
                        }
                    },
                    upsert=True
                )
                
                # Insert new showtimes (delete old ones first)
                if result.get('showtimes'):
                    # Ensure city_id is set correctly
                    for st in result['showtimes']:
                        st['city_id'] = location_id
                    # Delete old showtimes for this location
                    db.showtimes.delete_many({'city_id': location_id})
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

