"""
Concurrency Locking Mechanism
Uses MongoDB atomic operations to prevent duplicate scraping requests
Prevents collisions between on-demand scraping and daily refresh
"""

from pymongo.database import Database
from datetime import datetime, timedelta

LOCK_TIMEOUT = 600  # 10 minutes timeout for locks
LOCK_SOURCE_ONDEMAND = 'on-demand'
LOCK_SOURCE_DAILY = 'daily-refresh'

def acquire_lock(db: Database, city_name: str, lock_source: str = LOCK_SOURCE_ONDEMAND, priority: bool = False) -> bool:
    """
    Try to acquire a lock for scraping a city
    
    Args:
        db: MongoDB database instance
        city_name: Name of the city to lock
        lock_source: Source of the lock request ('on-demand' or 'daily-refresh')
        priority: If True, can override existing locks (for on-demand requests)
        
    Returns:
        True if lock acquired, False if already locked
    """
    try:
        now = datetime.utcnow()
        timeout_threshold = now - timedelta(seconds=LOCK_TIMEOUT)
        
        # Build query based on priority
        if priority:
            # Priority requests (on-demand) can override expired or daily-refresh locks
            query = {
                'city_name': city_name,
                '$or': [
                    {'status': {'$ne': 'processing'}},
                    {'last_updated': {'$lt': timeout_threshold}},  # Expired lock
                    {'lock_source': LOCK_SOURCE_DAILY}  # Can override daily refresh
                ]
            }
        else:
            # Non-priority requests (daily refresh) only proceed if not locked
            query = {
                'city_name': city_name,
                '$or': [
                    {'status': {'$ne': 'processing'}},
                    {'last_updated': {'$lt': timeout_threshold}}  # Only expired locks
                ]
            }
        
        # Try to update status to 'processing' atomically
        result = db.locations.update_one(
            query,
            {
                '$set': {
                    'status': 'processing',
                    'lock_source': lock_source,
                    'last_updated': now
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
                        'lock_source': lock_source,
                        'last_updated': now
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
                },
                '$unset': {
                    'lock_source': ''  # Clear lock_source when releasing
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

def get_lock_info(db: Database, city_name: str) -> dict:
    """
    Get information about the current lock
    
    Args:
        db: MongoDB database instance
        city_name: Name of the city to check
        
    Returns:
        Dictionary with lock information or None if not locked
    """
    try:
        city = db.locations.find_one({'city_name': city_name})
        if not city or city.get('status') != 'processing':
            return None
        
        return {
            'source': city.get('lock_source', 'unknown'),
            'last_updated': city.get('last_updated'),
            'status': city.get('status')
        }
    except Exception as e:
        print(f"Error getting lock info: {e}")
        return None

