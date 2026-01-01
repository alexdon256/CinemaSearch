#!/usr/bin/env python3
"""
Daily Background Refresh Job (DEPRECATED - Replaced by scraping agents)
Runs at 06:00 AM daily for image cleanup only

NOTE: This script has been replaced by 20 scraping agents (scraping_agent.py) that run daily.
- 20 scraping agents handle all scraping operations (load balanced, run daily at 06:00 AM)
- This script now only handles image cleanup
- Scraping agents replace the old daily refresh functionality with load-balanced parallel processing
"""

import os
import sys

# Add parent directory to path so we can import core modules
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from datetime import datetime, timezone
from dotenv import load_dotenv
from core.image_handler import cleanup_old_images

# Load environment variables
load_dotenv()

def refresh_all_cities():
    """
    Perform daily image cleanup only.
    All scraping is now handled by 20 scraping agents (scraping_agent.py) that run daily.
    """
    print(f"[{datetime.now(timezone.utc)}] Starting daily image cleanup job...")
    print("NOTE: All scraping is now handled by 20 scraping agents (scraping_agent.py)")
    print("This script only performs image cleanup.")
    print()
    
    # Cleanup old images (runs daily)
    print("Cleaning up old movie images...")
    removed_images = cleanup_old_images()
    if removed_images > 0:
        print(f"  ✓ Removed {removed_images} old images")
    else:
        print("  ✓ No old images to remove")
    
    print()
    print("=" * 60)
    print(f"Daily image cleanup completed:")
    print(f"  Images cleaned: {removed_images}")
    print("=" * 60)

if __name__ == '__main__':
    refresh_all_cities()

