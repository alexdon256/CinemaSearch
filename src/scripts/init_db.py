#!/usr/bin/env python3
"""
Database Schema Initialization Script
Creates collections, indexes, and initial data structures
"""

import os
import sys
from datetime import datetime
from pymongo import MongoClient, ASCENDING
from pymongo.errors import ConnectionFailure
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

MONGO_URI = os.getenv('MONGO_URI')
if not MONGO_URI:
    print("ERROR: MONGO_URI environment variable is required")
    sys.exit(1)

try:
    client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
    client.server_info()  # Test connection
    # Extract database name from URI or use default
    from urllib.parse import urlparse
    parsed = urlparse(MONGO_URI)
    db_name = parsed.path.lstrip('/').split('?')[0] if parsed.path else 'movie_db'
    db = client[db_name] if db_name else client.movie_db
    print(f"Connected to MongoDB: {db.name}")
except ConnectionFailure as e:
    print(f"ERROR: Failed to connect to MongoDB: {e}")
    sys.exit(1)

def create_locations_collection():
    """Create locations collection with indexes"""
    print("Creating 'locations' collection...")
    
    # Create indexes
    db.locations.create_index([("geo", "2dsphere")], name="geo_2dsphere")
    db.locations.create_index([("status", ASCENDING)], name="status_idx")
    db.locations.create_index([("city_name", ASCENDING)], name="city_name_idx", unique=True)
    db.locations.create_index([("country", ASCENDING)], name="country_idx")
    db.locations.create_index([("city", ASCENDING), ("country", ASCENDING)], name="city_country_idx")
    
    print("  ✓ Created indexes: geo (2dsphere), status, city_name, country, city+country")

def create_showtimes_collection():
    """Create showtimes collection with indexes and TTL"""
    print("Creating 'showtimes' collection...")
    
    # Create indexes
    db.showtimes.create_index([("cinema_id", ASCENDING), ("start_time", ASCENDING)], name="cinema_time_idx")
    db.showtimes.create_index([("start_time", ASCENDING)], name="start_time_idx")
    db.showtimes.create_index([("city_id", ASCENDING)], name="city_id_idx")
    
    # Create TTL index (expires after 90 days = 7,776,000 seconds)
    db.showtimes.create_index(
        [("created_at", ASCENDING)],
        expireAfterSeconds=7776000,
        name="created_at_ttl"
    )
    
    print("  ✓ Created indexes: cinema_id+start_time, start_time, city_id, created_at (TTL: 90 days)")

def create_stats_collection():
    """Create stats collection and initialize visitor counter"""
    print("Creating 'stats' collection...")
    
    # Initialize visitor counter if it doesn't exist
    if not db.stats.find_one({'_id': 'visitor_counter'}):
        db.stats.insert_one({
            '_id': 'visitor_counter',
            'count': 0,
            'created_at': datetime.utcnow()
        })
        print("  ✓ Initialized visitor_counter")
    else:
        print("  ✓ Visitor counter already exists")

def main():
    """Main initialization function"""
    print("=" * 60)
    print("CineStream Database Schema Initialization")
    print("=" * 60)
    print()
    
    try:
        create_locations_collection()
        create_showtimes_collection()
        create_stats_collection()
        
        print()
        print("=" * 60)
        print("Database initialization completed successfully!")
        print("=" * 60)
        
    except Exception as e:
        print(f"\nERROR: Database initialization failed: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()

