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
    'haiku': 'claude-haiku-4-5-20251001'
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
        
        prompt = f"""You are a web scraping agent. Your task is to find cinema websites in {location} and extract movie showtimes using web_search.

CRITICAL INSTRUCTIONS:
- Use the web_search tool extensively to find cinema websites and showtimes
- web_search returns the FULL CONTENT of web pages, not just snippets - extract showtime data from the page content
- Your FINAL response must be ONLY valid JSON - no explanatory text, no markdown, no code blocks
- Do NOT include any text before or after the JSON
- The response must start with {{ and end with }}
- Use the EXACT location specified below to avoid confusion with cities of the same name

Location Details:
- City: {city}
- State/Province/Region: {state or 'Not specified'}
- Country: {country}
- Full Location: {location}

SEARCH STRATEGY (use up to 12 web_search calls):
1. Start with broad searches to identify cinema chains in {location}:
   - Search: "[city] cinema showtimes [country]"
   - Search: "[city] movie theaters [country]"
   - Search: "[city] кинотеатр розклад" (for Ukrainian/Russian cities)
   - Search: "cinema [city] [country] schedule"

2. For each major cinema chain found, search specifically for their showtime pages:
   - Search: "[cinema chain name] [city] showtimes"
   - Search: "[cinema chain name] [city] schedule today"
   - Search: "[cinema chain name] [city] movies playing"
   - Try searching for the cinema's official website URL directly if found

3. Look for major cinema chains in {country}:
   - Ukraine: Multiplex, Planeta Kino, Cinema City, Oscar, etc.
   - USA: AMC, Regal, Cinemark, Alamo Drafthouse, etc.
   - UK: Odeon, Vue, Cineworld, Showcase, etc.
   - Search for each chain specifically: "[chain name] [city] [country]"

4. IMPORTANT: If there are multiple cities with the same name, ensure you are searching in {country}{f', {state}' if state else ''}, NOT other countries or states

5. Extract showtime information from the FULL PAGE CONTENT returned by web_search:
   - The web_search results contain the complete webpage HTML/content
   - Look for showtime tables, schedules, movie listings in the page content
   - Extract dates, times, movie titles, formats, languages from the page content
   - If a page shows "today" or "this week", extract those showtimes

DATA EXTRACTION REQUIREMENTS:
6. Extract showtimes {date_range_desc}:
   - DO NOT include past showtimes
   - Only include showtimes that are at least 1 hour in the future
   - Extract ALL available showtimes from the pages you access
   - Convert times to ISO 8601 format with timezone (use local timezone of {location})

7. For each movie found, extract:
   - Movie title (in local language, English, and other available languages: en, ua, ru)
   - Movie description/synopsis (in multiple languages: en, ua, ru - extract from pages or use your knowledge)
   - Movie poster/image URL (high-quality poster image URL if available in page content)
   - For each cinema showing this movie:
     * Cinema name and location/address (FULL address including street, building number, etc.)
     * Cinema website URL (general website URL)
     * Showtimes for this movie at this cinema:
       - Start time (ISO 8601 format with timezone - use the local timezone of {location})
       - Format (OPTIONAL - only include if available: 2D, 3D, IMAX, 4DX, Dolby Atmos, etc.)
       - Audio language / dubbing / subtitles information
       - Hall/room number if available

8. Group by movie to avoid duplication - each movie should appear once with all its showtimes across all cinemas

9. USE ALL 12 WEB_SEARCH CALLS if needed:
   - Don't stop after finding one cinema - search for multiple cinemas
   - Try different search terms if initial searches don't return useful results
   - Search for specific cinema websites and their showtime pages
   - Be thorough - use all available searches to find as much data as possible

OUTPUT FORMAT - Return ONLY this JSON structure (no other text):
{{
    "city": "{city}",
    "state": "{state or ''}",
    "country": "{country}",
    "movies": [
        {{
            "movie_title": {{"en": "English Title", "local": "Local Language Title", "ua": "Ukrainian Title", "ru": "Russian Title"}},
            "movie_description": {{"en": "English description/synopsis", "ua": "Ukrainian description", "ru": "Russian description"}},
            "movie_image_url": "https://example.com/poster.jpg",
            "theaters": [
                {{
                    "name": "Cinema Name",
                    "address": "Full address including street, building number, etc.",
                    "website": "https://cinema-website.com",
                    "showtimes": [
                        {{
                            "start_time": "2025-12-20T18:00:00+02:00",
                            "format": "2D",
                            "language": "Ukrainian dubbing",
                            "hall": "Hall 5"
                        }}
                    ]
                }}
            ]
        }}
    ]
}}

ERROR HANDLING:
- Only return an error if you have used multiple web_search calls (at least 5-6 searches) and still cannot find showtimes
- If you find cinema websites but showtime pages are inaccessible, try searching for alternative terms or pages
- If you cannot find any valid showtimes after thorough searching (using 8+ searches), return ONLY: {{"error": "No showtimes found for {location} - web scraping limitation"}}

REMEMBER: 
- Your response must be ONLY valid JSON, starting with {{ and ending with }}
- No explanatory text, no markdown code blocks, no additional commentary
- web_search returns FULL page content - extract showtimes from the HTML/content in the search results
- Use all 12 available web_search calls to be thorough
- Extract data from the page content returned by web_search, not just from search snippets
"""
        
        try:
            # Validate prompt is not empty
            if not prompt or not prompt.strip():
                raise ValueError("Prompt is empty")
            
            try:
                # Include web_search tool to enable internet browsing
                tools = [{
                    "type": "web_search_20250305",
                    "name": "web_search",
                    "max_uses": 12  # Allow multiple searches for finding cinema websites
                }]
                
                # Start conversation with web search enabled
                messages = [
                    {
                        "role": "user",
                        "content": prompt
                    }
                ]
                
                message = None
                
                message = self.client.messages.create(
                    model=self.model,
                    max_tokens=16384,
                    messages=messages,
                    tools=tools
                )
                
                # Check if response contains tool use
                if message.stop_reason == "tool_use":
                    # Add assistant's tool use to messages
                    messages.append({
                        "role": "assistant",
                        "content": message.content
                    })
                    
                
                if not message:
                    raise ValueError("Failed to get response from API after multiple iterations")
                    
            except Exception as api_error:
                # Check if it's an API key/authentication error
                error_str = str(api_error).lower()
                if 'api key' in error_str or 'authentication' in error_str or '401' in error_str or '403' in error_str or 'invalid' in error_str:
                    raise ValueError("ANTHROPIC_API_KEY is invalid or authentication failed. Please check your API key configuration.")
                # Re-raise other errors as-is
                raise
            
            # Parse response
            if not message.content or len(message.content) == 0:
                raise ValueError("Empty response from API")
            
            # Extract text from response (handle both text and tool use content blocks)
            response_text = ""
            for content_block in message.content:
                if content_block.type == "text":
                    response_text += content_block.text
                elif content_block.type == "tool_use":
                    # Tool use blocks shouldn't appear in final response, but handle gracefully
                    continue
            
            if not response_text or not response_text.strip():
                raise ValueError("Empty response text from API")
            
            # Extract JSON from response (handle markdown code blocks and text before/after)
            import json
            import re
            
            # First, try to extract JSON from markdown code blocks
            json_match = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', response_text, re.DOTALL)
            if json_match:
                response_text = json_match.group(1)
            else:
                # Try to find JSON object directly (handle nested braces properly)
                # Find all positions of opening braces
                brace_positions = [i for i, char in enumerate(response_text) if char == '{']
                
                # Try parsing JSON starting from each opening brace
                extracted_json = None
                for start_pos in brace_positions:
                    # Try to find the matching closing brace by counting
                    brace_count = 0
                    end_pos = -1
                    for i in range(start_pos, len(response_text)):
                        if response_text[i] == '{':
                            brace_count += 1
                        elif response_text[i] == '}':
                            brace_count -= 1
                            if brace_count == 0:
                                end_pos = i
                                break
                    
                    if end_pos != -1:
                        # Try to parse this as JSON
                        candidate = response_text[start_pos:end_pos+1]
                        try:
                            json.loads(candidate)  # Validate it's valid JSON
                            extracted_json = candidate
                            break
                        except json.JSONDecodeError:
                            continue
                
                if extracted_json:
                    response_text = extracted_json
                else:
                    # Last resort: try simple regex
                    json_match = re.search(r'\{.*\}', response_text, re.DOTALL)
                    if json_match:
                        response_text = json_match.group(0)
                    else:
                        raise ValueError(f"No valid JSON found in response. Response: {response_text[:500]}")
            
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
                
                movie_description = movie_data.get('movie_description', {})
                if not isinstance(movie_description, dict):
                    movie_description = {}
                
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
                        'movie_description': movie_description,
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

