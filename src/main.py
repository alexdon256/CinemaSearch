#!/usr/bin/env python3
"""
CineStream Web Application
High-concurrency movie showtime aggregator with AI-powered scraping
"""

import os
import sys
import argparse
import smtplib
from datetime import datetime
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
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
        'terms': 'Terms of Service',
        'privacy': 'Privacy Policy',
        'feedback': 'Feedback',
        'send_feedback': 'Send Feedback',
        'feedback_sent': 'Thank you! Your feedback has been sent.',
        'feedback_error': 'Error sending feedback. Please try again.',
        'country': 'Country',
        'state_province': 'State/Province (optional)',
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
        'terms': 'Умови використання',
        'privacy': 'Політика конфіденційності',
        'feedback': 'Зворотний зв\'язок',
        'send_feedback': 'Надіслати відгук',
        'feedback_sent': 'Дякуємо! Ваш відгук надіслано.',
        'feedback_error': 'Помилка відправки відгуку. Спробуйте ще раз.',
        'country': 'Країна',
        'state_province': 'Штат/Провінція (необов\'язково)',
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
        'terms': 'Условия использования',
        'privacy': 'Политика конфиденциальности',
        'feedback': 'Обратная связь',
        'send_feedback': 'Отправить отзыв',
        'feedback_sent': 'Спасибо! Ваш отзыв отправлен.',
        'feedback_error': 'Ошибка отправки отзыва. Попробуйте еще раз.',
        'country': 'Страна',
        'state_province': 'Штат/Провинция (необязательно)',
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
    """Detect user's city and country from IP address using free GeoIP service"""
    try:
        # Get real client IP from request headers (works with Nginx proxy)
        # X-Forwarded-For contains the original client IP when behind a proxy
        client_ip = request.headers.get('X-Forwarded-For', '').split(',')[0].strip()
        if not client_ip:
            client_ip = request.headers.get('X-Real-IP', '').strip()
        if not client_ip:
            client_ip = request.remote_addr
        
        # Skip geolocation for localhost/private IPs
        if client_ip in ('127.0.0.1', 'localhost', '::1') or client_ip.startswith(('192.168.', '10.', '172.16.', '172.17.', '172.18.', '172.19.', '172.20.', '172.21.', '172.22.', '172.23.', '172.24.', '172.25.', '172.26.', '172.27.', '172.28.', '172.29.', '172.30.', '172.31.')):
            return None
        
        # Use free ip-api.com service (no API key required, 45 requests/minute limit)
        # Alternative: ipapi.co (requires API key for city-level data)
        import urllib.request
        import json
        import time
        
        # Rate limiting: cache results for 1 hour per IP
        cache_key = f"geoip_{client_ip}"
        cached = session.get(cache_key)
        if cached:
            return cached
        
        # Request geolocation (free tier: 45 req/min, no API key needed)
        url = f"http://ip-api.com/json/{client_ip}?fields=status,country,regionName,city,lat,lon"
        
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                data = json.loads(response.read().decode())
                
                if data.get('status') == 'success':
                    city = data.get('city', '').strip()
                    country = data.get('country', '').strip()
                    region = data.get('regionName', '').strip()
                    
                    # Validate city name - reject if too short, contains only numbers, or seems invalid
                    if city and country:
                        # Filter out suspicious city names:
                        # - Too short (less than 3 characters)
                        # - Contains only numbers
                        # - Very unusual patterns
                        city_lower = city.lower()
                        
                        # Common invalid patterns from IP geolocation services
                        invalid_patterns = [
                            len(city) < 3,  # Too short (reject very short names like "Auly")
                            city.isdigit(),  # Only numbers
                            # Reject very unusual single-word city names that might be errors
                            len(city.split()) == 1 and len(city) < 5 and not any(c.isupper() for c in city),  # Very short single word without capitals
                        ]
                        
                        # If city seems invalid, don't return it
                        if any(invalid_patterns):
                            print(f"Rejected suspicious city name from geolocation: '{city}' for IP {client_ip}")
                            return None
                        
                        result = {
                            'city': city,
                            'country': country,
                            'region': region,
                            'lat': data.get('lat'),
                            'lon': data.get('lon')
                        }
                        # Cache in session for 1 hour
                        session[cache_key] = result
                        return result
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as e:
            # Silently fail - geolocation is optional
            print(f"Geolocation error for IP {client_ip}: {e}")
            pass
        
        return None
    except Exception as e:
        # Silently fail - geolocation is optional
        print(f"Geolocation error: {e}")
    return None

@app.context_processor
def inject_base_path():
    """Inject base_path into all templates based on request host"""
    # Check if request is coming through domain (not IP/localhost)
    # If Host header contains a domain name (not IP or localhost), use root path
    host = request.headers.get('Host', '').split(':')[0]  # Remove port if present
    
    # Check if host is an IP address (IPv4 or IPv6) or localhost
    is_ip = False
    if host:
        # IPv4 address check (e.g., 192.168.1.1)
        parts = host.split('.')
        if len(parts) == 4 and all(part.isdigit() and 0 <= int(part) <= 255 for part in parts):
            is_ip = True
        # IPv6 address check (contains colons and brackets)
        elif ':' in host or host.startswith('['):
            is_ip = True
        # localhost variants
        elif host.lower() in ('localhost', '127.0.0.1', '::1', '[::1]'):
            is_ip = True
    
    # Use root path for domain, /cinestream/ for IP/localhost
    base_path = '/' if (host and not is_ip) else '/cinestream/'
    
    return dict(base_path=base_path)

@app.before_request
def before_request():
    """Middleware: Set language, increment counter"""
    # Set language from query parameter if provided
    lang = request.args.get('lang')
    if lang:
        set_language(lang)
    
    # Increment visitor counter (only once per session, skip for health checks and internal requests)
    # Skip if X-Skip-Visitor-Counter header is present (for verify-workers, health checks, etc.)
    if 'visited' not in session and not request.headers.get('X-Skip-Visitor-Counter'):
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
        
        # Don't auto-detect from IP - let browser geolocation handle it
        # This gives users control and better accuracy
        detected_city = None
        detected_country = None
        detected_region = None
        
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
                             donation_url=DONATION_URL,
                             detected_city=detected_city,
                             detected_country=detected_country,
                             detected_region=detected_region)
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

# Cache for location translations (key: lang_city_state_country)
_translation_cache = {}

def translate_address(address_text, target_lang='en'):
    """
    Translate address text to target language using Nominatim geocoding.
    Uses the address to find the location and returns it in the target language.
    """
    if not address_text or not address_text.strip():
        return address_text
    
    import urllib.request
    import json
    import urllib.parse
    
    address_text = address_text.strip()
    
    # Check cache first
    cache_key = f"addr_{target_lang}_{address_text.lower()}"
    if cache_key in _translation_cache:
        return _translation_cache[cache_key]
    
    # Map language codes to Nominatim language codes
    lang_map = {
        'en': 'en',
        'ua': 'uk',  # Ukrainian
        'ru': 'ru'   # Russian
    }
    nominatim_lang = lang_map.get(target_lang, 'en')
    
    try:
        # Use Nominatim to geocode the address and get it in target language
        url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(address_text)}&format=json&limit=1&addressdetails=1&accept-language={nominatim_lang}"
        
        req = urllib.request.Request(url, headers={
            'User-Agent': 'CineStream/1.0'
        })
        
        with urllib.request.urlopen(req, timeout=3) as response:
            results = json.loads(response.read().decode())
            
            if results and len(results) > 0:
                # Get the display_name in target language, or reconstruct from address components
                result = results[0]
                address = result.get('address', {})
                
                # Build address from components in target language
                address_parts = []
                
                # Street address
                if address.get('road'):
                    road = address.get('road')
                    if address.get('house_number'):
                        road = f"{road} {address.get('house_number')}"
                    address_parts.append(road)
                
                # City/town
                city = (address.get('city') or 
                       address.get('town') or 
                       address.get('village') or 
                       address.get('municipality') or
                       '')
                if city:
                    address_parts.append(city)
                
                # State/region
                state = (address.get('state') or 
                        address.get('province') or 
                        address.get('region') or
                        '')
                if state:
                    address_parts.append(state)
                
                # Country
                country = address.get('country', '')
                if country:
                    address_parts.append(country)
                
                if address_parts:
                    translated_address = ', '.join(address_parts)
                    _translation_cache[cache_key] = translated_address
                    return translated_address
        
        # If geocoding fails, return original address
        _translation_cache[cache_key] = address_text
        return address_text
        
    except Exception as e:
        print(f"Address translation error for {address_text}: {e}")
        # Return original address if translation fails
        _translation_cache[cache_key] = address_text
        return address_text

def translate_location_name(city, state, country, target_lang='en'):
    """
    Translate location names to target language using Nominatim.
    Returns dict with translated city, state, country.
    Uses caching to avoid repeated API calls.
    """
    import urllib.request
    import json
    import urllib.parse
    
    result = {'city': city, 'state': state, 'country': country}
    
    # Check cache first
    cache_key = f"{target_lang}_{city}_{state}_{country}".lower()
    if cache_key in _translation_cache:
        return _translation_cache[cache_key]
    
    # Map language codes to Nominatim language codes
    lang_map = {
        'en': 'en',
        'ua': 'uk',  # Ukrainian
        'ru': 'ru'   # Russian
    }
    nominatim_lang = lang_map.get(target_lang, 'en')
    
    # Build search query with all location components
    location_parts = []
    if city:
        location_parts.append(city)
    if state:
        location_parts.append(state)
    if country:
        location_parts.append(country)
    
    if not location_parts:
        _translation_cache[cache_key] = result
        return result
    
    search_query = ', '.join(location_parts)
    
    try:
        # Use Nominatim to search and get translated names
        url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(search_query)}&format=json&limit=1&addressdetails=1&accept-language={nominatim_lang}"
        
        req = urllib.request.Request(url, headers={
            'User-Agent': 'CineStream/1.0'
        })
        
        with urllib.request.urlopen(req, timeout=3) as response:
            results = json.loads(response.read().decode())
            
            if results and len(results) > 0:
                address = results[0].get('address', {})
                
                # Get translated names
                if city:
                    result['city'] = (address.get('city') or 
                                     address.get('town') or 
                                     address.get('village') or 
                                     address.get('municipality') or
                                     city)
                if state:
                    result['state'] = (address.get('state') or 
                                      address.get('province') or 
                                      address.get('region') or
                                      state)
                if country:
                    result['country'] = address.get('country', country)
        
    except Exception as e:
        print(f"Translation error for {search_query}: {e}")
        # Return original names if translation fails
    
    # Cache the result
    _translation_cache[cache_key] = result
    return result

def verify_location_exists(city, country, state=None):
    """
    Verify that a location (city, state, country) actually exists using Nominatim API.
    Returns True if location is found, False otherwise.
    This prevents scraping non-existent places.
    """
    if not city or not country:
        return False
    
    import urllib.request
    import json
    import urllib.parse
    
    # Build search query
    location_parts = [city]
    if state:
        location_parts.append(state)
    location_parts.append(country)
    search_query = ', '.join(location_parts)
    
    # Check cache first (use session cache)
    cache_key = f"verified_location_{search_query.lower()}"
    cached = session.get(cache_key)
    if cached is not None:
        return cached
    
    try:
        url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(search_query)}&format=json&limit=5&addressdetails=1&accept-language=en"
        
        req = urllib.request.Request(url, headers={
            'User-Agent': 'CineStream/1.0'
        })
        
        with urllib.request.urlopen(req, timeout=3) as response:
            results = json.loads(response.read().decode())
            
            if not results or len(results) == 0:
                # No results found - location doesn't exist
                session[cache_key] = False
                return False
            
            # Check if any result matches the location
            city_lower = city.lower()
            country_lower = country.lower()
            state_lower = state.lower() if state else ''
            
            for result in results:
                address = result.get('address', {})
                result_city = (address.get('city') or 
                             address.get('town') or 
                             address.get('village') or 
                             address.get('municipality') or '').lower()
                result_country = (address.get('country') or '').lower()
                result_state = (address.get('state') or 
                              address.get('province') or 
                              address.get('region') or '').lower()
                
                # Check if country matches
                if result_country:
                    if country_lower not in result_country and result_country not in country_lower:
                        continue
                
                # Check if city matches (fuzzy matching)
                if result_city:
                    # Exact or substring match
                    if city_lower in result_city or result_city in city_lower:
                        # If state is provided, check it matches too
                        if state_lower:
                            if result_state and (state_lower in result_state or result_state in state_lower):
                                session[cache_key] = True
                                return True
                        else:
                            # No state provided, city and country match is enough
                            session[cache_key] = True
                            return True
                    
                    # Word-based matching (e.g., "New York" matches "New York City")
                    city_words = [w for w in city_lower.split() if len(w) > 2]
                    result_city_words = [w for w in result_city.split() if len(w) > 2]
                    matching_words = sum(1 for w in city_words if w in result_city_words)
                    
                    if matching_words >= min(len(city_words), 2):
                        # If state is provided, check it matches too
                        if state_lower:
                            if result_state and (state_lower in result_state or result_state in state_lower):
                                session[cache_key] = True
                                return True
                        else:
                            session[cache_key] = True
                            return True
            
            # No matching result found
            session[cache_key] = False
            return False
            
    except Exception as e:
        print(f"Location verification error for {search_query}: {e}")
        # On error, don't block - but log it
        # Return False to be safe (prevent scraping invalid locations)
        session[cache_key] = False
        return False

def normalize_location_names_together(city, state, country):
    """
    Optimized: Normalize city, state, and country in a single Nominatim API call.
    Returns tuple (normalized_city, normalized_state, normalized_country) or None if fails.
    """
    if not city or not country:
        return None
    
    import urllib.request
    import json
    import urllib.parse
    
    # Build search query with all components
    location_parts = [city]
    if state:
        location_parts.append(state)
    location_parts.append(country)
    search_query = ', '.join(location_parts)
    
    # Check cache first
    cache_key = f"normalized_together_{search_query.lower()}"
    cached = session.get(cache_key)
    if cached:
        return tuple(cached) if isinstance(cached, list) else None
    
    try:
        url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(search_query)}&format=json&limit=1&addressdetails=1&accept-language=en"
        
        req = urllib.request.Request(url, headers={
            'User-Agent': 'CineStream/1.0'
        })
        
        with urllib.request.urlopen(req, timeout=3) as response:
            results = json.loads(response.read().decode())
            
            if results and len(results) > 0:
                result = results[0]
                address = result.get('address', {})
                
                # Extract all three components from the same result
                normalized_city = (address.get('city') or 
                                 address.get('town') or 
                                 address.get('village') or 
                                 address.get('municipality') or
                                 city)
                normalized_country = address.get('country', country)
                normalized_state = None
                if state:
                    normalized_state = (address.get('state') or 
                                       address.get('province') or 
                                       address.get('region') or
                                       state)
                
                normalized = (normalized_city, normalized_state, normalized_country)
                # Cache the result
                session[cache_key] = list(normalized)  # Store as list for JSON serialization
                return normalized
        
        # If no results, return None to trigger fallback
        return None
        
    except Exception as e:
        print(f"Combined normalization error for {search_query}: {e}")
        return None

def normalize_location_name(name, location_type='city'):
    """
    Normalize location names to English to avoid duplicates from different languages.
    Uses Nominatim to get the canonical English name.
    """
    if not name or not name.strip():
        return name
    
    import urllib.request
    import json
    import time
    
    name = name.strip()
    
    # Cache normalized names to avoid repeated API calls
    cache_key = f"normalized_{location_type}_{name.lower()}"
    cached = session.get(cache_key)
    if cached:
        return cached
    
    try:
        # Use Nominatim to search for the location and get English name
        # Add country context for better results
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
                
                # Get English name from display_name or address
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
                session[cache_key] = normalized
                return normalized
        
        # If no results, return original name
        session[cache_key] = name
        return name
        
    except Exception as e:
        print(f"Normalization error for {name}: {e}")
        # Return original name if normalization fails
        return name

@app.route('/api/geocode', methods=['POST'])
def api_geocode():
    """Reverse geocode coordinates to get city, country, and region (normalized to English)"""
    try:
        data = request.get_json() or {}
        lat = data.get('lat')
        lon = data.get('lon')
        
        if not lat or not lon:
            return jsonify({'success': False, 'error': 'Latitude and longitude required'}), 400
        
        # Validate coordinates
        try:
            lat = float(lat)
            lon = float(lon)
            if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
                return jsonify({'success': False, 'error': 'Invalid coordinates'}), 400
        except (ValueError, TypeError):
            return jsonify({'success': False, 'error': 'Invalid coordinate format'}), 400
        
        # Use Nominatim for reverse geocoding (free, no API key needed)
        import urllib.request
        import json
        import urllib.parse
        
        url = f"https://nominatim.openstreetmap.org/reverse?format=json&lat={lat}&lon={lon}&addressdetails=1&accept-language=en"
        
        try:
            req = urllib.request.Request(url, headers={
                'User-Agent': 'CineStream/1.0'  # Required by Nominatim
            })
            with urllib.request.urlopen(req, timeout=5) as response:
                data = json.loads(response.read().decode())
                
                if data and 'address' in data:
                    address = data.get('address', {})
                    
                    # Extract city (can be in different fields) - already in English from accept-language=en
                    city = (address.get('city') or 
                           address.get('town') or 
                           address.get('village') or 
                           address.get('municipality') or
                           address.get('county') or
                           '')
                    
                    # Extract country - already in English
                    country = address.get('country', '')
                    
                    # Extract region/state - already in English
                    region = (address.get('state') or 
                             address.get('province') or 
                             address.get('region') or
                             address.get('state_district') or
                             '')
                    
                    if city and country:
                        # Normalize to ensure English names
                        city = normalize_location_name(city.strip(), 'city')
                        country = normalize_location_name(country.strip(), 'country')
                        if region:
                            region = normalize_location_name(region.strip(), 'state')
                        
                        return jsonify({
                            'success': True,
                            'city': city,
                            'country': country,
                            'region': region if region else None
                        })
                    else:
                        return jsonify({'success': False, 'error': 'Could not determine city and country from coordinates'}), 400
                else:
                    return jsonify({'success': False, 'error': 'No address data found'}), 400
                    
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as e:
            print(f"Reverse geocoding error: {e}")
            return jsonify({'success': False, 'error': 'Geocoding service unavailable'}), 500
            
    except Exception as e:
        print(f"Error in geocode endpoint: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/city-suggestions', methods=['GET'])
def api_city_suggestions():
    """Proxy Nominatim city search requests to avoid CORS issues on old browsers"""
    try:
        query = request.args.get('q', '').strip()
        lang = request.args.get('lang', 'en')
        
        if not query or len(query) < 2:
            return jsonify([]), 200
        
        import urllib.request
        import json
        import urllib.parse
        
        query_lower = query.lower().strip()
        query_words = query_lower.split()
        
        # Try Geonames API first (better for city resolution, free tier available)
        # Geonames has excellent city database - use it to find cities, then Nominatim to resolve state
        try:
            # Geonames search API - using demo account (limited requests)
            # For production, register at geonames.org for free account (1000 requests/hour)
            # Use 'q' parameter for better partial matching (fuzzy search) instead of name_startsWith
            geonames_url = f"http://api.geonames.org/searchJSON?q={urllib.parse.quote(query)}&maxRows=20&lang={lang}&style=FULL&username=demo&featureClass=P&orderby=relevance"
            
            geonames_req = urllib.request.Request(geonames_url, headers={
                'User-Agent': 'CineStream/1.0'
            })
            with urllib.request.urlopen(geonames_req, timeout=8) as geonames_response:
                geonames_data = json.loads(geonames_response.read().decode())
                
                filtered_data = []
                for item in geonames_data.get('geonames', []):
                    # Geonames feature codes for populated places
                    fcode = item.get('fcode', '')
                    if fcode not in ['PPL', 'PPLA', 'PPLA2', 'PPLA3', 'PPLA4', 'PPLC', 'PPLG', 'PPLS']:
                        continue
                    
                    city_name = item.get('name', '')
                    country_code = item.get('countryCode', '')
                    admin_name1 = item.get('adminName1', '')  # State/province from Geonames
                    country_name = item.get('countryName', '')
                    lat = item.get('lat', '')
                    lon = item.get('lng', '')
                    
                    # Flexible matching - Geonames already does fuzzy matching, so we just need to verify relevance
                    city_lower = city_name.lower()
                    matches = False
                    
                    # Direct prefix match (best) - "ankar" matches "ankara"
                    if city_lower.startswith(query_lower):
                        matches = True
                    # Contains match for single word queries - "ankar" in "ankara"
                    elif len(query_words) == 1 and query_lower in city_lower:
                        matches = True
                    # Word-by-word prefix match for multi-word queries
                    elif len(query_words) > 1:
                        city_words = city_lower.split()
                        if len(city_words) >= len(query_words):
                            all_match = True
                            for i in range(len(query_words)):
                                if i >= len(city_words) or not city_words[i].startswith(query_words[i]):
                                    all_match = False
                                    break
                            if all_match:
                                matches = True
                    # Last resort: check if query is a substring (for cases like "ankar" -> "ankara")
                    elif query_lower in city_lower and len(query_lower) >= 4:  # Only for queries 4+ chars to avoid false positives
                        matches = True
                    
                    if matches:
                        # Use Nominatim to resolve and normalize state name
                        state = admin_name1
                        if state and lat and lon:
                            try:
                                # Use Nominatim reverse geocoding to get normalized state name
                                nominatim_reverse_url = f"https://nominatim.openstreetmap.org/reverse?format=json&lat={lat}&lon={lon}&addressdetails=1&accept-language=en"
                                reverse_req = urllib.request.Request(nominatim_reverse_url, headers={
                                    'User-Agent': 'CineStream/1.0'
                                })
                                with urllib.request.urlopen(reverse_req, timeout=5) as reverse_response:
                                    reverse_data = json.loads(reverse_response.read().decode())
                                    if reverse_data and 'address' in reverse_data:
                                        address = reverse_data.get('address', {})
                                        # Get normalized state name from Nominatim
                                        state = (address.get('state') or 
                                                address.get('province') or 
                                                address.get('region') or 
                                                address.get('state_district') or 
                                                state)
                            except Exception as e:
                                print(f"Error resolving state from Nominatim for {city_name}: {e}")
                        
                        converted_item = {
                            'display_name': city_name,
                            'lat': str(lat),
                            'lon': str(lon),
                            'type': 'city' if fcode in ['PPLC', 'PPLA'] else 'town',
                            'class': 'place',
                            'address': {
                                'city': city_name,
                                'state': state,
                                'province': state,
                                'region': state,
                                'country': country_name
                            }
                        }
                        filtered_data.append(converted_item)
                
                if filtered_data:
                    return jsonify(filtered_data[:10]), 200
        except Exception as e:
            print(f"Geonames API error: {e}, trying Photon")
        
        # Try Photon API as second option (better for autocomplete)
        try:
            photon_url = f"https://photon.komoot.io/api/?q={urllib.parse.quote(query)}&limit=15&lang={lang}"
            req = urllib.request.Request(photon_url, headers={
                'User-Agent': 'CineStream/1.0'
            })
            with urllib.request.urlopen(req, timeout=8) as response:
                photon_data = json.loads(response.read().decode())
                
                # Convert Photon format to Nominatim-like format for frontend compatibility
                filtered_data = []
                for item in photon_data.get('features', []):
                    props = item.get('properties', {})
                    geometry = item.get('geometry', {})
                    
                    # Extract city name from Photon response
                    city_name = props.get('name', '')
                    place_type = props.get('type', '')
                    
                    # Only include cities, towns, villages
                    if place_type not in ['city', 'town', 'village', 'municipality']:
                        continue
                    
                    # Strict matching - must actually match the query
                    city_lower = city_name.lower()
                    matches = False
                    
                    # Direct prefix match (best)
                    if city_lower.startswith(query_lower):
                        matches = True
                    # Word-by-word prefix match (e.g., "los angel" matches "los angeles")
                    elif len(query_words) > 1:
                        city_words = city_lower.split()
                        if len(city_words) >= len(query_words):
                            all_match = True
                            for i in range(len(query_words)):
                                if i >= len(city_words) or not city_words[i].startswith(query_words[i]):
                                    all_match = False
                                    break
                            if all_match:
                                matches = True
                    # Contains match (only if single word query) - "ankar" in "ankara"
                    elif len(query_words) == 1 and query_lower in city_lower:
                        matches = True
                    # Last resort: check if query is a substring (for cases like "ankar" -> "ankara")
                    elif query_lower in city_lower and len(query_lower) >= 4:  # Only for queries 4+ chars to avoid false positives
                        matches = True
                    
                    if matches:
                        # Convert to Nominatim-like format
                        coords = geometry.get('coordinates', [])
                        country = props.get('country', '')
                        
                        # Get state/region from Photon if available
                        state = props.get('state', '') or props.get('region', '')
                        
                        # If state not in Photon response, use Nominatim reverse geocoding to get it
                        if not state and len(coords) >= 2:
                            try:
                                lat = coords[1]
                                lon = coords[0]
                                nominatim_reverse_url = f"https://nominatim.openstreetmap.org/reverse?format=json&lat={lat}&lon={lon}&addressdetails=1&accept-language=en"
                                reverse_req = urllib.request.Request(nominatim_reverse_url, headers={
                                    'User-Agent': 'CineStream/1.0'
                                })
                                with urllib.request.urlopen(reverse_req, timeout=5) as reverse_response:
                                    reverse_data = json.loads(reverse_response.read().decode())
                                    if reverse_data and 'address' in reverse_data:
                                        address = reverse_data.get('address', {})
                                        state = (address.get('state') or 
                                                address.get('province') or 
                                                address.get('region') or 
                                                address.get('state_district') or '')
                            except Exception as e:
                                print(f"Error getting state from Nominatim reverse geocoding: {e}")
                        
                        converted_item = {
                            'display_name': city_name,
                            'lat': str(coords[1]) if len(coords) > 1 else '',
                            'lon': str(coords[0]) if len(coords) > 0 else '',
                            'type': place_type,
                            'class': 'place',
                            'address': {
                                'city': city_name if place_type == 'city' else None,
                                'town': city_name if place_type == 'town' else None,
                                'village': city_name if place_type == 'village' else None,
                                'municipality': city_name if place_type == 'municipality' else None,
                                'state': state,
                                'province': state,
                                'region': state,
                                'country': country
                            }
                        }
                        filtered_data.append(converted_item)
                
                if filtered_data:
                    return jsonify(filtered_data[:10]), 200
        except Exception as e:
            print(f"Photon API error: {e}, falling back to Nominatim")
        
        # Fallback to Nominatim if Photon fails or returns no results
        # Use dedupe=1 to remove duplicates and increase limit for better matching
        url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(query)}&format=json&limit=30&addressdetails=1&extratags=1&accept-language={lang}&dedupe=1"
        
        try:
            req = urllib.request.Request(url, headers={
                'User-Agent': 'CineStream/1.0'  # Required by Nominatim
            })
            with urllib.request.urlopen(req, timeout=10) as response:
                data = json.loads(response.read().decode())
                
                # Filter results on backend to ensure they actually match the query
                # This prevents irrelevant results like "Accra" for "los angel"
                query_lower = query.lower().strip()
                filtered_data = []
                
                for item in data:
                    # Extract city name
                    address = item.get('address', {})
                    city_name = (address.get('city') or 
                                address.get('town') or 
                                address.get('village') or 
                                address.get('municipality') or '')
                    
                    # Also check display_name
                    display_name = item.get('display_name', '').lower()
                    
                    # Check if query matches city name or display name
                    city_lower = city_name.lower()
                    matches = False
                    
                    # Direct prefix match (best) - query starts the city name
                    if city_lower.startswith(query_lower) or display_name.startswith(query_lower):
                        matches = True
                    # Word-by-word prefix match (e.g., "los angel" matches "los angeles")
                    # This is more important than contains match for multi-word queries
                    query_words = query_lower.split()
                    if len(query_words) > 1:
                        city_words = city_lower.split()
                        display_words = display_name.split()
                        # Check city words
                        if len(city_words) >= len(query_words):
                            all_match = True
                            for i in range(len(query_words)):
                                if i >= len(city_words) or not city_words[i].startswith(query_words[i]):
                                    all_match = False
                                    break
                            if all_match:
                                matches = True
                        # Check display words if city didn't match
                        if not matches and len(display_words) >= len(query_words):
                            all_match = True
                            for i in range(len(query_words)):
                                if i >= len(display_words) or not display_words[i].startswith(query_words[i]):
                                    all_match = False
                                    break
                            if all_match:
                                matches = True
                    # Contains match - only for single word queries to avoid false positives like "Accra" for "los angel"
                    elif len(query_words) == 1 and (query_lower in city_lower or query_lower in display_name):
                        matches = True
                    # Last resort: check if query is a substring (for cases like "ankar" -> "ankara")
                    elif (query_lower in city_lower or query_lower in display_name) and len(query_lower) >= 4:  # Only for queries 4+ chars
                        matches = True
                    
                    # Only include if it matches
                    if matches:
                        filtered_data.append(item)
                        # Limit to 20 best matches
                        if len(filtered_data) >= 20:
                            break
                
                # If we have good matches, return them
                if len(filtered_data) > 0:
                    return jsonify(filtered_data), 200
                
                # If no good matches from Nominatim, try Geonames as fallback
                # Geonames is often more accurate for city searches
                try:
                    geonames_url = f"http://api.geonames.org/searchJSON?name={urllib.parse.quote(query)}&maxRows=20&featureClass=P&style=full&username=demo"
                    geonames_req = urllib.request.Request(geonames_url, headers={
                        'User-Agent': 'CineStream/1.0'
                    })
                    with urllib.request.urlopen(geonames_req, timeout=5) as geonames_response:
                        geonames_data = json.loads(geonames_response.read().decode())
                        geonames_results = geonames_data.get('geonames', [])
                        
                        # Convert Geonames format to Nominatim-like format for frontend compatibility
                        converted_results = []
                        query_lower = query.lower().strip()
                        for geo_item in geonames_results:
                            city_name = geo_item.get('name', '')
                            country = geo_item.get('countryName', '')
                            admin1 = geo_item.get('adminName1', '')  # State/province
                            
                            # Filter to ensure it matches
                            city_lower = city_name.lower()
                            if (city_lower.startswith(query_lower) or 
                                query_lower in city_lower or
                                (len(query_lower.split()) > 0 and city_lower.startswith(query_lower.split()[0]))):
                                # Convert to Nominatim-like format
                                converted_item = {
                                    'display_name': f"{city_name}, {admin1}, {country}" if admin1 else f"{city_name}, {country}",
                                    'address': {
                                        'city': city_name,
                                        'country': country,
                                        'state': admin1 if admin1 else None
                                    },
                                    'type': 'city',
                                    'class': 'place'
                                }
                                converted_results.append(converted_item)
                                if len(converted_results) >= 10:
                                    break
                        
                        if len(converted_results) > 0:
                            return jsonify(converted_results), 200
                
                except Exception as geonames_error:
                    print(f"Geonames fallback error: {geonames_error}")
                    # Continue to return empty if both fail
                
                # Return empty if no matches found
                return jsonify([]), 200
                
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as e:
            print(f"City suggestions error: {e}")
            return jsonify([]), 200  # Return empty array on error
            
    except Exception as e:
        print(f"Error in city suggestions endpoint: {e}")
        return jsonify([]), 200  # Return empty array on error

@app.route('/api/geocode-ip', methods=['GET'])
def api_geocode_ip():
    """Fallback: Get location from IP address (when browser geolocation fails)"""
    try:
        geo_data = detect_city_from_ip()
        if geo_data:
            # Normalize to English
            city = normalize_location_name(geo_data.get('city', ''), 'city')
            country = normalize_location_name(geo_data.get('country', ''), 'country')
            region = geo_data.get('region', '')
            if region:
                region = normalize_location_name(region, 'state')
            
            return jsonify({
                'success': True,
                'city': city,
                'country': country,
                'region': region if region else None
            })
        else:
            return jsonify({'success': False, 'error': 'Could not determine location from IP'}), 400
    except Exception as e:
        print(f"Error in IP geocode endpoint: {e}")
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/showtimes')
def api_showtimes():
    """API endpoint for showtimes"""
    try:
        lang = get_language()
        city_name = request.args.get('city_id') or request.args.get('city_name')
        format_filter = request.args.get('format')
        language_filter = request.args.get('language')
        
        # Use the proper data structure (db.movies, not db.showtimes)
        if not city_name:
            return jsonify([])
        
        # Get showtimes from movies collection (proper data structure)
        showtimes = get_showtimes_for_city(city_name)
        
        # Apply filters (format and language)
        if format_filter:
            showtimes = [s for s in showtimes if s.get('format') and s.get('format') == format_filter]
        if language_filter:
            showtimes = [s for s in showtimes if language_filter.lower() in s.get('language', '').lower()]
        
        # Translate location names and addresses to selected language
        for st in showtimes:
            # Translate city/state/country (for location display - but we're removing that)
            if st.get('city') or st.get('country'):
                translated = translate_location_name(
                    st.get('city', ''),
                    st.get('state', ''),
                    st.get('country', ''),
                    lang
                )
                if translated.get('city'):
                    st['city_translated'] = translated['city']
                if translated.get('state'):
                    st['state_translated'] = translated['state']
                if translated.get('country'):
                    st['country_translated'] = translated['country']
            
            # Translate cinema address
            if st.get('cinema_address'):
                st['cinema_address_translated'] = translate_address(st.get('cinema_address', ''), lang)
        
        # Note: get_showtimes_for_city already filters past showtimes and sorts by start_time
        # No need to sort again - it's already sorted
        
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
        
        # Check if there's an active lock (scraping in progress)
        from core.lock import get_lock_info
        lock_info = get_lock_info(db, city_name)
        is_processing = lock_info is not None or (status == 'processing')
        
        # Get error message if status is error
        error_message = None
        if status == 'error':
            error_message = city.get('error_message', 'An error occurred while fetching showtimes. Please check your API key configuration.')
        
        return jsonify({
            'status': status,
            'last_updated': last_updated_iso,
            'lock_source': lock_source,
            'ready': status == 'fresh',
            'processing': is_processing,
            'processing_by': lock_source if status == 'processing' or is_processing else None,
            'message': error_message
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
    
    # Reject potentially dangerous characters (security check - lightweight)
    dangerous_chars = ['<', '>', '{', '}', '[', ']', '$', '\\', '/']
    if any(char in city or char in country or (state and char in state) for char in dangerous_chars):
        return jsonify({'error': 'Invalid characters in input'}), 400
    
    # Basic sanity checks (lightweight, no API calls)
    if len(city) < 2:
        return jsonify({'error': 'City name is too short'}), 400
    if len(country) < 2:
        return jsonify({'error': 'Country name is too short'}), 400
    if state and len(state) < 2:
        return jsonify({'error': 'State/Province name is too short'}), 400
    
    # Verify location exists before scraping (backend validation)
    # This prevents scraping non-existent places even if frontend validation is bypassed
    location_valid = verify_location_exists(city, country, state)
    if not location_valid:
        return jsonify({'error': 'Location not found. Please verify the city, state, and country names are correct.'}), 400
    
    # Optimize: Normalize all location names in a single API call when possible
    # This reduces Nominatim API calls from 3 to 1 when we have city, state, and country
    if state:
        # Try to normalize all three in one call
        normalized = normalize_location_names_together(city, state, country)
        if normalized:
            city, state, country = normalized
        else:
            # Fallback to individual normalization if combined fails
            city = normalize_location_name(city, 'city')
            country = normalize_location_name(country, 'country')
            state = normalize_location_name(state, 'state')
    else:
        # Only city and country - can still optimize
        normalized = normalize_location_names_together(city, None, country)
        if normalized:
            city, _, country = normalized
        else:
            # Fallback to individual normalization
            city = normalize_location_name(city, 'city')
            country = normalize_location_name(country, 'country')
    
    # Build location identifier (city, state, country format) - using normalized names
    if state:
        location_id = f"{city}, {state}, {country}"
    else:
        location_id = f"{city}, {country}"
    
    # Check if we have complete data (all 14 days) - if so, just return it without scraping
    from datetime import timedelta, timezone
    now_utc = datetime.now(timezone.utc)
    today = now_utc.date()
    two_weeks_from_today = today + timedelta(days=14)
    
    # Check if we have data for all dates
    movies = list(db.movies.find({'city_id': location_id}))
    if movies:
        # Collect all unique dates that have showtimes
        dates_with_data = set()
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
                        # Get the date (ignore time)
                        date_with_data = start_time_utc.date()
                        dates_with_data.add(date_with_data)
        
        # Check if we have data for all dates from today to 2 weeks ahead
        all_dates_present = True
        current_date = today
        while current_date <= two_weeks_from_today:
            if current_date not in dates_with_data:
                all_dates_present = False
                break
            current_date += timedelta(days=1)
        
        if all_dates_present:
            # We have complete data (all 14 days) - just return it without scraping
            showtimes = get_showtimes_for_city(location_id)
            return jsonify({
                'status': 'fresh', 
                'message': 'Data is up to date (2 weeks coverage)',
                'showtimes': showtimes
            })
    
    # Check if location exists and is fresh (within last 24 hours) - also return without scraping
    location = db.locations.find_one({'city_name': location_id})
    if location and location.get('status') == 'fresh':
        last_updated = location.get('last_updated')
        if last_updated and isinstance(last_updated, datetime):
            # Handle both timezone-aware and naive datetimes
            if last_updated.tzinfo is None:
                # Naive datetime - assume UTC and convert
                last_updated_utc = last_updated.replace(tzinfo=timezone.utc)
            else:
                # Timezone-aware - convert to UTC
                last_updated_utc = last_updated.astimezone(timezone.utc)
            
            hours_old = (now_utc - last_updated_utc).total_seconds() / 3600
            if hours_old < 24:
                # Return existing showtimes immediately
                showtimes = get_showtimes_for_city(location_id)
                return jsonify({
                    'status': 'fresh', 
                    'message': 'Data already available',
                    'showtimes': showtimes
                })
    
    # Try to acquire lock with priority (on-demand requests take precedence)
    # On-demand can override daily-refresh locks immediately
    if not acquire_lock(db, location_id, lock_source='on-demand', priority=True):
        # Check what's holding the lock
        lock_info = get_lock_info(db, location_id)
        if lock_info:
            source = lock_info.get('source', 'unknown')
            if source == 'on-demand':
                # Another on-demand request is already processing
                message = 'Another on-demand scraping request is already in progress. Please wait for it to complete.'
            elif source == 'daily-refresh':
                # This shouldn't happen if override worked, but handle it anyway
                message = 'Daily refresh is currently running. Your request should override it - please try again in a moment.'
            else:
                message = 'Scraping already in progress'
        else:
            # Lock was released between check and acquire (race condition)
            message = 'Scraping status changed. Please try again.'
        return jsonify({'status': 'processing', 'message': message}), 202
    
    try:
        # Determine date range to scrape (incremental scraping - only missing days)
        date_start, date_end = get_date_range_to_scrape(location_id)
        
        # Check if there's actually a date range to scrape (if all dates are present, range will be very small)
        time_diff = (date_end - date_start).total_seconds()
        if time_diff < 3600:  # Less than 1 hour means no real date range to scrape
            # All dates are already present - just return existing data
            showtimes = get_showtimes_for_city(location_id)
            return jsonify({
                'status': 'fresh',
                'message': 'Data is up to date (all dates covered)',
                'showtimes': showtimes
            })
        
        # Spawn AI agent to scrape only the missing date range
        agent = ClaudeAgent()
        result = agent.scrape_city_showtimes(city, country, state, date_start, date_end)
        
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
                        # For existing movies, merge theaters and showtimes
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
                                from datetime import timezone
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
                        print(f"Updated {upserted_count} existing movies, inserted {inserted_count} new movies")
                    
                    # Clean up expired showtimes (older than 24 hours past their start_time)
                    from datetime import timedelta, timezone
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
                    print(f"Error updating movies: {insert_error}")
                    import traceback
                    traceback.print_exc()
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
            
    except ValueError as e:
        # Handle specific errors like missing API key
        error_message = str(e)
        if 'ANTHROPIC_API_KEY' in error_message:
            error_message = 'Anthropic API key is not configured. Please set ANTHROPIC_API_KEY environment variable.'
        
        # Safety check: location_id should always be defined here, but check just in case
        if 'location_id' in locals():
            # Mark location as error status
            db.locations.update_one(
                {'city_name': location_id},
                {
                    '$set': {
                        'status': 'error',
                        'error_message': error_message,
                        'last_updated': datetime.now(timezone.utc)
                    }
                },
                upsert=True
            )
            release_lock(db, location_id)
        
        import traceback
        print(f"Scraping error: {traceback.format_exc()}")
        return jsonify({'status': 'error', 'message': error_message}), 500
    except Exception as e:
        # Safety check: location_id should always be defined here, but check just in case
        if 'location_id' in locals():
            # Mark location as error status
            error_message = str(e)
            db.locations.update_one(
                {'city_name': location_id},
                {
                    '$set': {
                        'status': 'error',
                        'error_message': error_message,
                        'last_updated': datetime.now(timezone.utc)
                    }
                },
                upsert=True
            )
            release_lock(db, location_id)
        import traceback
        print(f"Scraping error: {traceback.format_exc()}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

def get_date_range_to_scrape(city_id):
    """
    Determine what date range needs to be scraped (incremental - only missing days).
    Only scrapes missing days up to 2 weeks total from today.
    Returns (start_date, end_date) - only the missing date range.
    
    Example: If we have 5 days of data, only scrape days 6-14 (to complete 2 weeks).
    """
    from datetime import timedelta, timezone
    
    now = datetime.now(timezone.utc)
    today = now.date()
    two_weeks_from_today = today + timedelta(days=14)
    
    # Find all movies for this city
    movies = list(db.movies.find({'city_id': city_id}))
    
    if not movies:
        # No data yet, scrape full 2 weeks range
        return now, datetime.combine(two_weeks_from_today, datetime.max.time()).replace(tzinfo=timezone.utc)
    
    # Collect all unique dates that have showtimes
    dates_with_data = set()
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
                    # Get the date (ignore time)
                    date_with_data = start_time_utc.date()
                    dates_with_data.add(date_with_data)
    
    if not dates_with_data:
        # No valid showtimes found, scrape full range
        return now, datetime.combine(two_weeks_from_today, datetime.max.time()).replace(tzinfo=timezone.utc)
    
    # Find missing dates between today and 2 weeks from today
    missing_dates = []
    current_date = today
    while current_date <= two_weeks_from_today:
        if current_date not in dates_with_data:
            missing_dates.append(current_date)
        current_date += timedelta(days=1)
    
    if not missing_dates:
        # We already have all 14 days, no scraping needed
        # Return a very small range (just today) to indicate no new data needed
        # But the caller should handle this case
        return now, now + timedelta(hours=1)
    
    # Scrape only the missing date range
    scrape_start_date = min(missing_dates)
    scrape_end_date = max(missing_dates)
    
    # Convert to datetime (start of first missing day, end of last missing day)
    scrape_start = datetime.combine(scrape_start_date, datetime.min.time()).replace(tzinfo=timezone.utc)
    scrape_end = datetime.combine(scrape_end_date, datetime.max.time()).replace(tzinfo=timezone.utc)
    
    return scrape_start, scrape_end

def get_showtimes_for_city(city_name):
    """Helper to get formatted showtimes for a city (flattened from movies structure)"""
    try:
        # Get all movies for this city
        movies = list(db.movies.find({'city_id': city_name}))
        
        # Flatten movies structure to showtimes format for backward compatibility
        from datetime import timezone
        now = datetime.now(timezone.utc)
        
        showtimes = []
        for movie in movies:
            movie_title = movie.get('movie', {})
            movie_description = movie.get('movie_description', {})
            movie_image_url = movie.get('movie_image_url')
            movie_image_path = movie.get('movie_image_path')
            
            theaters = movie.get('theaters', [])
            for theater in theaters:
                theater_name = theater.get('name', 'Unknown')
                theater_address = theater.get('address', '')
                theater_website = theater.get('website', '')
                
                theater_showtimes = theater.get('showtimes', [])
                for st in theater_showtimes:
                    start_time = st.get('start_time')
                    if isinstance(start_time, datetime):
                        # Preserve original timezone - don't convert to UTC
                        # Only convert to UTC for comparison purposes
                        if start_time.tzinfo is None:
                            # Naive datetime - assume UTC (shouldn't happen, but handle gracefully)
                            start_time = start_time.replace(tzinfo=timezone.utc)
                        
                        # Convert to UTC only for comparison
                        start_time_utc = start_time.astimezone(timezone.utc)
                        
                        # Only include future showtimes (compare in UTC)
                        if start_time_utc >= now:
                            # Store original timezone-aware datetime (preserves local timezone)
                            showtimes.append({
                                'city': movie.get('city', ''),
                                'state': movie.get('state', ''),
                                'country': movie.get('country', ''),
                                'city_id': movie.get('city_id', ''),
                                'cinema_id': theater_name,
                                'cinema_name': theater_name,
                                'cinema_address': theater_address,
                                'cinema_website': theater_website,
                                'movie': movie_title,
                                'movie_description': movie_description,
                                'movie_image_url': movie_image_url,
                                'movie_image_path': movie_image_path,
                                'start_time': start_time,  # Original timezone preserved
                                'format': st.get('format'),
                                'language': st.get('language', ''),
                                'hall': st.get('hall', ''),
                                'created_at': movie.get('created_at')
                            })
                    else:
                        # Try to parse string datetime
                        try:
                            if isinstance(start_time, str):
                                start_time = datetime.fromisoformat(start_time.replace('Z', '+00:00'))
                            
                            # Preserve timezone if present
                            if start_time.tzinfo is None:
                                start_time = start_time.replace(tzinfo=timezone.utc)
                            
                            # Convert to UTC for comparison
                            start_time_utc = start_time.astimezone(timezone.utc)
                            
                            # Only include future showtimes (compare in UTC)
                            if start_time_utc >= now:
                                # Store original timezone-aware datetime
                                showtimes.append({
                                    'city': movie.get('city', ''),
                                    'state': movie.get('state', ''),
                                    'country': movie.get('country', ''),
                                    'city_id': movie.get('city_id', ''),
                                    'cinema_id': theater_name,
                                    'cinema_name': theater_name,
                                    'cinema_address': theater_address,
                                    'cinema_website': theater_website,
                                    'movie': movie_title,
                                    'movie_description': movie_description,
                                    'movie_image_url': movie_image_url,
                                    'movie_image_path': movie_image_path,
                                    'start_time': start_time,  # Original timezone preserved
                                    'format': st.get('format'),
                                    'language': st.get('language', ''),
                                    'hall': st.get('hall', ''),
                                    'created_at': movie.get('created_at')
                                })
                        except (ValueError, AttributeError):
                            continue
        
        # Sort showtimes by start_time (ascending - earliest first)
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
    except Exception as e:
        print(f"Error getting showtimes for city: {e}")
        import traceback
        traceback.print_exc()
        return []

@app.route('/set-language/<lang>')
def set_lang(lang):
    """Set language endpoint"""
    # Validate language to prevent injection
    if lang in ['en', 'ua', 'ru']:
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

@app.errorhandler(404)
def page_not_found(e):
    """Handle 404 errors"""
    lang = get_language()
    if lang not in TRANSLATIONS:
        lang = 'en'
    t = TRANSLATIONS[lang]
    
    return render_template('404.html', translations=t, lang=lang), 404

@app.route('/terms')
def terms():
    """Terms of Service page"""
    lang = get_language()
    if lang not in TRANSLATIONS:
        lang = 'en'
    t = TRANSLATIONS[lang]
    
    return render_template('terms.html', translations=t, lang=lang, datetime=datetime)

@app.route('/api/feedback', methods=['POST'])
def api_feedback():
    """Handle feedback form submission"""
    try:
        data = request.get_json() or {}
        name = data.get('name', '').strip()
        email = data.get('email', '').strip()
        message = data.get('message', '').strip()
        
        # Validation
        if not message:
            return jsonify({'success': False, 'error': 'Message is required'}), 400
        
        if len(message) > 5000:
            return jsonify({'success': False, 'error': 'Message is too long (max 5000 characters)'}), 400
        
        # Email configuration
        recipient_email = 'oleksandr.don.256@gmail.com'
        # Sanitize name to prevent email header injection
        safe_name = (name or 'Anonymous').replace('\n', ' ').replace('\r', '').strip()[:100]
        subject = f'CineStream Feedback from {safe_name}'
        
        # Create email body (sanitize inputs to prevent injection)
        from datetime import timezone
        safe_email = (email or 'Not provided').replace('\n', ' ').replace('\r', '').strip()[:200]
        safe_message = message.replace('\r\n', '\n').replace('\r', '\n')[:5000]  # Normalize line endings
        email_body = f"""Feedback from CineStream Website

Name: {safe_name}
Email: {safe_email}
Date: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}

Message:
{safe_message}
"""
        
        # Try to send email using SMTP (if configured) or just log it
        try:
            # Check if SMTP is configured in environment
            smtp_host = os.getenv('SMTP_HOST')
            smtp_port = int(os.getenv('SMTP_PORT', '587'))
            smtp_user = os.getenv('SMTP_USER')
            smtp_password = os.getenv('SMTP_PASSWORD')
            
            if smtp_host and smtp_user and smtp_password:
                # Send email via SMTP
                msg = MIMEMultipart()
                msg['From'] = smtp_user
                msg['To'] = recipient_email
                msg['Subject'] = subject
                msg.attach(MIMEText(email_body, 'plain'))
                
                print(f"Attempting to send feedback email via SMTP...")
                print(f"  SMTP Host: {smtp_host}:{smtp_port}")
                print(f"  From: {smtp_user}")
                print(f"  To: {recipient_email}")
                
                server = smtplib.SMTP(smtp_host, smtp_port)
                server.starttls()
                server.login(smtp_user, smtp_password)
                server.send_message(msg)
                server.quit()
                
                print(f"✓ Feedback email sent successfully to {recipient_email}")
            else:
                # If SMTP not configured, log it with clear instructions
                missing_vars = []
                if not smtp_host:
                    missing_vars.append('SMTP_HOST')
                if not smtp_user:
                    missing_vars.append('SMTP_USER')
                if not smtp_password:
                    missing_vars.append('SMTP_PASSWORD')
                
                print(f"\n{'='*60}")
                print("⚠ FEEDBACK RECEIVED (SMTP not configured)")
                print(f"{'='*60}")
                print(f"Missing environment variables: {', '.join(missing_vars)}")
                print(f"To enable email delivery, set these in your .env file:")
                print(f"  SMTP_HOST=smtp.gmail.com  # or your SMTP server")
                print(f"  SMTP_PORT=587")
                print(f"  SMTP_USER=your-email@gmail.com")
                print(f"  SMTP_PASSWORD=your-app-password")
                print(f"{'='*60}")
                print("FEEDBACK CONTENT:")
                print(f"{'='*60}")
                print(email_body)
                print(f"{'='*60}\n")
        except Exception as e:
            # Log error with full details
            print(f"\n{'='*60}")
            print("✗ ERROR SENDING FEEDBACK EMAIL")
            print(f"{'='*60}")
            print(f"Error type: {type(e).__name__}")
            print(f"Error message: {str(e)}")
            print(f"\nSMTP Configuration:")
            print(f"  SMTP_HOST: {os.getenv('SMTP_HOST', 'NOT SET')}")
            print(f"  SMTP_PORT: {os.getenv('SMTP_PORT', 'NOT SET')}")
            print(f"  SMTP_USER: {os.getenv('SMTP_USER', 'NOT SET')}")
            print(f"  SMTP_PASSWORD: {'SET' if os.getenv('SMTP_PASSWORD') else 'NOT SET'}")
            print(f"\n{'='*60}")
            print("FEEDBACK CONTENT (Email sending failed, logging instead):")
            print(f"{'='*60}")
            print(email_body)
            print(f"{'='*60}\n")
            
            # Also log full traceback for debugging
            import traceback
            print("Full traceback:")
            traceback.print_exc()
        
        return jsonify({'success': True, 'message': 'Feedback sent successfully'})
    
    except Exception as e:
        print(f"Error processing feedback: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'success': False, 'error': 'Internal server error'}), 500

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

