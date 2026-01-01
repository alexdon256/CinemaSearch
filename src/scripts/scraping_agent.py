#!/usr/bin/env python3
"""
Daily Scraping Agent (Replaces Daily Refresh)
Runs once per day and scrapes cities from the database with load balancing

This script runs as a separate OS process (via systemd timer) to ensure true parallel execution.
20 agents run simultaneously once daily, each processing a subset of cities based on agent_id (0-19).
This replaces the old daily_refresh.py with load-balanced parallel processing.

Load Balancing Strategy:
- Each agent has an ID (0-19)
- Cities are distributed using: hash(city_name) % 20 == agent_id (stable assignment)
- This ensures each city is processed by exactly one agent per day
- All 20 agents run in parallel without conflicts
- Runs once daily at 06:00 AM (via systemd timer)
"""

import os
import sys
import time
import argparse
from datetime import datetime, timedelta, timezone

# Add parent directory to path so we can import core modules
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pymongo import MongoClient
from pymongo.errors import ConnectionFailure
from dotenv import load_dotenv
from core.agent import ClaudeAgent
from core.lock import acquire_lock, release_lock, get_lock_info
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

# Total number of agents (for load balancing)
TOTAL_AGENTS = 20

def scrape_city(city_doc, agent, agent_id):
    """Scrape a single city"""
    city_name = city_doc.get('city_name')
    if not city_name:
        return False, "Missing city_name"
    
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
        return False, "Missing country"
    
    # Normalize location names to English
    original_city = city
    original_state = state
    original_country = country
    
    city = normalize_location_name(city, 'city')
    country = normalize_location_name(country, 'country')
    if state:
        state = normalize_location_name(state, 'state')
    
    # Build location_id using normalized names
    if state:
        location_id = f"{city}, {state}, {country}"
    else:
        location_id = f"{city}, {country}"
    
    # Check if data needs refresh
    location_check = db.locations.find_one({'city_name': location_id})
    now_utc = datetime.now(timezone.utc)
    
    if location_check and location_check.get('status') == 'fresh':
        last_updated = location_check.get('last_updated')
        if last_updated and isinstance(last_updated, datetime):
            if last_updated.tzinfo is None:
                last_updated_utc = last_updated.replace(tzinfo=timezone.utc)
            else:
                last_updated_utc = last_updated.astimezone(timezone.utc)
            
            hours_old = (now_utc - last_updated_utc).total_seconds() / 3600
            # Skip if updated in last 24 hours (daily agents run once per day)
            if hours_old < 24:
                return False, f"Data is fresh (updated {hours_old:.1f} hours ago)"
    
    # Check if on-demand scraping is in progress
    lock_info = get_lock_info(db, location_id)
    if lock_info and lock_info.get('source') == 'on-demand':
        return False, "On-demand scraping in progress"
    
    # Try to acquire lock (scraping agent has medium priority)
    if not acquire_lock(db, location_id, lock_source='scraping-agent', priority=False):
        return False, "Already processing"
    
    try:
        # Determine date range to scrape (incremental scraping)
        now = datetime.now(timezone.utc)
        two_weeks_from_now = now + timedelta(days=14)
        
        # Find all movies for this city to determine what date range we need
        movies = list(db.movies.find({'city_id': location_id}))
        
        if movies:
            # Find the latest showtime date
            latest_date_utc = None
            for movie in movies:
                theaters = movie.get('theaters', [])
                for theater in theaters:
                    showtimes = theater.get('showtimes', [])
                    for st in showtimes:
                        start_time = st.get('start_time')
                        if isinstance(start_time, datetime):
                            if start_time.tzinfo is None:
                                start_time_utc = start_time.replace(tzinfo=timezone.utc)
                            else:
                                start_time_utc = start_time.astimezone(timezone.utc)
                            if latest_date_utc is None or start_time_utc > latest_date_utc:
                                latest_date_utc = start_time_utc
            latest_date = latest_date_utc
            
            # Determine scrape range
            if latest_date:
                days_ahead = (latest_date - now).days
                
                if days_ahead >= 13:
                    # We have data up to 2 weeks ahead, only scrape the new day
                    date_start = two_weeks_from_now - timedelta(days=1)
                    date_end = two_weeks_from_now
                elif days_ahead >= 0:
                    # We have some data but not enough - fill gap to 2 weeks
                    date_start = max(now, latest_date - timedelta(hours=1))
                    date_end = two_weeks_from_now
                else:
                    # Data is in the past - catch up
                    date_start = now
                    date_end = two_weeks_from_now
            else:
                date_start = now
                date_end = two_weeks_from_now
        else:
            # No data yet, scrape full range
            date_start = now
            date_end = two_weeks_from_now
        
        # Check if lock was overridden before starting expensive scraping operation
        lock_info = get_lock_info(db, location_id)
        if lock_info and lock_info.get('source') != 'scraping-agent':
            # Lock was overridden by on-demand request - abort early
            print(f"  ⚠ Lock was overridden by on-demand request - aborting")
            release_lock(db, location_id, 'stale', lock_source='scraping-agent')  # Try to release, but won't if already overridden
            return False, "Interrupted by on-demand request"
        
        # Scrape city
        result = agent.scrape_city_showtimes(city, country, state, date_start, date_end)
        
        # Check again after scraping (might have been overridden during the long operation)
        lock_info = get_lock_info(db, location_id)
        if lock_info and lock_info.get('source') != 'scraping-agent':
            # Lock was overridden during scraping - discard results and abort
            print(f"  ⚠ Lock was overridden during scraping - discarding results")
            return False, "Interrupted by on-demand request during scraping"
        
        if result.get('success'):
            # Check lock ownership BEFORE writing any data to database
            # This prevents writing data if on-demand overrode the lock during scraping
            lock_info = get_lock_info(db, location_id)
            if lock_info and lock_info.get('source') != 'scraping-agent':
                # Lock was overridden during scraping - discard results and abort
                print(f"  ⚠ Lock was overridden before writing data - discarding results")
                return False, "Interrupted by on-demand request before data write"
            
            # Extract and normalize location components from result
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
            
            # Check lock ownership again before updating location status
            lock_info = get_lock_info(db, location_id)
            if lock_info and lock_info.get('source') != 'scraping-agent':
                print(f"  ⚠ Lock was overridden before updating location - discarding results")
                return False, "Interrupted by on-demand request before location update"
            
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
            
            # Check lock ownership before writing movies (most critical operation)
            lock_info = get_lock_info(db, location_id)
            if lock_info and lock_info.get('source') != 'scraping-agent':
                print(f"  ⚠ Lock was overridden before writing movies - discarding results")
                # Mark location as stale since we updated it but didn't write movies
                db.locations.update_one(
                    {'city_name': location_id},
                    {'$set': {'status': 'stale'}}
                )
                return False, "Interrupted by on-demand request before movie write"
            
            # Insert/update movies (merge with existing)
            if result.get('movies'):
                upserted_count = 0
                inserted_count = 0
                
                try:
                    for movie in result['movies']:
                        movie['city_id'] = location_id
                        
                        movie_title = movie.get('movie', {})
                        if not isinstance(movie_title, dict):
                            movie_title = {}
                        
                        movie_en = movie_title.get('en')
                        if not movie_en:
                            continue
                        
                        query = {
                            'city_id': location_id,
                            'movie.en': movie_en
                        }
                        
                        existing_movie = db.movies.find_one(query)
                        
                        if existing_movie:
                            # Merge theaters
                            existing_theaters = existing_movie.get('theaters', [])
                            new_theaters = movie.get('theaters', [])
                            
                            theater_map = {t.get('name'): t for t in existing_theaters}
                            
                            for new_theater in new_theaters:
                                theater_name = new_theater.get('name')
                                if theater_name in theater_map:
                                    # Merge showtimes
                                    existing_showtimes = theater_map[theater_name].get('showtimes', [])
                                    new_showtimes = new_theater.get('showtimes', [])
                                    
                                    existing_times = {st.get('start_time') for st in existing_showtimes if st.get('start_time')}
                                    
                                    for new_st in new_showtimes:
                                        if new_st.get('start_time') not in existing_times:
                                            existing_showtimes.append(new_st)
                                    
                                    theater_map[theater_name]['showtimes'] = existing_showtimes
                                    if new_theater.get('address'):
                                        theater_map[theater_name]['address'] = new_theater.get('address')
                                    if new_theater.get('website'):
                                        theater_map[theater_name]['website'] = new_theater.get('website')
                                else:
                                    theater_map[theater_name] = new_theater
                            
                            movie['theaters'] = list(theater_map.values())
                            movie['updated_at'] = datetime.now(timezone.utc)
                        
                        if 'created_at' not in movie:
                            movie['created_at'] = existing_movie.get('created_at', datetime.now(timezone.utc))
                        
                        result_upsert = db.movies.replace_one(query, movie)
                        if result_upsert.modified_count > 0:
                            upserted_count += 1
                        else:
                            result_insert = db.movies.insert_one(movie)
                            if result_insert.inserted_id:
                                inserted_count += 1
                    
                    if upserted_count > 0 or inserted_count > 0:
                        print(f"  ✓ Updated {upserted_count} existing, inserted {inserted_count} new movies")
                    
                    # Final check after all database writes - ensure we still own the lock
                    # This prevents releasing a lock that was overridden during the write operation
                    lock_info = get_lock_info(db, location_id)
                    if lock_info and lock_info.get('source') != 'scraping-agent':
                        print(f"  ⚠ Lock was overridden after writing movies - operation completed but lock transferred")
                        print(f"  ⚠ Data was written successfully, but on-demand now owns the lock")
                        # Data was written, but lock is now owned by on-demand
                        # Don't release lock - let on-demand handle it
                        return False, "Interrupted by on-demand request after data write"
                
                except Exception as insert_error:
                    print(f"  ✗ Error updating movies: {insert_error}")
                    import traceback
                    traceback.print_exc()
                    db.locations.update_one(
                        {'city_name': location_id},
                        {'$set': {'status': 'stale'}}
                    )
                    raise
            
            # Check if we still own the lock before releasing (might have been overridden by on-demand)
            lock_info = get_lock_info(db, location_id)
            if lock_info and lock_info.get('source') == 'scraping-agent':
                # We still own the lock, safe to release
                release_lock(db, location_id, 'fresh', lock_source='scraping-agent')
                return True, "Success"
            else:
                # Lock was overridden by on-demand request - don't release it, let on-demand handle it
                print(f"  ⚠ Lock was overridden by on-demand request - skipping release")
                return False, "Interrupted by on-demand request"
        else:
            # Check if we still own the lock before releasing
            lock_info = get_lock_info(db, location_id)
            if lock_info and lock_info.get('source') == 'scraping-agent':
                release_lock(db, location_id, 'stale', lock_source='scraping-agent')
            else:
                print(f"  ⚠ Lock was overridden - skipping release")
            return False, result.get('error', 'Unknown error')
            
    except Exception as e:
        # Check if we still own the lock before releasing
        lock_info = get_lock_info(db, location_id)
        if lock_info and lock_info.get('source') == 'scraping-agent':
            release_lock(db, location_id, 'stale', lock_source='scraping-agent')
        else:
            print(f"  ⚠ Lock was overridden - skipping release")
        print(f"  ✗ Exception: {e}")
        import traceback
        print(f"  Traceback: {traceback.format_exc()}")
        return False, str(e)

def run_scraping_agent(agent_id):
    """
    Run scraping agent once with load balancing (replaces daily refresh)
    
    Args:
        agent_id: Agent ID (0-19) - determines which cities this agent processes
    """
    if agent_id < 0 or agent_id >= TOTAL_AGENTS:
        print(f"ERROR: agent_id must be between 0 and {TOTAL_AGENTS - 1}")
        sys.exit(1)
    
    print(f"[{datetime.now(timezone.utc)}] Starting scraping agent #{agent_id} (of {TOTAL_AGENTS})")
    print(f"Load balancing: Processing cities where (hash(city_name) % {TOTAL_AGENTS} == {agent_id})")
    print(f"This agent runs once daily to replace daily refresh with load-balanced scraping")
    
    agent = ClaudeAgent()
    cycle_start = datetime.now(timezone.utc)
    print(f"\n{'='*60}")
    print(f"[{cycle_start}] Agent #{agent_id} - Daily Run")
    print(f"{'='*60}")
    
    # Get all cities from database
    cities = db.locations.find({})
    cities_list = list(cities)
    
    if not cities_list:
        print("No cities found in database")
        return
    
    # Filter cities for this agent using load balancing
    # Use hash of city_name for stable distribution (not index, which can change)
    # This ensures each city is always assigned to the same agent, even if list order changes
    matching_cities = []
    for city_doc in cities_list:
        city_name = city_doc.get('city_name', '')
        if city_name:
            # Use hash of city_name for consistent assignment
            city_hash = hash(city_name)
            # Convert to positive number and modulo
            assigned_agent = abs(city_hash) % TOTAL_AGENTS
            if assigned_agent == agent_id:
                matching_cities.append(city_doc)
    
    if not matching_cities:
        print(f"No cities assigned to agent #{agent_id}")
        return
    
    print(f"Found {len(matching_cities)} cities assigned to agent #{agent_id} (out of {len(cities_list)} total)")
    
    success_count = 0
    error_count = 0
    skipped_count = 0
    
    for city_doc in matching_cities:
        city_name = city_doc.get('city_name', 'Unknown')
        print(f"\nProcessing: {city_name}")
        
        success, message = scrape_city(city_doc, agent, agent_id)
        
        if success:
            success_count += 1
            print(f"  ✓ {message}")
        else:
            if "Data is fresh" in message or "Already processing" in message or "On-demand scraping" in message:
                skipped_count += 1
                print(f"  ⚠ {message}")
            else:
                error_count += 1
                print(f"  ✗ {message}")
        
        # Small delay between cities to avoid overwhelming the API
        time.sleep(2)
    
    cycle_end = datetime.now(timezone.utc)
    cycle_duration = (cycle_end - cycle_start).total_seconds()
    
    print(f"\n{'='*60}")
    print(f"Agent #{agent_id} - Daily run completed in {cycle_duration:.1f} seconds:")
    print(f"  Success: {success_count}")
    print(f"  Errors: {error_count}")
    print(f"  Skipped: {skipped_count}")
    print(f"{'='*60}\n")
    
    # Agent #0 also handles image cleanup (runs once per day)
    if agent_id == 0:
        print("Performing daily image cleanup (agent #0)...")
        from core.image_handler import cleanup_old_images
        removed_images = cleanup_old_images()
        if removed_images > 0:
            print(f"  ✓ Removed {removed_images} old images")
        else:
            print("  ✓ No old images to remove")
        print()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Daily scraping agent with load balancing (replaces daily refresh)')
    parser.add_argument('--agent-id', type=int, required=True, help=f'Agent ID (0-{TOTAL_AGENTS-1}) for load balancing')
    
    args = parser.parse_args()
    
    try:
        run_scraping_agent(args.agent_id)
    except KeyboardInterrupt:
        print(f"\n\nScraping agent #{args.agent_id} stopped by user")
        sys.exit(0)
    except Exception as e:
        print(f"\n\nFatal error in agent #{args.agent_id}: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

