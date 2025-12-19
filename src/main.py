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
from core.lock import acquire_lock, release_lock

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
        'filter_by_genre': 'Filter by Genre',
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
        'filter_by_genre': 'Фільтр за жанром',
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
        'filter_by_genre': 'Фильтр по жанру',
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
    lang = get_language()
    t = TRANSLATIONS[lang]
    
    # Detect city
    city = detect_city_from_ip()
    
    # Get locations
    locations = list(db.locations.find({'status': 'fresh'}).limit(50))
    
    return render_template('index.html', 
                         translations=t,
                         lang=lang,
                         locations=locations,
                         visitor_count=get_visitor_count(),
                         donation_url=DONATION_URL)

@app.route('/api/showtimes')
def api_showtimes():
    """API endpoint for showtimes"""
    lang = get_language()
    city_name = request.args.get('city_id') or request.args.get('city_name')
    genre = request.args.get('genre')
    format_filter = request.args.get('format')
    language_filter = request.args.get('language')
    
    query = {}
    if city_name:
        # Find cinemas in this city
        city = db.locations.find_one({'city_name': city_name})
        if city:
            query['city_id'] = city_name
    
    showtimes = list(db.showtimes.find(query).sort('start_time', 1))
    
    # Filter out past showtimes
    now = datetime.utcnow()
    showtimes = [s for s in showtimes if s.get('start_time') and s['start_time'] > now]
    
    # Apply filters
    if genre:
        showtimes = [s for s in showtimes if genre.lower() in s.get('movie', {}).get('genre', '').lower()]
    if format_filter:
        showtimes = [s for s in showtimes if s.get('format') == format_filter]
    if language_filter:
        showtimes = [s for s in showtimes if language_filter.lower() in s.get('language', '').lower()]
    
    # Convert datetime objects to ISO strings for JSON
    for st in showtimes:
        if isinstance(st.get('start_time'), datetime):
            st['start_time'] = st['start_time'].isoformat()
        if isinstance(st.get('created_at'), datetime):
            st['created_at'] = st['created_at'].isoformat()
        # Remove MongoDB _id for JSON serialization
        if '_id' in st:
            st['_id'] = str(st['_id'])
    
    return jsonify(showtimes)

@app.route('/api/scrape', methods=['POST'])
def api_scrape():
    """On-demand scraping endpoint"""
    data = request.get_json() or {}
    city_name = data.get('city_name')
    
    if not city_name:
        return jsonify({'error': 'city_name required'}), 400
    
    # Check if city exists and is fresh (within last 24 hours)
    city = db.locations.find_one({'city_name': city_name})
    if city and city.get('status') == 'fresh':
        last_updated = city.get('last_updated')
        if last_updated:
            hours_old = (datetime.utcnow() - last_updated).total_seconds() / 3600
            if hours_old < 24:
                return jsonify({'status': 'fresh', 'message': 'Data already available'})
    
    # Try to acquire lock
    if not acquire_lock(db, city_name):
        return jsonify({'status': 'processing', 'message': 'Scraping already in progress'}), 202
    
    try:
        # Spawn AI agent to scrape
        agent = ClaudeAgent()
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
                },
                upsert=True
            )
            
            # Insert showtimes (remove old ones first)
            if result.get('showtimes'):
                # Add city_id to each showtime
                for st in result['showtimes']:
                    st['city_id'] = city_name
                # Delete old showtimes for this city
                db.showtimes.delete_many({'city_id': city_name})
                # Insert new showtimes
                db.showtimes.insert_many(result['showtimes'])
            
            release_lock(db, city_name)
            return jsonify({
                'status': 'success', 
                'message': 'Scraping completed',
                'showtimes_count': len(result.get('showtimes', []))
            })
        else:
            release_lock(db, city_name)
            return jsonify({'status': 'error', 'message': result.get('error', 'Unknown error')}), 500
            
    except Exception as e:
        release_lock(db, city_name)
        import traceback
        print(f"Scraping error: {traceback.format_exc()}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

@app.route('/set-language/<lang>')
def set_lang(lang):
    """Set language endpoint"""
    set_language(lang)
    return redirect(request.referrer or url_for('index'))

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

