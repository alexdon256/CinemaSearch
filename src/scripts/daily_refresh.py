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
from core.image_handler import cleanup_old_images
import urllib.request
import urllib.parse
import json

# Simple in-memory cache for normalization (not using Flask session)
_normalization_cache = {}

def normalize_location_name(name, location_type='city'):
    """
    Normalize location names to English to avoid duplicates from different languages.
    Uses Nominatim to get the canonical English name.
    Standalone version for scripts (doesn't use Flask session).
    """
    if not name or not name.strip():
        return name
    
    name = name.strip()
    
    # Check cache first
    cache_key = f"{location_type}_{name.lower()}"
    if cache_key in _normalization_cache:
        return _normalization_cache[cache_key]
    
    try:
        # Use Nominatim to search for the location and get English name
        search_query = name
        url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(search_query)}&format=json&limit=1&addressdetails=1&accept-language=en"
        
        req = urllib.request.Request(url, headers={
            'User-Agent': 'CineStream/1.0'
        })
        
        with urllib.request.urlopen(req, timeout=3) as response:
            results = json.loads(response.read().decode())
            
            if results and len(results) > 0:
                result = results[0]
                address = result.get('address', {})
                
                # Get English name from address
                if location_type == 'city':
                    normalized = (address.get('city') or 
                                 address.get('town') or 
                                 address.get('village') or 
                                 address.get('municipality') or
                                 name)
                elif location_type == 'country':
                    normalized = address.get('country', name)
                elif location_type == 'state':
                    normalized = (address.get('state') or 
                                 address.get('province') or 
                                 address.get('region') or
                                 name)
                else:
                    normalized = name
                
                # Cache the result
                _normalization_cache[cache_key] = normalized
                return normalized
        
        # If no results, return original name
        _normalization_cache[cache_key] = name
        return name
        
    except Exception as e:
        print(f"  ⚠ Normalization error for {name}: {e}")
        # Return original name if normalization fails
        _normalization_cache[cache_key] = name
        return name

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
    from datetime import timezone
    print(f"[{datetime.now(timezone.utc)}] Starting daily refresh job...")
    
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
        
        # Normalize location names to English to avoid duplicates from different languages
        # This ensures consistent scraping even if database has non-English names
        original_city = city
        original_state = state
        original_country = country
        
        city = normalize_location_name(city, 'city')
        country = normalize_location_name(country, 'country')
        if state:
            state = normalize_location_name(state, 'state')
        
        # Log if normalization changed the name
        if city != original_city or country != original_country or (state and state != original_state):
            print(f"  🔄 Normalized: '{original_city}, {original_state or ''}, {original_country}' → '{city}, {state or ''}, {country}'")
        
        print(f"Refreshing {city_name}...")
        
        # Build location_id using normalized names to ensure consistency
        # Must be defined before any checks that use it
        if state:
            location_id = f"{city}, {state}, {country}"
        else:
            location_id = f"{city}, {country}"
        
        # Check if data needs refresh (catch-up logic for power outages)
        location_check = db.locations.find_one({'city_name': location_id})
        from datetime import timezone, timedelta
        now_utc = datetime.now(timezone.utc)
        
        if location_check and location_check.get('status') == 'fresh':
            last_updated = location_check.get('last_updated')
            if last_updated and isinstance(last_updated, datetime):
                # Handle both timezone-aware and naive datetimes
                if last_updated.tzinfo is None:
                    # Naive datetime - assume UTC
                    last_updated_utc = last_updated.replace(tzinfo=timezone.utc)
                else:
                    # Timezone-aware - convert to UTC
                    last_updated_utc = last_updated.astimezone(timezone.utc)
                
                hours_old = (now_utc - last_updated_utc).total_seconds() / 3600
                days_old = (now_utc - last_updated_utc).days
                
                # If data is less than 24 hours old, skip (already fresh)
                if hours_old < 24:
                    print(f"  ⚠ Skipping {city_name} (data is fresh, updated {hours_old:.1f} hours ago)")
                    continue
                
                # If more than 1 day old, log catch-up scenario
                if days_old > 1:
                    print(f"  🔄 Catch-up: {city_name} data is {days_old} days old (power outage recovery)")
        
        # Check if on-demand scraping is in progress (don't override user requests)
        lock_info = get_lock_info(db, location_id)
        if lock_info and lock_info.get('source') == 'on-demand':
            print(f"  ⚠ Skipping {city_name} (on-demand scraping in progress - will retry later)")
            continue
        
        # Try to acquire lock (daily refresh has lower priority)
        if not acquire_lock(db, location_id, lock_source='daily-refresh', priority=False):
            print(f"  ⚠ Skipping {city_name} (already processing)")
            continue
        
        try:
            # Determine date range to scrape (incremental scraping with catch-up)
            now = datetime.now(timezone.utc)
            two_weeks_from_now = now + timedelta(days=14)
            
            # Find all movies for this city to determine what date range we need
            movies = list(db.movies.find({'city_id': location_id}))
            
            if movies:
                # Find the latest showtime date (convert to UTC for comparison)
                latest_date_utc = None
                for movie in movies:
                    theaters = movie.get('theaters', [])
                    for theater in theaters:
                        showtimes = theater.get('showtimes', [])
                        for st in showtimes:
                            start_time = st.get('start_time')
                            if isinstance(start_time, datetime):
                                # Convert to UTC for comparison
                                if start_time.tzinfo is None:
                                    start_time_utc = start_time.replace(tzinfo=timezone.utc)
                                else:
                                    start_time_utc = start_time.astimezone(timezone.utc)
                                if latest_date_utc is None or start_time_utc > latest_date_utc:
                                    latest_date_utc = start_time_utc
                latest_date = latest_date_utc
                
                # Determine scrape range with catch-up logic
                if latest_date:
                    # Calculate how many days ahead we have data
                    days_ahead = (latest_date - now).days
                    
                    if days_ahead >= 13:
                        # We have data up to 2 weeks ahead, only scrape the new day
                        date_start = two_weeks_from_now - timedelta(days=1)
                        date_end = two_weeks_from_now
                        print(f"  📅 Scraping new day: {date_start.date()} to {date_end.date()}")
                    elif days_ahead >= 0:
                        # We have some data but not enough - fill gap to 2 weeks
                        date_start = max(now, latest_date - timedelta(hours=1))
                        date_end = two_weeks_from_now
                        gap_days = (date_end - date_start).days
                        print(f"  📅 Filling gap: {gap_days} days from {date_start.date()} to {date_end.date()}")
                    else:
                        # Data is in the past (catch-up scenario after power outage)
                        # Scrape from now to 2 weeks ahead to catch up
                        date_start = now
                        date_end = two_weeks_from_now
                        print(f"  🔄 Catch-up: Scraping full range {date_start.date()} to {date_end.date()} (data was {abs(days_ahead)} days behind)")
                else:
                    # No valid showtimes found, scrape full range
                    date_start = now
                    date_end = two_weeks_from_now
                    print(f"  📅 No valid showtimes found, scraping full range")
            else:
                # No data yet, scrape full range
                date_start = now
                date_end = two_weeks_from_now
                print(f"  📅 No existing data, scraping full range")
            
            # Scrape city with state and country (incremental)
            result = agent.scrape_city_showtimes(city, country, state, date_start, date_end)
            
            if result.get('success'):
                # Extract location components from result and normalize them
                result_city = normalize_location_name(result.get('city', city), 'city')
                result_state = result.get('state', state or '')
                if result_state:
                    result_state = normalize_location_name(result_state, 'state')
                result_country = normalize_location_name(result.get('country', country), 'country')
                
                # Build location identifier using normalized result values
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
                            'last_updated': datetime.now(timezone.utc)
                        }
                    },
                    upsert=True
                )
                
                # Insert/update movies (merge with existing, don't delete first)
                if result.get('movies'):
                    upserted_count = 0
                    inserted_count = 0
                    
                    try:
                        for movie in result['movies']:
                            # Ensure city_id is set
                            movie['city_id'] = location_id
                            
                            # Create unique query for movie (city + movie title)
                            movie_title = movie.get('movie', {})
                            if not isinstance(movie_title, dict):
                                movie_title = {}
                            
                            movie_en = movie_title.get('en')
                            if not movie_en:
                                continue  # Skip movies without English title
                            
                            query = {
                                'city_id': location_id,
                                'movie.en': movie_en
                            }
                            
                            # Update existing movie or insert new
                            existing_movie = db.movies.find_one(query)
                            
                            if existing_movie:
                                # Merge theaters - update existing or add new
                                existing_theaters = existing_movie.get('theaters', [])
                                new_theaters = movie.get('theaters', [])
                                
                                # Create a map of existing theaters by name
                                theater_map = {t.get('name'): t for t in existing_theaters}
                                
                                # Merge new theaters
                                for new_theater in new_theaters:
                                    theater_name = new_theater.get('name')
                                    if theater_name in theater_map:
                                        # Theater exists - merge showtimes
                                        existing_showtimes = theater_map[theater_name].get('showtimes', [])
                                        new_showtimes = new_theater.get('showtimes', [])
                                        
                                        # Create set of existing showtime times to avoid duplicates
                                        existing_times = {st.get('start_time') for st in existing_showtimes if st.get('start_time')}
                                        
                                        # Add new showtimes that don't exist
                                        for new_st in new_showtimes:
                                            if new_st.get('start_time') not in existing_times:
                                                existing_showtimes.append(new_st)
                                        
                                        theater_map[theater_name]['showtimes'] = existing_showtimes
                                        # Update address/website if provided
                                        if new_theater.get('address'):
                                            theater_map[theater_name]['address'] = new_theater.get('address')
                                        if new_theater.get('website'):
                                            theater_map[theater_name]['website'] = new_theater.get('website')
                                    else:
                                        # New theater - add it
                                        theater_map[theater_name] = new_theater
                                
                                # Update movie with merged theaters
                                movie['theaters'] = list(theater_map.values())
                                movie['updated_at'] = datetime.now(timezone.utc)
                            
                            # Preserve existing created_at
                            if 'created_at' not in movie:
                                movie['created_at'] = existing_movie.get('created_at', datetime.now(timezone.utc))
                            
                            result_upsert = db.movies.replace_one(query, movie)
                            if result_upsert.modified_count > 0:
                                upserted_count += 1
                            else:
                                # New movie - insert it
                                result_insert = db.movies.insert_one(movie)
                                if result_insert.inserted_id:
                                    inserted_count += 1
                        
                        if upserted_count > 0 or inserted_count > 0:
                            print(f"  ✓ Updated {upserted_count} existing, inserted {inserted_count} new movies")
                        
                        # Clean up expired showtimes (older than 24 hours past their start_time)
                        expired_cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
                        
                        # Update all movies to remove expired showtimes
                        movies_to_update = list(db.movies.find({'city_id': location_id}))
                        for movie in movies_to_update:
                            theaters = movie.get('theaters', [])
                            updated = False
                            for theater in theaters:
                                showtimes = theater.get('showtimes', [])
                                original_count = len(showtimes)
                                # Filter expired showtimes (convert to UTC for comparison)
                                filtered_showtimes = []
                                for st in showtimes:
                                    start_time = st.get('start_time')
                                    if isinstance(start_time, datetime):
                                        # Convert to UTC for comparison, but preserve original timezone
                                        if start_time.tzinfo is None:
                                            start_time_utc = start_time.replace(tzinfo=timezone.utc)
                                        else:
                                            start_time_utc = start_time.astimezone(timezone.utc)
                                        if start_time_utc >= expired_cutoff:
                                            filtered_showtimes.append(st)  # Keep original timezone
                                showtimes = filtered_showtimes
                                if len(showtimes) != original_count:
                                    theater['showtimes'] = showtimes
                                    updated = True
                            
                            if updated:
                                # Remove theaters with no showtimes
                                movie['theaters'] = [t for t in theaters if t.get('showtimes')]
                                # Update movie if it still has theaters
                                if movie['theaters']:
                                    db.movies.replace_one({'_id': movie['_id']}, movie)
                                else:
                                    # Remove movie if no theaters left
                                    db.movies.delete_one({'_id': movie['_id']})
                            
                    except Exception as insert_error:
                        # If insert fails, existing data is preserved
                        print(f"  ✗ Error updating movies: {insert_error}")
                        import traceback
                        traceback.print_exc()
                        db.locations.update_one(
                            {'city_name': location_id},
                            {'$set': {'status': 'stale'}}
                        )
                        raise  # Re-raise to be caught by outer exception handler
                
                # Use location_id (not city_name) to release lock - they might differ
                release_lock(db, location_id, 'fresh')
                success_count += 1
            else:
                # Use location_id for consistency
                release_lock(db, location_id, 'stale')
                print(f"  ✗ Error: {result.get('error', 'Unknown error')}")
                error_count += 1
                
        except Exception as e:
            # location_id is initialized before try block, so it's always available
            release_lock(db, location_id, 'stale')
            print(f"  ✗ Exception: {e}")
            import traceback
            print(f"  Traceback: {traceback.format_exc()}")
            error_count += 1
    
    # Cleanup old images (runs daily)
    print()
    print("Cleaning up old movie images...")
    removed_images = cleanup_old_images()
    if removed_images > 0:
        print(f"  ✓ Removed {removed_images} old images")
    else:
        print("  ✓ No old images to remove")
    
    print()
    print("=" * 60)
    print(f"Daily refresh completed:")
    print(f"  Success: {success_count}")
    print(f"  Errors: {error_count}")
    print(f"  Images cleaned: {removed_images}")
    print("=" * 60)

if __name__ == '__main__':
    refresh_all_cities()

