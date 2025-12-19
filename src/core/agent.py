"""
Claude AI Agent for Web Scraping
Distributed agent that discovers and scrapes cinema showtimes
"""

import os
from anthropic import Anthropic
from typing import Dict, List, Optional
from datetime import datetime, timedelta

class ClaudeAgent:
    """AI Agent wrapper for Claude API"""
    
    def __init__(self):
        api_key = os.getenv('ANTHROPIC_API_KEY')
        if not api_key:
            raise ValueError("ANTHROPIC_API_KEY environment variable is required")
        
        self.client = Anthropic(api_key=api_key)
        self.model = "claude-sonnet-4-20250514"  # Latest Claude model
    
    def scrape_city_showtimes(self, city_name: str) -> Dict:
        """
        Scrape showtimes for a given city
        
        Args:
            city_name: Name of the city to scrape
            
        Returns:
            Dictionary with 'success', 'showtimes', and optional 'error'
        """
        prompt = f"""You are a web scraping agent. Your task is to find cinema websites for the city "{city_name}" and extract movie showtimes.

Requirements:
1. Search for official cinema websites in {city_name}
2. Extract showtimes that are in the FUTURE (not past)
3. For each showtime, extract:
   - Movie title (in Ukrainian, English, and Russian if available)
   - Cinema name
   - Start time (ISO 8601 format)
   - Format (2D, 3D, IMAX, etc.)
   - Price (if available)
   - Direct purchase link (deep link to ticketing page)
   - Language/dubbing information

4. Validate that all links are working and point to actual ticketing pages
5. Only include showtimes that are at least 1 hour in the future

Return your findings as a JSON structure with this format:
{{
    "cinemas": [
        {{
            "name": "Cinema Name",
            "website": "https://...",
            "showtimes": [
                {{
                    "movie_title": {{"en": "...", "ua": "...", "ru": "..."}},
                    "start_time": "2025-12-20T18:00:00Z",
                    "format": "2D",
                    "price": "150 UAH",
                    "buy_link": "https://...",
                    "language": "Ukrainian"
                }}
            ]
        }}
    ]
}}

If you cannot find any valid showtimes, return {{"error": "No showtimes found"}}.
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
            for cinema in result.get('cinemas', []):
                cinema_name = cinema.get('name', 'Unknown')
                for st in cinema.get('showtimes', []):
                    # Validate time is in future
                    try:
                        start_time = datetime.fromisoformat(st['start_time'].replace('Z', '+00:00'))
                        if start_time < datetime.now(start_time.tzinfo) + timedelta(hours=1):
                            continue  # Skip past or too-close showtimes
                    except:
                        continue  # Skip invalid dates
                    
                    showtime = {
                        'city_id': city_name,  # Will be set by caller if needed
                        'cinema_id': cinema_name,
                        'cinema_name': cinema_name,
                        'movie': st.get('movie_title', {}),
                        'start_time': start_time,
                        'format': st.get('format', '2D'),
                        'price': st.get('price', ''),
                        'buy_link': st.get('buy_link', ''),
                        'language': st.get('language', ''),
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

