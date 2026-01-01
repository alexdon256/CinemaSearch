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
LOCK_SOURCE_SCRAPING_AGENT = 'scraping-agent'

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
        from datetime import timezone
        now = datetime.now(timezone.utc)
        timeout_threshold = now - timedelta(seconds=LOCK_TIMEOUT)
        
        # Build query based on priority
        if priority:
            # Priority requests (on-demand) can override expired, daily-refresh, or scraping-agent locks
            query = {
                'city_name': city_name,
                '$or': [
                    {'status': {'$ne': 'processing'}},
                    {'last_updated': {'$lt': timeout_threshold}},  # Expired lock
                    {'lock_source': LOCK_SOURCE_DAILY},  # Can override daily refresh
                    {'lock_source': LOCK_SOURCE_SCRAPING_AGENT}  # Can override scraping agents
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
        
        # If no document exists, create one with processing status atomically
        if result.matched_count == 0:
            # Try atomic upsert with the same query conditions to prevent race conditions
            # This ensures we only create/update if the conditions are still met
            upsert_query = query.copy()
            upsert_result = db.locations.update_one(
                upsert_query,
                {
                    '$set': {
                        'status': 'processing',
                        'lock_source': lock_source,
                        'last_updated': now
                    }
                },
                upsert=True
            )
            # If we created a new document, we got the lock
            if upsert_result.upserted_id:
                return True
            # If we modified an existing document, we got the lock
            if upsert_result.modified_count > 0:
                return True
            # Document exists but wasn't modified - another process got the lock
            # For priority requests, try one more time to override scraping-agent or daily-refresh locks
            if priority:
                # Try to override scraping-agent or daily-refresh locks atomically
                override_result = db.locations.update_one(
                    {
                        'city_name': city_name,
                        'lock_source': {'$in': [LOCK_SOURCE_DAILY, LOCK_SOURCE_SCRAPING_AGENT]}
                    },
                    {
                        '$set': {
                            'status': 'processing',
                            'lock_source': lock_source,
                            'last_updated': now
                        }
                    }
                )
                if override_result.modified_count > 0:
                    return True
            return False
        
        return result.modified_count > 0
        
    except Exception as e:
        print(f"Error acquiring lock: {e}")
        return False

def release_lock(db: Database, city_name: str, status: str = 'fresh', lock_source: str = None):
    """
    Release a lock for a city
    
    Args:
        db: MongoDB database instance
        city_name: Name of the city to unlock
        status: Status to set after releasing lock (default: 'fresh')
        lock_source: Optional - only release if lock_source matches (prevents releasing someone else's lock)
    """
    try:
        from datetime import timezone
        query = {'city_name': city_name}
        
        # If lock_source is specified, only release if we still own the lock
        # This prevents a scraping agent from releasing an on-demand lock that overrode it
        if lock_source:
            query['lock_source'] = lock_source
        
        result = db.locations.update_one(
            query,
            {
                '$set': {
                    'status': status,
                    'last_updated': datetime.now(timezone.utc)
                },
                '$unset': {
                    'lock_source': ''  # Clear lock_source when releasing
                }
            }
        )
        
        # If lock_source was specified but we didn't modify anything, the lock was overridden
        if lock_source and result.modified_count == 0:
            return False  # Lock was overridden by another process
        
        return True
    except Exception as e:
        print(f"Error releasing lock: {e}")
        return False

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
            # Handle both timezone-aware and naive datetimes
            from datetime import timezone
            now_utc = datetime.now(timezone.utc)
            
            if last_updated.tzinfo is None:
                # Naive datetime - assume UTC
                last_updated_utc = last_updated.replace(tzinfo=timezone.utc)
            else:
                # Timezone-aware - convert to UTC
                last_updated_utc = last_updated.astimezone(timezone.utc)
            
            # Compare in UTC
            if now_utc - last_updated_utc > timedelta(seconds=LOCK_TIMEOUT):
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

