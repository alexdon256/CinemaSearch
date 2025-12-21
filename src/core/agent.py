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
    
    def scrape_city_showtimes(self, city: str, country: str = None, state: str = None) -> Dict:
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
        
        prompt = f"""You are a web scraping agent. Your task is to find cinema websites in {location} and extract current movie showtimes.

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
4. Extract showtimes from TODAY up to 2 WEEKS IN ADVANCE (or whatever is available on the cinema websites)
   - Start from today's date
   - Include all showtimes up to 14 days in the future
   - If cinemas only show less than 2 weeks ahead, include whatever is available
   - DO NOT include past showtimes
5. For each showtime, extract:
   - Movie title (in local language, English, and other available languages)
   - Movie poster/image URL (high-quality poster image URL if available)
   - Cinema name and location/address (FULL address including street, building number, etc.)
   - Start time (ISO 8601 format with timezone)
   - Format (OPTIONAL - only include if available: 2D, 3D, IMAX, 4DX, Dolby Atmos, etc.)
   - Price (in local currency if available)
   - Direct purchase link (deep link to ticketing page for that specific showing)
   - Audio language / dubbing / subtitles information

6. Validate that all links point to actual ticketing pages
7. Only include showtimes that are at least 1 hour in the future (to avoid showing showtimes that are about to start)
8. Include the local currency for prices (UAH for Ukraine, USD for USA, EUR for EU, etc.)

Return your findings as a JSON structure with this format:
{{
    "city": "{city}",
    "state": "{state or ''}",
    "country": "{country}",
    "cinemas": [
        {{
            "name": "Cinema Name",
            "address": "Full address",
            "website": "https://...",
            "showtimes": [
                {{
                    "movie_title": {{"en": "English Title", "local": "Local Language Title"}},
                    "movie_image_url": "https://example.com/poster.jpg",
                    "start_time": "2025-12-20T18:00:00+02:00",
                    "format": "2D",  // Optional: 2D, 3D, IMAX, 4DX, Dolby Atmos, etc. Only include if available
                    "price": "150 UAH",
                    "buy_link": "https://...",
                    "language": "Ukrainian dubbing",
                    "hall": "Hall 5"
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
                max_tokens=4096,
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
            
            # Transform to database format
            showtimes = []
            result_city = result.get('city', city)
            result_state = result.get('state', state or '')
            result_country = result.get('country', country)
            
            # Validate cinemas is a list
            cinemas = result.get('cinemas', [])
            if not isinstance(cinemas, list):
                cinemas = []
            
            for cinema in cinemas:
                if not isinstance(cinema, dict):
                    continue
                cinema_name = cinema.get('name', 'Unknown')
                cinema_address = cinema.get('address', '')
                
                # Validate showtimes is a list
                cinema_showtimes = cinema.get('showtimes', [])
                if not isinstance(cinema_showtimes, list):
                    cinema_showtimes = []
                
                for st in cinema_showtimes:
                    if not isinstance(st, dict):
                        continue
                    # Validate time is in future and within 2 weeks
                    try:
                        time_str = st.get('start_time', '')
                        if not time_str:
                            continue
                        # Handle timezone-aware and naive datetimes
                        time_str = time_str.replace('Z', '+00:00')
                        start_time = datetime.fromisoformat(time_str)
                        
                        # Make comparison timezone-aware
                        if start_time.tzinfo is None:
                            # Naive datetime - assume UTC
                            from datetime import timezone
                            start_time = start_time.replace(tzinfo=timezone.utc)
                        
                        now = datetime.now(start_time.tzinfo) if start_time.tzinfo else datetime.utcnow()
                        
                        # Skip if showtime is less than 1 hour in the future (too soon)
                        if start_time < now + timedelta(hours=1):
                            continue  # Skip past or too-close showtimes
                        
                        # Skip if showtime is more than 2 weeks in the future
                        two_weeks_from_now = now + timedelta(days=14)
                        if start_time > two_weeks_from_now:
                            continue  # Skip showtimes beyond 2 weeks
                    except (ValueError, KeyError, TypeError) as e:
                        print(f"Invalid date format in showtime: {e}")
                        continue  # Skip invalid dates
                    
                    # Build location identifier with state if available
                    if result_state:
                        location_id = f"{result_city}, {result_state}, {result_country}"
                    else:
                        location_id = f"{result_city}, {result_country}"
                    
                    # Get movie title for image naming
                    movie_title = st.get('movie_title', {})
                    movie_title_str = movie_title.get('en') or movie_title.get('local') or movie_title.get('ua') or ''
                    
                    # Download movie image if URL is provided
                    movie_image_path = None
                    movie_image_url = st.get('movie_image_url')
                    if movie_image_url:
                        from core.image_handler import download_image
                        movie_image_path = download_image(movie_image_url, movie_title_str)
                    
                    showtime = {
                        'city': result_city,
                        'state': result_state,
                        'country': result_country,
                        'city_id': location_id,  # Combined for lookup
                        'cinema_id': cinema_name,
                        'cinema_name': cinema_name,
                        'cinema_address': cinema_address,  # Full address including street
                        'movie': movie_title,
                        'movie_image_url': movie_image_url,  # Original URL
                        'movie_image_path': movie_image_path,  # Local path if downloaded
                        'start_time': start_time,
                        'format': st.get('format'),  # Optional - only include if available
                        'price': st.get('price', ''),
                        'buy_link': st.get('buy_link', ''),
                        'language': st.get('language', ''),
                        'hall': st.get('hall', ''),
                        'created_at': datetime.utcnow()
                    }
                    showtimes.append(showtime)
            
            return {
                'success': True,
                'showtimes': showtimes,
                'cinemas_found': len(result.get('cinemas', []))
            }
            
        except Exception as e:
            return {
                'success': False,
                'error': str(e),
                'showtimes': []
            }

