"""
Gemini AI Agent for Web Scraping
Step-by-step scraping: Find theaters, then scrape each theater day by day
"""

import os
import json
import re
from typing import Dict, List, Optional
from datetime import datetime, timedelta, timezone, time as dt_time
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
            # Use grounding with Google Search for web access
            # Note: Grounding may require specific model or API configuration
            # Use dict format for generation_config (more compatible)
            response = self.model.generate_content(
                prompt,
                generation_config={
                    'temperature': 0.1,
                    'max_output_tokens': 4096,
                }
            )
            
            # Handle response - check if text exists
            if not hasattr(response, 'text') or not response.text:
                print("Error: Empty response from Gemini API")
                return []
            
            response_text = response.text.strip()
            
            # Extract JSON from response
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
            response = self.model.generate_content(
                prompt,
                generation_config={
                    'temperature': 0.1,
                    'max_output_tokens': 8192,
                }
            )
            
            if not hasattr(response, 'text') or not response.text:
                print("Error: Empty response from Gemini API when finding movies")
                return []
            
            response_text = response.text.strip()
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
                        city: str, country: str, state: str = None) -> Dict:
        """
        Step 3: Scrape showtimes for a specific movie across all theaters for one day
        
        Args:
            movie: Dict with movie_title, movie_description, movie_image_url
            theaters: List of theater dicts
            target_date: Date to scrape (datetime object)
            city, country, state: Location info
            
        Returns:
            Dict with movie info and showtimes from all theaters for that day
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
            response = self.model.generate_content(
                prompt,
                generation_config={
                    'temperature': 0.1,
                    'max_output_tokens': 8192,
                }
            )
            
            if not hasattr(response, 'text') or not response.text:
                print(f"Error: Empty response from Gemini API for {title_display} on {date_str}")
                return None
            
            response_text = response.text.strip()
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
                              date_range_start: datetime = None, date_range_end: datetime = None) -> Dict:
        """
        Main scraping method: Step-by-step approach
        1. Find theaters
        2. Find all movies currently playing
        3. For each movie, scrape day by day across all theaters
        4. Continue until 2 weeks ahead or no movies found
        5. Track last showtime to maintain 2 weeks coverage
        
        Returns:
            Dictionary with 'success', 'movies', and optional 'error'
        """
        # Input validation
        if not city or not isinstance(city, str) or not city.strip():
            raise ValueError("City must be a non-empty string")
        if not country or not isinstance(country, str) or not country.strip():
            raise ValueError("Country is required")
        
        city = city.strip()[:100]
        country = country.strip()[:100]
        state = state.strip()[:100] if state and isinstance(state, str) else None
        
        # Determine date range
        now = datetime.now(timezone.utc)
        if date_range_start is None:
            date_range_start = now
        else:
            if date_range_start.tzinfo is None:
                date_range_start = date_range_start.replace(tzinfo=timezone.utc)
        
        if date_range_end is None:
            date_range_end = now + timedelta(days=14)
        else:
            if date_range_end.tzinfo is None:
                date_range_end = date_range_end.replace(tzinfo=timezone.utc)
        
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
            # Track the latest showtime date for each movie
            movie_data_by_title = {}  # title_key -> movie data with theaters by date
            current_date = date_range_start.date()
            end_date = date_range_end.date()
            max_date = current_date  # Track the latest date we've found showtimes for
            
            # For each day in range
            while current_date <= end_date:
                date_str = current_date.isoformat()
                target_datetime = datetime.combine(current_date, dt_time.min).replace(tzinfo=timezone.utc)
                
                print(f"Scraping date: {date_str}")
                
                # For each movie, check if it has showtimes on this day
                for movie in movies:
                    # Create unique key from movie title
                    movie_title = movie.get('movie_title', {})
                    if isinstance(movie_title, dict):
                        title_key = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or ''
                    else:
                        title_key = str(movie_title) if movie_title else ''
                    
                    if not title_key:
                        continue
                    
                    title_key = title_key.lower().strip()
                    title_display = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or title_key
                    
                    print(f"  - Checking {title_display} for {date_str}...")
                    result = self.scrape_movie_day(movie, theaters, target_datetime, city, country, state)
                    
                    if result and result.get('theaters'):
                        # Movie has showtimes on this date
                        theaters_data = result.get('theaters', [])
                        if theaters_data:
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
                            
                            movie_data_by_title[title_key]['theaters_by_date'][date_str].extend(theaters_data)
                            max_date = max(max_date, current_date)
                
                # Move to next day
                current_date += timedelta(days=1)
            
            # Step 4: Continue scraping if we haven't reached 2 weeks yet
            # Check if any movie has showtimes extending beyond our current end_date
            target_end_date = (now + timedelta(days=14)).date()
            if max_date < target_end_date:
                print(f"Extending search: last showtime found on {max_date}, target is {target_end_date}")
                current_date = max_date + timedelta(days=1)
                
                while current_date <= target_end_date:
                    date_str = current_date.isoformat()
                    target_datetime = datetime.combine(current_date, dt_time.min).replace(tzinfo=timezone.utc)
                    
                    print(f"Extended scraping date: {date_str}")
                    
                    # Check all movies again for extended dates
                    for movie in movies:
                        movie_title = movie.get('movie_title', {})
                        if isinstance(movie_title, dict):
                            title_key = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or ''
                        else:
                            title_key = str(movie_title) if movie_title else ''
                        
                        if not title_key or title_key.lower().strip() not in movie_data_by_title:
                            continue
                        
                        title_key = title_key.lower().strip()
                        title_display = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or title_key
                        
                        print(f"  - Checking {title_display} for {date_str}...")
                        result = self.scrape_movie_day(movie, theaters, target_datetime, city, country, state)
                        
                        if result and result.get('theaters'):
                            theaters_data = result.get('theaters', [])
                            if theaters_data:
                                if date_str not in movie_data_by_title[title_key]['theaters_by_date']:
                                    movie_data_by_title[title_key]['theaters_by_date'][date_str] = []
                                movie_data_by_title[title_key]['theaters_by_date'][date_str].extend(theaters_data)
                                max_date = max(max_date, current_date)
                    
                    current_date += timedelta(days=1)
            
            # Step 5: Transform to database format
            merged_movies = self._merge_movies_from_dates(movie_data_by_title, city, state, country)
            
            return {
                'success': True,
                'movies': merged_movies,
                'movies_count': len(merged_movies)
            }
            
        except Exception as e:
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
    
    def _merge_movies_by_title(self, movies_by_date: Dict[str, List[Dict]], 
                               city: str, state: str, country: str) -> List[Dict]:
        """Merge movies by title across dates and theaters"""
        from core.image_handler import download_image
        
        # Group movies by title
        movies_dict = {}  # title_key -> movie data
        
        for date_str, movies in movies_by_date.items():
            for movie in movies:
                # Create unique key from movie title
                title = movie.get('movie_title', {})
                if isinstance(title, dict):
                    title_key = title.get('en') or title.get('local') or title.get('ua') or ''
                else:
                    title_key = str(title) if title else ''
                
                if not title_key:
                    continue
                
                # Normalize title key (lowercase, strip)
                title_key = title_key.lower().strip()
                
                if title_key not in movies_dict:
                    # New movie - initialize
                    movie_title = movie.get('movie_title', {})
                    if not isinstance(movie_title, dict):
                        movie_title = {'local': str(movie_title) if movie_title else ''}
                    
                    movie_description = movie.get('movie_description', {})
                    if not isinstance(movie_description, dict):
                        movie_description = {}
                    
                    movie_image_url = movie.get('movie_image_url', '')
                    movie_title_str = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or ''
                    
                    # Download image
                    movie_image_path = None
                    if movie_image_url:
                        movie_image_path = download_image(movie_image_url, movie_title_str)
                    
                    movies_dict[title_key] = {
                        'city': city,
                        'state': state or '',
                        'country': country,
                        'city_id': f"{city}, {state}, {country}" if state else f"{city}, {country}",
                        'movie': movie_title,
                        'movie_description': movie_description,
                        'movie_image_url': movie_image_url,
                        'movie_image_path': movie_image_path,
                        'theaters': [],
                        'created_at': datetime.now(timezone.utc),
                        'updated_at': datetime.now(timezone.utc)
                    }
                
                # Add theater and showtimes
                theater_name = movie.get('theater_name', 'Unknown')
                theater_address = movie.get('theater_address', '')
                theater_website = movie.get('theater_website', '')
                
                # Find or create theater in this movie's theaters list
                theater = None
                for t in movies_dict[title_key]['theaters']:
                    if t['name'] == theater_name and t['address'] == theater_address:
                        theater = t
                        break
                
                if not theater:
                    theater = {
                        'name': theater_name,
                        'address': theater_address,
                        'website': theater_website,
                        'showtimes': []
                    }
                    movies_dict[title_key]['theaters'].append(theater)
                
                # Add showtimes for this date
                showtimes = movie.get('showtimes', [])
                if isinstance(showtimes, list):
                    for st in showtimes:
                        if not isinstance(st, dict):
                            continue
                        
                        # Validate and parse showtime
                        time_str = st.get('start_time', '')
                        if not time_str:
                            continue
                        
                        try:
                            time_str = time_str.replace('Z', '+00:00')
                            start_time = datetime.fromisoformat(time_str)
                            
                            if start_time.tzinfo is None:
                                start_time = start_time.replace(tzinfo=timezone.utc)
                            
                            # Validate time is in future and within range
                            start_time_utc = start_time.astimezone(timezone.utc)
                            now_utc = datetime.now(timezone.utc)
                            
                            if start_time_utc < now_utc + timedelta(hours=1):
                                continue  # Skip past showtimes
                            
                            theater['showtimes'].append({
                                'start_time': start_time,
                                'format': st.get('format'),
                                'language': st.get('language', ''),
                                'hall': st.get('hall', '')
                            })
                        except (ValueError, TypeError) as e:
                            print(f"Invalid showtime format: {time_str}, error: {e}")
                            continue
        
        # Convert to list and filter out movies with no valid showtimes
        result = []
        for movie_data in movies_dict.values():
            # Filter theaters with valid showtimes
            valid_theaters = []
            for theater in movie_data['theaters']:
                if theater['showtimes']:
                    valid_theaters.append(theater)
            
            if valid_theaters:
                movie_data['theaters'] = valid_theaters
                result.append(movie_data)
        
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
