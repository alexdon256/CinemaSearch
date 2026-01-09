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
    
    def scrape_theater_day(self, theater: Dict, target_date: datetime, city: str, country: str, state: str = None) -> List[Dict]:
        """
        Step 2: Scrape showtimes for a specific theater on a specific day
        
        Args:
            theater: Dict with name, address, website
            target_date: Date to scrape (datetime object)
            city, country, state: Location info
            
        Returns:
            List of movie dicts with showtimes for that day
        """
        date_str = target_date.strftime('%Y-%m-%d')
        day_name = target_date.strftime('%A, %B %d, %Y')
        location = f"{city}, {state}, {country}" if state else f"{city}, {country}"
        
        prompt = f"""Find movie showtimes for {theater['name']} on {day_name} ({date_str}).

Theater: {theater['name']}
Address: {theater['address']}
Website: {theater['website']}
Location: {location}

Search the theater website for showtimes on {date_str}. Extract:
- Movie title (in local language, English, Ukrainian, Russian if available)
- Movie description/synopsis (en/ua/ru)
- Movie poster/image URL
- Showtimes for {date_str}:
  * Start time (ISO 8601 format with timezone: YYYY-MM-DDTHH:MM:SS+TZ)
  * Format (2D/3D/IMAX/4DX if available)
  * Language/dubbing/subtitles
  * Hall/room number if available

Return ONLY JSON:
{{
    "date": "{date_str}",
    "theater": "{theater['name']}",
    "movies": [
        {{
            "movie_title": {{"en": "...", "local": "...", "ua": "...", "ru": "..."}},
            "movie_description": {{"en": "...", "ua": "...", "ru": "..."}},
            "movie_image_url": "https://...",
            "showtimes": [
                {{"start_time": "2025-12-20T18:00:00+02:00", "format": "2D", "language": "...", "hall": "..."}}
            ]
        }}
    ]
}}

If no showtimes found for this date, return: {{"date": "{date_str}", "theater": "{theater['name']}", "movies": []}}
"""
        
        try:
            # Use dict format for generation_config (more compatible)
            response = self.model.generate_content(
                prompt,
                generation_config={
                    'temperature': 0.1,
                    'max_output_tokens': 8192,
                }
            )
            
            # Handle response - check if text exists
            if not hasattr(response, 'text') or not response.text:
                print(f"Error: Empty response from Gemini API for {theater['name']}")
                return []
            
            response_text = response.text.strip()
            json_text = self._extract_json(response_text)
            result = json.loads(json_text)
            
            if not isinstance(result, dict) or 'movies' not in result:
                return []
            
            movies = result.get('movies', [])
            if not isinstance(movies, list):
                return []
            
            # Add theater info to each movie
            for movie in movies:
                movie['theater_name'] = theater['name']
                movie['theater_address'] = theater['address']
                movie['theater_website'] = theater['website']
            
            return movies
            
        except Exception as e:
            print(f"Error scraping {theater['name']} for {date_str}: {e}")
            return []
    
    def scrape_city_showtimes(self, city: str, country: str = None, state: str = None, 
                              date_range_start: datetime = None, date_range_end: datetime = None) -> Dict:
        """
        Main scraping method: Step-by-step approach
        1. Find theaters
        2. For each theater, scrape day by day
        3. Merge all results
        
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
            
            # Step 2: Scrape each theater day by day
            all_movies_by_date = {}  # date -> list of movies
            current_date = date_range_start.date()
            end_date = date_range_end.date()
            
            while current_date <= end_date:
                # Create datetime at start of day in UTC
                target_datetime = datetime.combine(current_date, dt_time.min).replace(tzinfo=timezone.utc)
                date_str = current_date.isoformat()
                
                print(f"Scraping date: {date_str}")
                
                for theater in theaters:
                    print(f"  - Scraping {theater['name']} for {date_str}...")
                    movies = self.scrape_theater_day(theater, target_datetime, city, country, state)
                    
                    if movies:
                        if date_str not in all_movies_by_date:
                            all_movies_by_date[date_str] = []
                        all_movies_by_date[date_str].extend(movies)
                
                # Move to next day
                current_date += timedelta(days=1)
            
            # Step 3: Merge and transform to database format
            merged_movies = self._merge_movies_by_title(all_movies_by_date, city, state, country)
            
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
