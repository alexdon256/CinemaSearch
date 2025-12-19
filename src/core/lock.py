"""
Concurrency Locking Mechanism
Uses MongoDB atomic operations to prevent duplicate scraping requests
"""

from pymongo.database import Database
from datetime import datetime, timedelta

LOCK_TIMEOUT = 300  # 5 minutes timeout for locks

def acquire_lock(db: Database, city_name: str) -> bool:
    """
    Try to acquire a lock for scraping a city
    
    Args:
        db: MongoDB database instance
        city_name: Name of the city to lock
        
    Returns:
        True if lock acquired, False if already locked
    """
    try:
        # Try to update status to 'processing' atomically
        result = db.locations.update_one(
            {
                'city_name': city_name,
                '$or': [
                    {'status': {'$ne': 'processing'}},
                    {'last_updated': {'$lt': datetime.utcnow() - timedelta(seconds=LOCK_TIMEOUT)}}
                ]
            },
            {
                '$set': {
                    'status': 'processing',
                    'last_updated': datetime.utcnow()
                }
            }
        )
        
        # If no document exists, create one with processing status
        if result.matched_count == 0:
            db.locations.update_one(
                {'city_name': city_name},
                {
                    '$set': {
                        'status': 'processing',
                        'last_updated': datetime.utcnow()
                    }
                },
                upsert=True
            )
            return True
        
        return result.modified_count > 0
        
    except Exception as e:
        print(f"Error acquiring lock: {e}")
        return False

def release_lock(db: Database, city_name: str, status: str = 'fresh'):
    """
    Release a lock for a city
    
    Args:
        db: MongoDB database instance
        city_name: Name of the city to unlock
        status: Status to set after releasing lock (default: 'fresh')
    """
    try:
        db.locations.update_one(
            {'city_name': city_name},
            {
                '$set': {
                    'status': status,
                    'last_updated': datetime.utcnow()
                }
            }
        )
    except Exception as e:
        print(f"Error releasing lock: {e}")

def is_locked(db: Database, city_name: str) -> bool:
    """
    Check if a city is currently locked
    
    Args:
        db: MongoDB database instance
        city_name: Name of the city to check
        
    Returns:
        True if locked, False otherwise
    """
    try:
        city = db.locations.find_one({'city_name': city_name})
        if not city:
            return False
        
        status = city.get('status')
        if status != 'processing':
            return False
        
        # Check if lock has timed out
        last_updated = city.get('last_updated')
        if last_updated and isinstance(last_updated, datetime):
            if datetime.utcnow() - last_updated > timedelta(seconds=LOCK_TIMEOUT):
                return False  # Lock expired
        
        return True
        
    except Exception as e:
        print(f"Error checking lock: {e}")
        return False

