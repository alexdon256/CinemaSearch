"""
Claude AI Agent for Web Scraping
Distributed agent that discovers and scrapes cinema showtimes
"""

import os
from anthropic import Anthropic
from typing import Dict, List, Optional
from datetime import datetime, timedelta

# Available models (in order of cost, cheapest first)
MODELS = {
    'haiku': 'claude-3-5-haiku-20241022',    # Fastest, cheapest - good for structured tasks
    'sonnet': 'claude-sonnet-4-20250514',     # Balanced performance/cost
}

# Default to Haiku for cost efficiency (structured JSON extraction works well)
DEFAULT_MODEL = 'haiku'

class ClaudeAgent:
    """AI Agent wrapper for Claude API"""
    
    def __init__(self, model_key: str = None):
        api_key = os.getenv('ANTHROPIC_API_KEY')
        if not api_key:
            raise ValueError("ANTHROPIC_API_KEY environment variable is required")
        
        self.client = Anthropic(api_key=api_key)
        
        # Allow model override via env var or parameter
        model_key = model_key or os.getenv('CLAUDE_MODEL', DEFAULT_MODEL)
        self.model = MODELS.get(model_key, MODELS[DEFAULT_MODEL])
    
    def scrape_city_showtimes(self, city: str, country: str = None, state: str = None, date_range_start: datetime = None, date_range_end: datetime = None) -> Dict:
        """
        Scrape showtimes for a given city
        
        Args:
            city: Name of the city to scrape
            country: Country name for disambiguation (required for accuracy)
            state: State/Province/Region name (optional but recommended for large countries)
            
        Returns:
            Dictionary with 'success', 'showtimes', and optional 'error'
        """
        # Input validation and sanitization
        if not city or not isinstance(city, str) or not city.strip():
            raise ValueError("City must be a non-empty string")
        if not country or not isinstance(country, str) or not country.strip():
            raise ValueError("Country is required for accurate location identification")
        
        # Sanitize inputs
        city = city.strip()[:100]
        country = country.strip()[:100]
        # Handle state - it can be None, empty string, or a valid string
        if state:
            if isinstance(state, str):
                state = state.strip()[:100] if state.strip() else None
            else:
                state = None
        else:
            state = None
        
        # Build location string with state if available
        if state:
            location = f"{city}, {state}, {country}"
        else:
            location = f"{city}, {country}"
        
        # Determine date range for scraping
        from datetime import timezone
        now = datetime.now(timezone.utc)
        
        # Ensure date ranges are timezone-aware
        if date_range_start is None:
            date_range_start = now
        else:
            # Ensure timezone-aware
            if date_range_start.tzinfo is None:
                date_range_start = date_range_start.replace(tzinfo=timezone.utc)
        
        if date_range_end is None:
            date_range_end = now + timedelta(days=14)
        else:
            # Ensure timezone-aware
            if date_range_end.tzinfo is None:
                date_range_end = date_range_end.replace(tzinfo=timezone.utc)
        
        # Format dates for prompt (use UTC dates)
        start_date_str = date_range_start.date().isoformat()
        end_date_str = date_range_end.date().isoformat()
        
        # Build date range description
        today_utc = now.date()
        two_weeks_utc = (now + timedelta(days=14)).date()
        if date_range_start.date() == today_utc and date_range_end.date() == two_weeks_utc:
            date_range_desc = "from TODAY up to 2 WEEKS IN ADVANCE"
        else:
            date_range_desc = f"from {start_date_str} to {end_date_str}"
        
        prompt = f"""You are a web scraping agent. Your task is to find cinema websites in {location} and extract movie showtimes.

CRITICAL: Use the EXACT location specified below to avoid confusion with cities of the same name in other countries/states.

Location Details:
- City: {city}
- State/Province/Region: {state or 'Not specified'}
- Country: {country}
- Full Location: {location}

Requirements:
1. Search for all official cinema chain websites operating SPECIFICALLY in {location}
2. IMPORTANT: If there are multiple cities with the same name, ensure you are searching in {country}{f', {state}' if state else ''}, NOT other countries or states
3. Look for major and minor cinema chains in that country/region (e.g., Multiplex, Planeta Kino for Ukraine; AMC, Regal, Cinemark for USA; Odeon, Vue, Cineworld for UK, etc.)
4. Extract showtimes {date_range_desc} (or whatever is available on the cinema websites)
   - DO NOT include past showtimes
   - Only include showtimes that are at least 1 hour in the future
5. For each movie, extract:
   - Movie title (in local language, English, and other available languages)
   - Movie poster/image URL (high-quality poster image URL if available)
   - For each cinema showing this movie:
     * Cinema name and location/address (FULL address including street, building number, etc.)
     * Cinema website URL (general website, not specific showtime links)
     * Showtimes for this movie at this cinema:
       - Start time (ISO 8601 format with timezone)
       - Format (OPTIONAL - only include if available: 2D, 3D, IMAX, 4DX, Dolby Atmos, etc.)
       - Audio language / dubbing / subtitles information
       - Hall/room number if available

6. Group by movie to avoid duplication - each movie should appear once with all its showtimes across all cinemas

Return your findings as a JSON structure with this format:
{{
    "city": "{city}",
    "state": "{state or ''}",
    "country": "{country}",
    "movies": [
        {{
            "movie_title": {{"en": "English Title", "local": "Local Language Title"}},
            "movie_image_url": "https://example.com/poster.jpg",
            "theaters": [
                {{
                    "name": "Cinema Name",
                    "address": "Full address including street, building number, etc.",
                    "website": "https://cinema-website.com",
                    "showtimes": [
                        {{
                            "start_time": "2025-12-20T18:00:00+02:00",
                            "format": "2D",  // Optional: only include if available
                            "language": "Ukrainian dubbing",
                            "hall": "Hall 5"  // Optional
                        }}
                    ]
                }}
            ]
        }}
    ]
}}

If you cannot find any valid showtimes, return {{"error": "No showtimes found for {location}"}}.
"""
        
        try:
            # Validate prompt is not empty
            if not prompt or not prompt.strip():
                raise ValueError("Prompt is empty")
            
            message = self.client.messages.create(
                model=self.model,
                max_tokens=8192,
                messages=[
                    {
                        "role": "user",
                        "content": prompt
                    }
                ]
            )
            
            # Parse response
            if not message.content or len(message.content) == 0:
                raise ValueError("Empty response from API")
            
            response_text = message.content[0].text
            if not response_text or not response_text.strip():
                raise ValueError("Empty response text from API")
            
            # Extract JSON from response (handle markdown code blocks)
            import json
            import re
            
            # Try to extract JSON from markdown code blocks
            json_match = re.search(r'```(?:json)?\s*(\{.*\})\s*```', response_text, re.DOTALL)
            if json_match:
                response_text = json_match.group(1)
            else:
                # Try to find JSON object directly
                json_match = re.search(r'\{.*\}', response_text, re.DOTALL)
                if json_match:
                    response_text = json_match.group(0)
                else:
                    raise ValueError(f"No JSON found in response. Response: {response_text[:200]}")
            
            # Validate and parse JSON
            try:
                result = json.loads(response_text)
            except json.JSONDecodeError as e:
                raise ValueError(f"Failed to parse JSON response: {e}. Response: {response_text[:200]}")
            
            # Validate result structure
            if not isinstance(result, dict):
                raise ValueError(f"Expected JSON object, got {type(result)}")
            
            # Check for error response
            if 'error' in result:
                return {
                    'success': False,
                    'error': result.get('error', 'Unknown error'),
                    'showtimes': []
                }
            
            # Transform to database format (movies with theaters)
            movies = []
            result_city = result.get('city', city)
            result_state = result.get('state', state or '')
            result_country = result.get('country', country)
            
            # Build location identifier with state if available
            if result_state:
                location_id = f"{result_city}, {result_state}, {result_country}"
            else:
                location_id = f"{result_city}, {result_country}"
            
            # Validate movies is a list
            movies_data = result.get('movies', [])
            if not isinstance(movies_data, list):
                movies_data = []
            
            for movie_data in movies_data:
                if not isinstance(movie_data, dict):
                    continue
                
                movie_title = movie_data.get('movie_title', {})
                if not isinstance(movie_title, dict):
                    movie_title = {}
                
                movie_title_str = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or ''
                movie_image_url = movie_data.get('movie_image_url')
                
                # Download movie image if URL is provided
                movie_image_path = None
                if movie_image_url:
                    from core.image_handler import download_image
                    movie_image_path = download_image(movie_image_url, movie_title_str)
                
                # Process theaters and showtimes
                theaters_data = movie_data.get('theaters', [])
                if not isinstance(theaters_data, list):
                    theaters_data = []
                
                theaters = []
                for theater in theaters_data:
                    if not isinstance(theater, dict):
                        continue
                    
                    theater_name = theater.get('name', 'Unknown')
                    theater_address = theater.get('address', '')
                    theater_website = theater.get('website', '')
                    
                    # Process showtimes for this theater
                    showtimes_data = theater.get('showtimes', [])
                    if not isinstance(showtimes_data, list):
                        showtimes_data = []
                    
                    valid_showtimes = []
                    for st in showtimes_data:
                        if not isinstance(st, dict):
                            continue
                        
                        # Validate time is in future and within range
                        try:
                            time_str = st.get('start_time', '')
                            if not time_str:
                                continue
                            # Handle timezone-aware and naive datetimes
                            time_str = time_str.replace('Z', '+00:00')
                            start_time = datetime.fromisoformat(time_str)
                            
                            # Preserve original timezone for display - don't convert to UTC
                            from datetime import timezone
                            if start_time.tzinfo is None:
                                # If naive, the agent should have provided timezone info
                                # For safety, assume UTC but log a warning
                                print(f"Warning: Naive datetime received for showtime, assuming UTC: {time_str}")
                                start_time = start_time.replace(tzinfo=timezone.utc)
                            
                            # For comparisons only, convert to UTC (but keep original timezone for storage)
                            start_time_utc = start_time.astimezone(timezone.utc)
                            now_utc = datetime.now(timezone.utc)
                            
                            # Skip if showtime is less than 1 hour in the future (compare in UTC)
                            if start_time_utc < now_utc + timedelta(hours=1):
                                continue
                            
                            # Check if within requested date range (convert to UTC for comparison)
                            if date_range_start:
                                range_start_utc = date_range_start
                                if range_start_utc.tzinfo is None:
                                    range_start_utc = range_start_utc.replace(tzinfo=timezone.utc)
                                else:
                                    range_start_utc = range_start_utc.astimezone(timezone.utc)
                                if start_time_utc < range_start_utc:
                                    continue
                            
                            if date_range_end:
                                range_end_utc = date_range_end
                                if range_end_utc.tzinfo is None:
                                    range_end_utc = range_end_utc.replace(tzinfo=timezone.utc)
                                else:
                                    range_end_utc = range_end_utc.astimezone(timezone.utc)
                                if start_time_utc > range_end_utc:
                                    continue
                            
                            # Store original timezone-aware datetime (preserves timezone info for display)
                        except (ValueError, KeyError, TypeError) as e:
                            print(f"Invalid date format in showtime: {e}")
                            continue
                        
                        valid_showtimes.append({
                            'start_time': start_time,
                            'format': st.get('format'),  # Optional
                            'language': st.get('language', ''),
                            'hall': st.get('hall', '')
                        })
                    
                    if valid_showtimes:
                        theaters.append({
                            'name': theater_name,
                            'address': theater_address,
                            'website': theater_website,
                            'showtimes': valid_showtimes
                        })
                
                if theaters:  # Only add movie if it has valid theaters/showtimes
                    movies.append({
                        'city': result_city,
                        'state': result_state,
                        'country': result_country,
                        'city_id': location_id,
                        'movie': movie_title,
                        'movie_image_url': movie_image_url,
                        'movie_image_path': movie_image_path,
                        'theaters': theaters,
                        'created_at': datetime.now(timezone.utc),
                        'updated_at': datetime.now(timezone.utc)
                    })
            
            return {
                'success': True,
                'movies': movies,
                'movies_count': len(movies)
            }
            
        except Exception as e:
            return {
                'success': False,
                'error': str(e),
                'movies': []
            }

