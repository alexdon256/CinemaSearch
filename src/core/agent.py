"""
Gemini AI Agent for Web Scraping
Step-by-step scraping: Find theaters, then scrape each theater day by day
"""

import os
import json
import re
import time
from typing import Dict, List, Optional, Tuple
from datetime import datetime, timedelta, timezone, time as dt_time, date
import google.generativeai as genai

# Available models (cheapest first)
MODELS = {
    'flash': 'gemini-2.0-flash-exp',  # Cheapest experimental model
    'flash-stable': 'gemini-1.5-flash',  # Stable Flash model
    'pro': 'gemini-1.5-pro'  # More capable if needed
}

# Default to Flash for cost efficiency
DEFAULT_MODEL = 'flash'

class GeminiAgent:
    """AI Agent wrapper for Gemini API with step-by-step scraping"""
    
    def __init__(self, model_key: str = None):
        api_key = os.getenv('GOOGLE_API_KEY') or os.getenv('GEMINI_API_KEY')
        if not api_key:
            raise ValueError("GOOGLE_API_KEY or GEMINI_API_KEY environment variable is required")
        
        genai.configure(api_key=api_key)
        
        # Allow model override via env var or parameter
        model_key = model_key or os.getenv('GEMINI_MODEL', DEFAULT_MODEL)
        self.model_name = MODELS.get(model_key, MODELS[DEFAULT_MODEL])
        self.model = genai.GenerativeModel(self.model_name)
    
    @staticmethod
    def _normalize_theater_key(name: str, address: str) -> Tuple[str, str]:
        """Normalize theater name and address for consistent matching"""
        if not name:
            name = ''
        if not address:
            address = ''
        # Normalize: lowercase, strip, remove extra spaces
        normalized_name = ' '.join(name.lower().strip().split())
        normalized_address = ' '.join(address.lower().strip().split())
        return (normalized_name, normalized_address)
    
    @staticmethod
    def _get_movie_title_key(movie_title) -> str:
        """Extract and normalize movie title key for consistent matching"""
        if isinstance(movie_title, dict):
            title_key = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or ''
        else:
            title_key = str(movie_title) if movie_title else ''
        return title_key.lower().strip() if title_key else ''
    
    def _should_skip_movie_day(self, title_key: str, current_date: date, existing_data: Dict, 
                               theaters: List[Dict]) -> Tuple[bool, Optional[date]]:
        """
        Determine if we should skip scraping this movie/day.
        
        Args:
            title_key: Normalized movie title key
            current_date: Date to check (date object, not datetime)
            existing_data: Dict mapping title_key -> {(theater_name, theater_address): latest_date}
            theaters: List of theater dicts to check
        
        Returns:
            (should_skip, earliest_needed_date): 
            - should_skip: True if we can skip the entire day
            - earliest_needed_date: The earliest date we need to scrape (None if skipping)
        """
        if not existing_data or title_key not in existing_data:
            # No existing data for this movie - need to scrape
            return False, None
        
        theater_dates = existing_data[title_key]
        if not theater_dates:
            # Empty theater data - need to scrape
            return False, None
        
        # Find the earliest date we need to scrape across all theaters
        # This allows us to skip entire date ranges
        earliest_needed_date = None
        theaters_need_data = False
        
        for theater in theaters:
            theater_name = theater.get('name', '')
            theater_address = theater.get('address', '')
            theater_key = self._normalize_theater_key(theater_name, theater_address)
            
            # Check if this theater has data
            latest_existing_date = None
            # Try exact match first
            if theater_key in theater_dates:
                latest_existing_date = theater_dates[theater_key]
            else:
                # Try fuzzy matching (in case of slight variations)
                for existing_key, existing_date in theater_dates.items():
                    existing_name, existing_addr = existing_key
                    # Check if names are similar (allowing for minor variations)
                    if (existing_name in theater_key[0] or theater_key[0] in existing_name):
                        if not existing_addr or not theater_key[1] or existing_addr in theater_key[1] or theater_key[1] in existing_addr:
                            latest_existing_date = existing_date
                            break
            
            # If theater doesn't have data, or has data but before current_date, we need to scrape
            if latest_existing_date is None:
                theaters_need_data = True
                earliest_needed_date = current_date if earliest_needed_date is None else min(earliest_needed_date, current_date)
            elif latest_existing_date < current_date:
                theaters_need_data = True
                next_needed = latest_existing_date + timedelta(days=1)
                earliest_needed_date = next_needed if earliest_needed_date is None else min(earliest_needed_date, next_needed)
        
        # If no theaters need data, we can skip this day
        if not theaters_need_data:
            return True, None
        
        return False, earliest_needed_date
    
    def find_theaters(self, city: str, country: str, state: str = None) -> List[Dict]:
        """
        Step 1: Find theaters with websites for the location
        
        Returns:
            List of theater dicts with name, address, website
        """
        location = f"{city}, {state}, {country}" if state else f"{city}, {country}"
        
        prompt = f"""Find all cinema/theater websites in {location}. Return ONLY JSON array.

Search for cinema chains and independent theaters in {location}. For each theater found, extract:
- Theater name
- Full address (street, building number, city, state, country)
- Website URL (main website, not specific showtime pages)

Return JSON array:
[
    {{
        "name": "Theater Name",
        "address": "Full address",
        "website": "https://theater-website.com"
    }}
]

If no theaters found, return empty array: []
"""
        
        try:
            response_text = self._call_api_with_retry(prompt, max_output_tokens=4096)
            
            if not response_text:
                return []
            
            json_text = self._extract_json(response_text)
            theaters = json.loads(json_text)
            
            if not isinstance(theaters, list):
                return []
            
            # Validate and clean theaters
            valid_theaters = []
            for theater in theaters:
                if isinstance(theater, dict) and theater.get('name') and theater.get('website'):
                    valid_theaters.append({
                        'name': str(theater.get('name', '')).strip(),
                        'address': str(theater.get('address', '')).strip(),
                        'website': str(theater.get('website', '')).strip()
                    })
            
            return valid_theaters
            
        except Exception as e:
            print(f"Error finding theaters: {e}")
            return []
    
    def find_movies(self, theaters: List[Dict], city: str, country: str, state: str = None) -> List[Dict]:
        """
        Step 2: Find all movies currently playing in theaters
        
        Args:
            theaters: List of theater dicts
            city, country, state: Location info
            
        Returns:
            List of movie dicts with basic info (title, description, image)
        """
        location = f"{city}, {state}, {country}" if state else f"{city}, {country}"
        theater_names = [t['name'] for t in theaters]
        theater_list = ", ".join(theater_names[:10])  # Limit to first 10 for prompt
        
        prompt = f"""Find all movies currently playing in cinemas in {location}.

Theaters: {theater_list}
Location: {location}

Search cinema websites to find all movies currently showing. For each movie, extract:
- Movie title (in local language, English, Ukrainian, Russian if available)
- Movie description/synopsis (en/ua/ru)
- Movie poster/image URL

Return ONLY JSON array:
[
    {{
        "movie_title": {{"en": "...", "local": "...", "ua": "...", "ru": "..."}},
        "movie_description": {{"en": "...", "ua": "...", "ru": "..."}},
        "movie_image_url": "https://..."
    }}
]

If no movies found, return empty array: []
"""
        
        try:
            response_text = self._call_api_with_retry(prompt, max_output_tokens=8192)
            
            if not response_text:
                return []
            
            json_text = self._extract_json(response_text)
            movies = json.loads(json_text)
            
            if not isinstance(movies, list):
                return []
            
            # Validate and clean movies
            valid_movies = []
            for movie in movies:
                if isinstance(movie, dict) and movie.get('movie_title'):
                    valid_movies.append({
                        'movie_title': movie.get('movie_title', {}),
                        'movie_description': movie.get('movie_description', {}),
                        'movie_image_url': movie.get('movie_image_url', '')
                    })
            
            return valid_movies
            
        except Exception as e:
            print(f"Error finding movies: {e}")
            return []
    
    def scrape_movie_day(self, movie: Dict, theaters: List[Dict], target_date: datetime, 
                        city: str, country: str, state: str = None) -> Optional[Dict]:
        """
        Step 3: Scrape showtimes for a specific movie across all theaters for one day
        
        Args:
            movie: Dict with movie_title, movie_description, movie_image_url
            theaters: List of theater dicts
            target_date: Date to scrape (datetime object with timezone)
            city, country, state: Location info
            
        Returns:
            Dict with movie info and showtimes from all theaters for that day, or None on error
        """
        date_str = target_date.strftime('%Y-%m-%d')
        day_name = target_date.strftime('%A, %B %d, %Y')
        location = f"{city}, {state}, {country}" if state else f"{city}, {country}"
        
        # Get movie title for prompt
        movie_title = movie.get('movie_title', {})
        if isinstance(movie_title, dict):
            title_display = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or 'Unknown'
        else:
            title_display = str(movie_title) if movie_title else 'Unknown'
        
        theater_list = "\n".join([f"- {t['name']} ({t['website']})" for t in theaters[:20]])  # Limit to 20 theaters
        
        prompt = f"""Find showtimes for "{title_display}" on {day_name} ({date_str}) in {location}.

Movie: {title_display}
Date: {date_str}
Location: {location}

Theaters to check:
{theater_list}

Search each theater website for showtimes of this movie on {date_str}. Extract:
- For each theater showing this movie:
  * Theater name
  * Theater address
  * Theater website
  * Showtimes for {date_str}:
    - Start time (ISO 8601 format with timezone: YYYY-MM-DDTHH:MM:SS+TZ)
    - Format (2D/3D/IMAX/4DX if available)
    - Language/dubbing/subtitles
    - Hall/room number if available

Return ONLY JSON:
{{
    "date": "{date_str}",
    "movie_title": {json.dumps(movie_title)},
    "movie_description": {json.dumps(movie.get('movie_description', {}))},
    "movie_image_url": "{movie.get('movie_image_url', '')}",
    "theaters": [
        {{
            "name": "Theater Name",
            "address": "Full address",
            "website": "https://...",
            "showtimes": [
                {{"start_time": "2025-12-20T18:00:00+02:00", "format": "2D", "language": "...", "hall": "..."}}
            ]
        }}
    ]
}}

If movie is not showing on this date, return: {{"date": "{date_str}", "movie_title": {json.dumps(movie_title)}, "theaters": []}}
"""
        
        try:
            response_text = self._call_api_with_retry(prompt, max_output_tokens=8192)
            
            if not response_text:
                print(f"Error: Empty response from Gemini API for {title_display} on {date_str}")
                return None
            
            json_text = self._extract_json(response_text)
            result = json.loads(json_text)
            
            if not isinstance(result, dict):
                return None
            
            # Ensure movie info is included
            result['movie_title'] = movie.get('movie_title', {})
            result['movie_description'] = movie.get('movie_description', {})
            result['movie_image_url'] = movie.get('movie_image_url', '')
            
            return result
            
        except Exception as e:
            print(f"Error scraping {title_display} for {date_str}: {e}")
            return None
    
    def scrape_city_showtimes(self, city: str, country: str = None, state: str = None, 
                              date_range_start: datetime = None, date_range_end: datetime = None,
                              existing_data: Dict = None) -> Dict:
        """
        Main scraping method: Step-by-step approach
        1. Find theaters with websites for the location
        2. Find all movies currently playing in those theaters
        3. For each movie, scrape day by day across all theaters
           - Scrapes from date_range_start to max(date_range_end, 14 days from now)
           - One query per movie per day
           - Intelligently skips dates/theaters that already have data (from existing_data parameter)
           - Tracks latest showtime date to ensure 14-day coverage
        4. Merge all results by movie title
        
        Args:
            city: City name
            country: Country name (required)
            state: State/province name (optional)
            date_range_start: Start datetime (defaults to now, will be converted to UTC)
            date_range_end: End datetime (defaults to 14 days from now, will be converted to UTC)
            existing_data: Optional dict mapping movie_title_key -> {(theater_name, theater_address): latest_date}
                          Used to skip scraping dates/theaters that already have data.
                          Theater keys should be tuples (name, address) - will be normalized internally.
        
        Returns:
            Dictionary with 'success' (bool), 'movies' (list), and optional 'error' (str)
        """
        # Input validation
        if not city or not isinstance(city, str) or not city.strip():
            raise ValueError("City must be a non-empty string")
        if not country or not isinstance(country, str) or not country.strip():
            raise ValueError("Country is required")
        
        city = city.strip()[:100]
        country = country.strip()[:100]
        state = state.strip()[:100] if state and isinstance(state, str) else None
        
        # Normalize existing_data to use normalized keys
        normalized_existing_data = {}
        if existing_data:
            for title_key, theater_dates in existing_data.items():
                if not isinstance(title_key, str):
                    continue
                normalized_title_key = title_key.lower().strip()
                normalized_theater_dates = {}
                for theater_key, latest_date in theater_dates.items():
                    if isinstance(theater_key, tuple) and len(theater_key) == 2:
                        normalized_key = self._normalize_theater_key(theater_key[0], theater_key[1])
                        # Ensure latest_date is a date object
                        if isinstance(latest_date, datetime):
                            latest_date = latest_date.date()
                        elif not isinstance(latest_date, date):
                            continue
                        normalized_theater_dates[normalized_key] = latest_date
                if normalized_theater_dates:
                    normalized_existing_data[normalized_title_key] = normalized_theater_dates
        
        # Determine date range - always ensure UTC and proper date handling
        now = datetime.now(timezone.utc)
        today = now.date()
        
        if date_range_start is None:
            date_range_start = now
        else:
            if date_range_start.tzinfo is None:
                date_range_start = date_range_start.replace(tzinfo=timezone.utc)
            else:
                date_range_start = date_range_start.astimezone(timezone.utc)
        
        if date_range_end is None:
            date_range_end = now + timedelta(days=14)
        else:
            if date_range_end.tzinfo is None:
                date_range_end = date_range_end.replace(tzinfo=timezone.utc)
            else:
                date_range_end = date_range_end.astimezone(timezone.utc)
        
        # Always ensure we scrape at least 14 days ahead from today
        target_end_date = today + timedelta(days=14)
        start_date = date_range_start.date()
        end_date = max(date_range_end.date(), target_end_date)
        
        location = f"{city}, {state}, {country}" if state else f"{city}, {country}"
        
        try:
            # Step 1: Find theaters
            print(f"Step 1: Finding theaters in {location}...")
            theaters = self.find_theaters(city, country, state)
            
            if not theaters:
                return {
                    'success': False,
                    'error': f'No theaters found for {location}',
                    'movies': []
                }
            
            print(f"Found {len(theaters)} theaters")
            
            # Step 2: Find all movies currently playing
            print(f"Step 2: Finding movies currently playing in {location}...")
            movies = self.find_movies(theaters, city, country, state)
            
            if not movies:
                return {
                    'success': False,
                    'error': f'No movies found for {location}',
                    'movies': []
                }
            
            print(f"Found {len(movies)} movies")
            
            # Step 3: Scrape each movie day by day across all theaters
            movie_data_by_title = {}  # title_key -> movie data with theaters by date
            current_date = start_date
            max_date = current_date  # Track the latest date we've found showtimes for
            
            # Scrape from start date until we reach 14 days ahead
            while current_date <= end_date:
                date_str = current_date.isoformat()
                target_datetime = datetime.combine(current_date, dt_time.min).replace(tzinfo=timezone.utc)
                
                print(f"Scraping date: {date_str}")
                
                # For each movie, check if it has showtimes on this day
                for movie in movies:
                    # Create unique key from movie title
                    title_key = self._get_movie_title_key(movie.get('movie_title', {}))
                    
                    if not title_key:
                        continue
                    
                    title_display = movie.get('movie_title', {})
                    if isinstance(title_display, dict):
                        title_display = title_display.get('en') or title_display.get('local') or title_display.get('ua') or title_key
                    else:
                        title_display = str(title_display) if title_display else title_key
                    
                    # Check if we should skip scraping this movie/day
                    should_skip, earliest_needed = self._should_skip_movie_day(
                        title_key, current_date, normalized_existing_data, theaters
                    )
                    
                    if should_skip:
                        print(f"  - Skipping {title_display} for {date_str} (all theaters already have data)")
                        continue
                    
                    print(f"  - Checking {title_display} for {date_str}...")
                    result = self.scrape_movie_day(movie, theaters, target_datetime, city, country, state)
                    
                    if result and result.get('theaters'):
                        # Movie has showtimes on this date
                        theaters_data = result.get('theaters', [])
                        if theaters_data:
                            # Filter out theaters we already have data for
                            filtered_theaters_data = []
                            
                            for theater_data in theaters_data:
                                theater_name = theater_data.get('name', '')
                                theater_address = theater_data.get('address', '')
                                theater_key = self._normalize_theater_key(theater_name, theater_address)
                                
                                # Check if we already have data for this movie/theater up to this date
                                if title_key in normalized_existing_data and theater_key in normalized_existing_data[title_key]:
                                    latest_existing_date = normalized_existing_data[title_key][theater_key]
                                    # Skip if we already have data for this date or later
                                    if latest_existing_date >= current_date:
                                        print(f"      - Skipping {theater_name} (already have data up to {latest_existing_date})")
                                        continue
                                
                                # We need this data
                                filtered_theaters_data.append(theater_data)
                            
                            # Only add if we have theaters that need data
                            if filtered_theaters_data:
                                # Initialize movie data if not exists
                                if title_key not in movie_data_by_title:
                                    movie_data_by_title[title_key] = {
                                        'movie_title': movie.get('movie_title', {}),
                                        'movie_description': movie.get('movie_description', {}),
                                        'movie_image_url': movie.get('movie_image_url', ''),
                                        'theaters_by_date': {}  # date -> list of theaters with showtimes
                                    }
                                
                                # Add theaters for this date
                                if date_str not in movie_data_by_title[title_key]['theaters_by_date']:
                                    movie_data_by_title[title_key]['theaters_by_date'][date_str] = []
                                
                                movie_data_by_title[title_key]['theaters_by_date'][date_str].extend(filtered_theaters_data)
                                max_date = max(max_date, current_date)
                            else:
                                print(f"      - No new data for {date_str} (all theaters already have data)")
                    
                    # Move to next day
                    current_date += timedelta(days=1)
            
            # Step 4: Transform to database format
            merged_movies = self._merge_movies_from_dates(movie_data_by_title, city, state, country)
            
            return {
                'success': True,
                'movies': merged_movies,
                'movies_count': len(merged_movies)
            }
            
        except Exception as e:
            import traceback
            print(f"Error in scrape_city_showtimes: {e}")
            print(traceback.format_exc())
            return {
                'success': False,
                'error': str(e),
                'movies': []
            }
    
    def _merge_movies_from_dates(self, movie_data_by_title: Dict[str, Dict],
                                 city: str, state: str, country: str) -> List[Dict]:
        """
        Merge movies from the new structure (theaters_by_date)
        """
        from core.image_handler import download_image
        
        result = []
        
        for title_key, movie_data in movie_data_by_title.items():
            movie_title = movie_data.get('movie_title', {})
            movie_description = movie_data.get('movie_description', {})
            movie_image_url = movie_data.get('movie_image_url', '')
            theaters_by_date = movie_data.get('theaters_by_date', {})
            
            if not isinstance(movie_title, dict):
                movie_title = {'local': str(movie_title) if movie_title else ''}
            if not isinstance(movie_description, dict):
                movie_description = {}
            
            movie_title_str = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or ''
            
            # Download image
            movie_image_path = None
            if movie_image_url:
                movie_image_path = download_image(movie_image_url, movie_title_str)
            
            # Merge theaters across all dates
            # Structure: theater_name+address -> theater with showtimes from all dates
            theaters_dict = {}  # (name, address) -> theater dict
            
            for date_str, theaters_list in theaters_by_date.items():
                if not isinstance(theaters_list, list):
                    continue
                
                for theater_data in theaters_list:
                    if not isinstance(theater_data, dict):
                        continue
                    
                    theater_name = theater_data.get('name', 'Unknown')
                    theater_address = theater_data.get('address', '')
                    theater_website = theater_data.get('website', '')
                    showtimes = theater_data.get('showtimes', [])
                    
                    if not isinstance(showtimes, list):
                        continue
                    
                    # Create unique key for theater
                    theater_key = (theater_name, theater_address)
                    
                    if theater_key not in theaters_dict:
                        theaters_dict[theater_key] = {
                            'name': theater_name,
                            'address': theater_address,
                            'website': theater_website,
                            'showtimes': []
                        }
                    
                    # Add showtimes for this date
                    for st in showtimes:
                        if not isinstance(st, dict):
                            continue
                        
                        time_str = st.get('start_time', '')
                        if not time_str:
                            continue
                        
                        try:
                            time_str = time_str.replace('Z', '+00:00')
                            start_time = datetime.fromisoformat(time_str)
                            
                            if start_time.tzinfo is None:
                                start_time = start_time.replace(tzinfo=timezone.utc)
                            
                            # Validate time is in future
                            start_time_utc = start_time.astimezone(timezone.utc)
                            now_utc = datetime.now(timezone.utc)
                            
                            if start_time_utc < now_utc + timedelta(hours=1):
                                continue  # Skip past showtimes
                            
                            theaters_dict[theater_key]['showtimes'].append({
                                'start_time': start_time,
                                'format': st.get('format'),
                                'language': st.get('language', ''),
                                'hall': st.get('hall', '')
                            })
                        except (ValueError, TypeError) as e:
                            print(f"Invalid showtime format: {time_str}, error: {e}")
                            continue
            
            # Filter out theaters with no valid showtimes
            valid_theaters = []
            for theater in theaters_dict.values():
                if theater['showtimes']:
                    valid_theaters.append(theater)
            
            if valid_theaters:
                result.append({
                    'city': city,
                    'state': state or '',
                    'country': country,
                    'city_id': f"{city}, {state}, {country}" if state else f"{city}, {country}",
                    'movie': movie_title,
                    'movie_description': movie_description,
                    'movie_image_url': movie_image_url,
                    'movie_image_path': movie_image_path,
                    'theaters': valid_theaters,
                    'created_at': datetime.now(timezone.utc),
                    'updated_at': datetime.now(timezone.utc)
                })
        
        return result
    
    def _extract_json(self, text: str) -> str:
        """Extract JSON from response text"""
        # Try markdown code blocks first
        json_match = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', text, re.DOTALL)
        if json_match:
            return json_match.group(1)
        
        # Try to find JSON object
        brace_positions = [i for i, char in enumerate(text) if char == '{']
        for start_pos in brace_positions:
            brace_count = 0
            end_pos = -1
            for i in range(start_pos, len(text)):
                if text[i] == '{':
                    brace_count += 1
                elif text[i] == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        end_pos = i
                        break
            
            if end_pos != -1:
                candidate = text[start_pos:end_pos+1]
                try:
                    json.loads(candidate)
                    return candidate
                except json.JSONDecodeError:
                    continue
        
        # Try array format
        bracket_positions = [i for i, char in enumerate(text) if char == '[']
        for start_pos in bracket_positions:
            bracket_count = 0
            end_pos = -1
            for i in range(start_pos, len(text)):
                if text[i] == '[':
                    bracket_count += 1
                elif text[i] == ']':
                    bracket_count -= 1
                    if bracket_count == 0:
                        end_pos = i
                        break
            
            if end_pos != -1:
                candidate = text[start_pos:end_pos+1]
                try:
                    json.loads(candidate)
                    return candidate
                except json.JSONDecodeError:
                    continue
        
        # Last resort: try simple regex
        json_match = re.search(r'[\{\[].*[\}\]]', text, re.DOTALL)
        if json_match:
            return json_match.group(0)
        
        raise ValueError(f"No valid JSON found in response: {text[:500]}")

# Alias for backward compatibility
ClaudeAgent = GeminiAgent
