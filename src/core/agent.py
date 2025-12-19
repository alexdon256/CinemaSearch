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
    
    def scrape_city_showtimes(self, city: str, country: str = None) -> Dict:
        """
        Scrape showtimes for a given city
        
        Args:
            city: Name of the city to scrape
            country: Country name for disambiguation (optional but recommended)
            
        Returns:
            Dictionary with 'success', 'showtimes', and optional 'error'
        """
        # Build location string
        if country:
            location = f"{city}, {country}"
        else:
            location = city
        
        # Parse city/country from combined string if provided as "City, Country"
        if not country and ', ' in city:
            parts = city.rsplit(', ', 1)
            city = parts[0]
            country = parts[1] if len(parts) > 1 else None
            location = f"{city}, {country}" if country else city
        
        prompt = f"""You are a web scraping agent. Your task is to find cinema websites in {location} and extract current movie showtimes.

Location Details:
- City: {city}
- Country: {country or 'Not specified (use context from city name)'}

Requirements:
1. Search for official cinema chain websites operating in {location}
2. Look for major cinema chains in that country (e.g., Multiplex, Planeta Kino for Ukraine; AMC, Regal for USA; Odeon, Vue for UK)
3. Extract showtimes that are in the FUTURE only (not past screenings)
4. For each showtime, extract:
   - Movie title (in local language, English, and other available languages)
   - Cinema name and location/address
   - Start time (ISO 8601 format with timezone)
   - Format (2D, 3D, IMAX, 4DX, Dolby Atmos, etc.)
   - Price (in local currency if available)
   - Direct purchase link (deep link to ticketing page for that specific showing)
   - Audio language / dubbing / subtitles information

5. Validate that all links point to actual ticketing pages
6. Only include showtimes that are at least 1 hour in the future
7. Include the local currency for prices (UAH for Ukraine, USD for USA, EUR for EU, etc.)

Return your findings as a JSON structure with this format:
{{
    "city": "{city}",
    "country": "{country or 'Unknown'}",
    "cinemas": [
        {{
            "name": "Cinema Name",
            "address": "Full address",
            "website": "https://...",
            "showtimes": [
                {{
                    "movie_title": {{"en": "English Title", "local": "Local Language Title"}},
                    "start_time": "2025-12-20T18:00:00+02:00",
                    "format": "2D",
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
            response_text = message.content[0].text
            
            # Extract JSON from response (handle markdown code blocks)
            import json
            import re
            
            # Try to extract JSON from markdown code blocks
            json_match = re.search(r'```(?:json)?\s*(\{.*\})\s*```', response_text, re.DOTALL)
            if json_match:
                response_text = json_match.group(1)
            
            result = json.loads(response_text)
            
            # Transform to database format
            showtimes = []
            result_city = result.get('city', city)
            result_country = result.get('country', country or 'Unknown')
            
            for cinema in result.get('cinemas', []):
                cinema_name = cinema.get('name', 'Unknown')
                cinema_address = cinema.get('address', '')
                
                for st in cinema.get('showtimes', []):
                    # Validate time is in future
                    try:
                        start_time = datetime.fromisoformat(st['start_time'].replace('Z', '+00:00'))
                        if start_time < datetime.now(start_time.tzinfo) + timedelta(hours=1):
                            continue  # Skip past or too-close showtimes
                    except:
                        continue  # Skip invalid dates
                    
                    showtime = {
                        'city': result_city,
                        'country': result_country,
                        'city_id': f"{result_city}, {result_country}",  # Combined for lookup
                        'cinema_id': cinema_name,
                        'cinema_name': cinema_name,
                        'cinema_address': cinema_address,
                        'movie': st.get('movie_title', {}),
                        'start_time': start_time,
                        'format': st.get('format', '2D'),
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

