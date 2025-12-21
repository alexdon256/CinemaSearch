#!/usr/bin/env python3
"""
CineStream Web Application
High-concurrency movie showtime aggregator with AI-powered scraping
"""

import os
import sys
import argparse
from datetime import datetime
from flask import Flask, render_template, request, session, jsonify, redirect, url_for
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure
from dotenv import load_dotenv
from core.agent import ClaudeAgent
from core.lock import acquire_lock, release_lock, get_lock_info
from core.image_handler import cleanup_old_images, ensure_image_directory

# Load environment variables
load_dotenv()

app = Flask(__name__)
app.secret_key = os.getenv('SECRET_KEY', 'change-me-in-production')

# MongoDB connection
MONGO_URI = os.getenv('MONGO_URI')
if not MONGO_URI:
    raise ValueError("MONGO_URI environment variable is required")

try:
    mongo_client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
    mongo_client.server_info()  # Test connection
    # Extract database name from URI or use default
    from urllib.parse import urlparse
    parsed = urlparse(MONGO_URI)
    db_name = parsed.path.lstrip('/').split('?')[0] if parsed.path else 'movie_db'
    db = mongo_client[db_name] if db_name else mongo_client.movie_db
except (ConnectionFailure, Exception) as e:
    print(f"ERROR: Failed to connect to MongoDB: {e}")
    print("Please check MONGO_URI environment variable.")
    sys.exit(1)

# Localization dictionaries
TRANSLATIONS = {
    'en': {
        'title': 'CineStream - Movie Showtimes',
        'donate': 'Donate to Come Back Alive',
        'select_city': 'Select City',
        'filter_by_format': 'Filter by Format',
        'filter_by_language': 'Filter by Language',
        'sort_by_distance': 'Sort by Distance',
        'visitor_count': 'Total Visitors',
        'no_showtimes': 'No showtimes available',
        'buy_tickets': 'Buy Tickets',
        'loading': 'Loading...',
    },
    'ua': {
        'title': 'CineStream - Розклад кіно',
        'donate': 'Пожертвувати БФ Повернись живим',
        'select_city': 'Оберіть місто',
        'filter_by_format': 'Фільтр за форматом',
        'filter_by_language': 'Фільтр за мовою',
        'sort_by_distance': 'Сортувати за відстанню',
        'visitor_count': 'Всього відвідувачів',
        'no_showtimes': 'Немає сеансів',
        'buy_tickets': 'Купити квитки',
        'loading': 'Завантаження...',
    },
    'ru': {
        'title': 'CineStream - Расписание кино',
        'donate': 'Пожертвовать БФ Вернись живым',
        'select_city': 'Выберите город',
        'filter_by_format': 'Фильтр по формату',
        'filter_by_language': 'Фильтр по языку',
        'sort_by_distance': 'Сортировать по расстоянию',
        'visitor_count': 'Всего посетителей',
        'no_showtimes': 'Нет сеансов',
        'buy_tickets': 'Купить билеты',
        'loading': 'Загрузка...',
    }
}

DONATION_URL = 'https://savelife.in.ua'

def get_language():
    """Get user's preferred language from session or default to 'en'"""
    return session.get('language', 'en')

def set_language(lang):
    """Set user's preferred language"""
    if lang in ['en', 'ua', 'ru']:
        session['language'] = lang

def increment_visitor_counter():
    """Atomically increment visitor counter"""
    try:
        db.stats.update_one(
            {'_id': 'visitor_counter'},
            {'$inc': {'count': 1}},
            upsert=True
        )
    except Exception as e:
        print(f"Error incrementing visitor counter: {e}")

def get_visitor_count():
    """Get current visitor count"""
    try:
        result = db.stats.find_one({'_id': 'visitor_counter'})
        return result.get('count', 0) if result else 0
    except Exception as e:
        print(f"Error getting visitor count: {e}")
        return 0

def detect_city_from_ip():
    """Detect user's city from IP address (simplified - in production use GeoIP)"""
    # This is a placeholder - in production, use a GeoIP service
    # For now, return None to trigger on-demand scraping
    return None

@app.before_request
def before_request():
    """Middleware: Set language, increment counter"""
    # Set language from query parameter if provided
    lang = request.args.get('lang')
    if lang:
        set_language(lang)
    
    # Increment visitor counter (only once per session)
    if 'visited' not in session:
        increment_visitor_counter()
        session['visited'] = True

@app.route('/')
def index():
    """Main page"""
    try:
        lang = get_language()
        # Ensure lang is valid, default to 'en' if not
        if lang not in TRANSLATIONS:
            lang = 'en'
        t = TRANSLATIONS[lang]
        
        # Detect city
        city = detect_city_from_ip()
        
        # Get locations
        try:
            locations = list(db.locations.find({'status': 'fresh'}).limit(50))
        except Exception as e:
            print(f"Error fetching locations: {e}")
            locations = []
        
        return render_template('index.html', 
                             translations=t,
                             lang=lang,
                             locations=locations,
                             visitor_count=get_visitor_count(),
                             donation_url=DONATION_URL)
    except Exception as e:
        print(f"Error in index route: {e}")
        import traceback
        traceback.print_exc()
        # Return basic error page with safe defaults
        return render_template('index.html', 
                             translations=TRANSLATIONS['en'],
                             lang='en',
                             locations=[],
                             visitor_count=0,
                             donation_url=DONATION_URL), 500

@app.route('/api/showtimes')
def api_showtimes():
    """API endpoint for showtimes"""
    try:
        lang = get_language()
        city_name = request.args.get('city_id') or request.args.get('city_name')
        format_filter = request.args.get('format')
        language_filter = request.args.get('language')
        
        query = {}
        if city_name:
            # Find cinemas in this city
            try:
                city = db.locations.find_one({'city_name': city_name})
                if city:
                    query['city_id'] = city_name
            except Exception as e:
                print(f"Error finding city: {e}")
        
        try:
            showtimes = list(db.showtimes.find(query).sort('start_time', 1))
        except Exception as e:
            print(f"Error fetching showtimes: {e}")
            showtimes = []
        
        # Filter out past showtimes (handle both timezone-aware and naive datetimes)
        now = datetime.utcnow()
        filtered_showtimes = []
        for s in showtimes:
            try:
                start_time = s.get('start_time')
                if not start_time:
                    continue
                # Handle timezone-aware datetimes
                if isinstance(start_time, datetime):
                    if start_time.tzinfo is None:
                        # Naive datetime - compare directly with naive UTC
                        if start_time > now:
                            filtered_showtimes.append(s)
                    else:
                        # Timezone-aware - convert now to same timezone or compare in UTC
                        from datetime import timezone
                        now_aware = now.replace(tzinfo=timezone.utc)
                        if start_time > now_aware:
                            filtered_showtimes.append(s)
            except Exception as e:
                # Skip showtimes with invalid dates
                print(f"Error processing showtime: {e}")
                continue
        showtimes = filtered_showtimes
        
        # Apply filters
        if format_filter:
            showtimes = [s for s in showtimes if s.get('format') and s.get('format') == format_filter]
        if language_filter:
            showtimes = [s for s in showtimes if language_filter.lower() in s.get('language', '').lower()]
        
        # Sort showtimes by start_time (ascending - earliest first)
        # This ensures showtimes are displayed in chronological order
        def get_sort_time(st):
            """Helper to extract sortable time from showtime"""
            start_time = st.get('start_time')
            if isinstance(start_time, datetime):
                return start_time
            elif isinstance(start_time, str):
                try:
                    return datetime.fromisoformat(start_time.replace('Z', '+00:00'))
                except (ValueError, AttributeError):
                    return datetime.max
            else:
                return datetime.max
        
        showtimes.sort(key=get_sort_time)
        
        # Convert datetime objects to ISO strings for JSON
        for st in showtimes:
            try:
                if isinstance(st.get('start_time'), datetime):
                    st['start_time'] = st['start_time'].isoformat()
                if isinstance(st.get('created_at'), datetime):
                    st['created_at'] = st['created_at'].isoformat()
                # Remove MongoDB _id for JSON serialization
                if '_id' in st:
                    st['_id'] = str(st['_id'])
            except Exception as e:
                print(f"Error serializing showtime: {e}")
                continue
        
        return jsonify(showtimes)
    except Exception as e:
        print(f"Error in api_showtimes: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/scrape/status/<city_name>')
def api_scrape_status(city_name):
    """Check scraping status for a city"""
    try:
        # URL decode city_name in case it contains special characters
        from urllib.parse import unquote
        city_name = unquote(city_name)
        
        city = db.locations.find_one({'city_name': city_name})
        if not city:
            return jsonify({'status': 'not_found', 'message': 'City not scraped yet'})
        
        status = city.get('status', 'unknown')
        last_updated = city.get('last_updated')
        lock_source = city.get('lock_source')
        
        # Handle datetime serialization safely
        last_updated_iso = None
        if last_updated:
            if isinstance(last_updated, datetime):
                last_updated_iso = last_updated.isoformat()
            else:
                try:
                    last_updated_iso = str(last_updated)
                except Exception:
                    pass
        
        return jsonify({
            'status': status,
            'last_updated': last_updated_iso,
            'lock_source': lock_source,
            'ready': status == 'fresh',
            'processing_by': lock_source if status == 'processing' else None
        })
    except Exception as e:
        print(f"Error getting scrape status: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

@app.route('/api/scrape', methods=['POST'])
def api_scrape():
    """On-demand scraping endpoint"""
    data = request.get_json() or {}
    city = data.get('city') or data.get('city_name')  # Support both formats
    country = data.get('country')
    state = data.get('state') or data.get('province') or data.get('region')  # Support multiple field names
    
    # Input validation and sanitization
    if not city:
        return jsonify({'error': 'city required'}), 400
    
    if not country:
        return jsonify({'error': 'country required for accurate location identification'}), 400
    
    # Sanitize inputs (remove dangerous characters, limit length)
    city = str(city).strip()[:100] if city else ''
    country = str(country).strip()[:100] if country else ''
    state = str(state).strip()[:100] if state else ''
    
    # Basic validation - reject empty after sanitization
    if not city or not country:
        return jsonify({'error': 'Invalid city or country'}), 400
    
    # Reject potentially dangerous characters
    dangerous_chars = ['<', '>', '{', '}', '[', ']', '$', '\\', '/']
    if any(char in city or char in country or (state and char in state) for char in dangerous_chars):
        return jsonify({'error': 'Invalid characters in input'}), 400
    
    # Build location identifier (city, state, country format)
    if state:
        location_id = f"{city}, {state}, {country}"
    else:
        location_id = f"{city}, {country}"
    
    # Check if location exists and is fresh (within last 24 hours)
    location = db.locations.find_one({'city_name': location_id})
    if location and location.get('status') == 'fresh':
        last_updated = location.get('last_updated')
        if last_updated and isinstance(last_updated, datetime):
            # Handle both timezone-aware and naive datetimes
            if last_updated.tzinfo is None:
                # Naive datetime - compare directly
                hours_old = (datetime.utcnow() - last_updated).total_seconds() / 3600
            else:
                # Timezone-aware - convert to UTC for comparison
                from datetime import timezone
                now_aware = datetime.utcnow().replace(tzinfo=timezone.utc)
                hours_old = (now_aware - last_updated).total_seconds() / 3600
            if hours_old < 24:
                # Return existing showtimes immediately
                showtimes = get_showtimes_for_city(location_id)
                return jsonify({
                    'status': 'fresh', 
                    'message': 'Data already available',
                    'showtimes': showtimes
                })
    
    # Try to acquire lock with priority (on-demand requests take precedence)
    if not acquire_lock(db, location_id, lock_source='on-demand', priority=True):
        # Check what's holding the lock
        lock_info = get_lock_info(db, location_id)
        if lock_info:
            source = lock_info.get('source', 'unknown')
            if source == 'daily-refresh':
                message = 'Daily refresh is currently running. Your request will be processed after it completes.'
            else:
                message = 'Scraping already in progress'
        else:
            message = 'Scraping already in progress'
        return jsonify({'status': 'processing', 'message': message}), 202
    
    try:
        # Spawn AI agent to scrape
        agent = ClaudeAgent()
        result = agent.scrape_city_showtimes(city, country, state)
        
        if result.get('success'):
            # Update location status with city/state/country info
            db.locations.update_one(
                {'city_name': location_id},
                {
                    '$set': {
                        'city': city,
                        'state': state or '',
                        'country': country,
                        'status': 'fresh',
                        'last_updated': datetime.utcnow()
                    }
                },
                upsert=True
            )
            
            # Insert showtimes (merge with existing, don't delete first)
            if result.get('showtimes'):
                # Ensure city_id is set correctly and prepare showtimes
                showtimes_to_insert = []
                for st in result['showtimes']:
                    st['city_id'] = location_id
                    showtimes_to_insert.append(st)
                
                if showtimes_to_insert:
                    # Use upsert strategy to avoid deleting existing records
                    # Create unique identifier for each showtime (cinema + movie + start_time)
                    upserted_count = 0
                    inserted_count = 0
                    
                    try:
                        for st in showtimes_to_insert:
                            # Create a unique query to identify this specific showtime
                            # Use cinema_id, movie title, and start_time as unique identifier
                            movie_title = st.get('movie', {})
                            if not isinstance(movie_title, dict):
                                movie_title = {}
                            
                            # Build query with required fields
                            query = {
                                'city_id': location_id,
                                'cinema_id': st.get('cinema_id', ''),
                                'start_time': st.get('start_time')
                            }
                            
                            # Add movie title to query if available (helps identify duplicates)
                            movie_en = movie_title.get('en')
                            if movie_en:
                                query['movie.en'] = movie_en
                            
                            # Remove None/empty values from query
                            query = {k: v for k, v in query.items() if v is not None and v != ''}
                            
                            # Use replace_one with upsert=True to update existing or insert new
                            # This preserves existing records and only updates/inserts what's new
                            result_upsert = db.showtimes.replace_one(
                                query,
                                st,
                                upsert=True
                            )
                            
                            if result_upsert.upserted_id:
                                inserted_count += 1
                            elif result_upsert.modified_count > 0:
                                upserted_count += 1
                        
                        if upserted_count > 0 or inserted_count > 0:
                            print(f"Updated {upserted_count} existing showtimes, inserted {inserted_count} new showtimes")
                        
                        # Only delete expired showtimes (older than 24 hours past their start_time)
                        from datetime import timedelta
                        expired_cutoff = datetime.utcnow() - timedelta(hours=24)
                        delete_result = db.showtimes.delete_many({
                            'city_id': location_id,
                            'start_time': {'$lt': expired_cutoff}
                        })
                        if delete_result.deleted_count > 0:
                            print(f"Cleaned up {delete_result.deleted_count} expired showtimes")
                            
                    except Exception as insert_error:
                        # If insert fails, existing data is preserved
                        print(f"Error updating showtimes: {insert_error}")
                        db.locations.update_one(
                            {'city_name': location_id},
                            {'$set': {'status': 'stale'}}
                        )
                        raise  # Re-raise to be caught by outer exception handler
                
                # Cleanup old images periodically (every 10th scrape)
                import random
                if random.randint(1, 10) == 1:
                    cleanup_old_images()
            
            release_lock(db, location_id)
            
            # Return showtimes immediately so user doesn't need another request
            formatted_showtimes = get_showtimes_for_city(location_id)
            return jsonify({
                'status': 'success', 
                'message': 'Scraping completed',
                'city': city,
                'state': state or '',
                'country': country,
                'showtimes_count': len(formatted_showtimes),
                'showtimes': formatted_showtimes
            })
        else:
            release_lock(db, location_id)
            return jsonify({'status': 'error', 'message': result.get('error', 'Unknown error')}), 500
            
    except Exception as e:
        release_lock(db, location_id)
        import traceback
        print(f"Scraping error: {traceback.format_exc()}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

def get_showtimes_for_city(city_name):
    """Helper to get formatted showtimes for a city"""
    query = {'city_id': city_name}
    showtimes = list(db.showtimes.find(query).sort('start_time', 1))
    
    # Filter out past showtimes (handle both timezone-aware and naive datetimes)
    now = datetime.utcnow()
    filtered_showtimes = []
    for s in showtimes:
        start_time = s.get('start_time')
        if not start_time:
            continue
        # Handle timezone-aware datetimes
        if isinstance(start_time, datetime):
            if start_time.tzinfo is None:
                # Naive datetime - compare directly with naive UTC
                if start_time > now:
                    filtered_showtimes.append(s)
            else:
                # Timezone-aware - convert now to same timezone or compare in UTC
                from datetime import timezone
                now_aware = now.replace(tzinfo=timezone.utc)
                if start_time > now_aware:
                    filtered_showtimes.append(s)
    showtimes = filtered_showtimes
    
    # Sort showtimes by start_time (ascending - earliest first)
    # This ensures showtimes are displayed in chronological order
    def get_sort_time(st):
        """Helper to extract sortable time from showtime"""
        start_time = st.get('start_time')
        if isinstance(start_time, datetime):
            return start_time
        elif isinstance(start_time, str):
            try:
                return datetime.fromisoformat(start_time.replace('Z', '+00:00'))
            except (ValueError, AttributeError):
                return datetime.max
        else:
            return datetime.max
    
    showtimes.sort(key=get_sort_time)
    
    # Convert datetime objects to ISO strings for JSON
    for st in showtimes:
        if isinstance(st.get('start_time'), datetime):
            st['start_time'] = st['start_time'].isoformat()
        if isinstance(st.get('created_at'), datetime):
            st['created_at'] = st['created_at'].isoformat()
        if '_id' in st:
            st['_id'] = str(st['_id'])
    
    return showtimes

@app.route('/set-language/<lang>')
def set_lang(lang):
    """Set language endpoint"""
    set_language(lang)
    return redirect(request.referrer or url_for('index'))

@app.route('/static/movie_images/<filename>')
def serve_movie_image(filename):
    """Serve movie images from local storage"""
    from flask import send_from_directory
    from core.image_handler import IMAGE_BASE_DIR, ensure_image_directory
    import os.path
    
    try:
        # Security: prevent directory traversal and validate filename
        if not filename or not isinstance(filename, str):
            return '', 404
        
        # Remove any path components
        filename = os.path.basename(filename)
        
        # Validate filename doesn't contain dangerous characters
        if '..' in filename or '/' in filename or '\\' in filename:
            return '', 404
        
        # Validate filename format (alphanumeric, dots, dashes, underscores only)
        if not all(c.isalnum() or c in ('.', '-', '_') for c in filename):
            return '', 404
        
        # Validate extension
        if not filename.lower().endswith(('.jpg', '.jpeg', '.png', '.gif', '.webp')):
            return '', 404
        
        ensure_image_directory()
        return send_from_directory(IMAGE_BASE_DIR, filename)
    except Exception as e:
        print(f"Error serving image {filename}: {e}")
        return '', 404

@app.route('/api/cleanup-images', methods=['POST'])
def api_cleanup_images():
    """Manually trigger image cleanup (also called automatically)"""
    try:
        removed_count = cleanup_old_images()
        return jsonify({'success': True, 'removed_count': removed_count})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(description='CineStream Web Application')
    parser.add_argument('--port', type=int, default=8000, help='Port to bind to')
    parser.add_argument('--host', default='127.0.0.1', help='Host to bind to')
    parser.add_argument('--debug', action='store_true', help='Enable debug mode')
    
    args = parser.parse_args()
    
    port = args.port
    host = args.host
    debug = args.debug
    
    print(f"Starting CineStream on {host}:{port}")
    print(f"MongoDB: {MONGO_URI}")
    
    app.run(host=host, port=port, debug=debug, threaded=True)

if __name__ == '__main__':
    main()

