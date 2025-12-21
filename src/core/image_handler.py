"""
Image Download and Management Handler
Downloads movie images, stores them locally, and manages cleanup
"""

import os
import hashlib
import requests
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urlparse
from PIL import Image
import io

# Image storage configuration
# Store images in static/movie_images relative to the src directory
# __file__ is src/core/image_handler.py, so we go up 2 levels to get to src/
SRC_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE_BASE_DIR = os.path.join(SRC_DIR, 'static', 'movie_images')
IMAGE_EXPIRY_DAYS = 90  # 3 months (matches MongoDB TTL)

def ensure_image_directory():
    """Ensure the image directory exists"""
    Path(IMAGE_BASE_DIR).mkdir(parents=True, exist_ok=True)
    return IMAGE_BASE_DIR

def get_image_filename(image_url: str, movie_title: str = None) -> str:
    """
    Generate a unique filename for an image based on URL and movie title
    
    Args:
        image_url: URL of the image
        movie_title: Optional movie title for better naming
        
    Returns:
        Filename with extension
    """
    # Create hash from URL for uniqueness
    url_hash = hashlib.md5(image_url.encode()).hexdigest()[:12]
    
    # Try to get extension from URL
    parsed = urlparse(image_url)
    path = parsed.path
    ext = os.path.splitext(path)[1] or '.jpg'
    
    # Clean extension (remove query params if any)
    ext = ext.split('?')[0]
    if not ext or ext not in ['.jpg', '.jpeg', '.png', '.webp', '.gif']:
        ext = '.jpg'
    
    # Create filename with movie title if available
    if movie_title:
        # Clean movie title for filename (remove special chars, limit length)
        clean_title = "".join(c for c in movie_title if c.isalnum() or c in (' ', '-', '_')).strip()[:30]
        clean_title = clean_title.replace(' ', '_').replace('__', '_')  # Remove double underscores
        if clean_title:  # Only use if not empty after cleaning
            filename = f"{clean_title}_{url_hash}{ext}"
        else:
            filename = f"{url_hash}{ext}"
    else:
        filename = f"{url_hash}{ext}"
    
    return filename

def download_image(image_url: str, movie_title: str = None) -> str:
    """
    Download an image from URL and save it locally
    
    Args:
        image_url: URL of the image to download
        movie_title: Optional movie title for better naming
        
    Returns:
        Relative path to the saved image (for use in templates)
        Returns None if download fails
    """
    if not image_url or not image_url.startswith(('http://', 'https://')):
        return None
    
    try:
        # Ensure directory exists
        ensure_image_directory()
        
        # Generate filename
        filename = get_image_filename(image_url, movie_title)
        filepath = os.path.join(IMAGE_BASE_DIR, filename)
        
        # Skip if already exists (but verify it's a valid image file)
        if os.path.exists(filepath):
            try:
                # Quick validation that it's actually an image
                test_img = Image.open(filepath)
                try:
                    test_img.verify()
                    test_img.close()  # Close after verify
                    return f"/static/movie_images/{filename}"
                except Exception:
                    test_img.close()  # Ensure closed even if verify fails
                    raise
            except Exception:
                # File exists but is corrupted, remove it and re-download
                try:
                    os.remove(filepath)
                except Exception:
                    pass
        
        # Download image
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }
        response = requests.get(image_url, headers=headers, timeout=10, stream=True)
        response.raise_for_status()
        
        # Validate it's an image
        content_type = response.headers.get('content-type', '')
        if not content_type.startswith('image/'):
            return None
        
        # Read and validate image (with size limit to prevent memory issues)
        MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB limit
        image_data = response.content
        if len(image_data) < 100:  # Too small, probably not a real image
            return None
        if len(image_data) > MAX_IMAGE_SIZE:  # Too large, skip
            print(f"Image too large ({len(image_data)} bytes), skipping")
            return None
        
        # Try to open with PIL to validate
        try:
            img = Image.open(io.BytesIO(image_data))
            img.verify()
        except Exception:
            return None
        
        # Re-open for saving (verify() closes the image)
        img = Image.open(io.BytesIO(image_data))
        
        try:
            # Convert to RGB if necessary (for JPEG compatibility)
            original_mode = img.mode
            if original_mode in ('RGBA', 'LA', 'P'):
                # Create white background
                rgb_img = Image.new('RGB', img.size, (255, 255, 255))
                # Convert palette to RGBA if needed
                if original_mode == 'P':
                    img = img.convert('RGBA')
                # Paste with alpha channel as mask
                if original_mode in ('RGBA', 'LA') or (original_mode == 'P' and img.mode == 'RGBA'):
                    rgb_img.paste(img, mask=img.split()[-1])  # Use alpha channel as mask
                else:
                    rgb_img.paste(img)
                img.close()  # Close original image
                img = rgb_img
            
            # Save as JPEG for consistency and smaller size
            if not filename.endswith('.jpg'):
                filename = filename.rsplit('.', 1)[0] + '.jpg'
                filepath = os.path.join(IMAGE_BASE_DIR, filename)
            
            img.save(filepath, 'JPEG', quality=85, optimize=True)
            img.close()  # Ensure image is closed after saving
            
            return f"/static/movie_images/{filename}"
        except Exception as e:
            # Ensure image is closed even if save fails
            if img:
                try:
                    img.close()
                except Exception:
                    pass
            raise
        
    except Exception as e:
        print(f"Error downloading image from {image_url}: {e}")
        return None

def cleanup_old_images():
    """
    Remove images older than IMAGE_EXPIRY_DAYS
    This should be called periodically or when records are deleted
    """
    try:
        ensure_image_directory()
        from datetime import timezone
        cutoff_date = datetime.now(timezone.utc) - timedelta(days=IMAGE_EXPIRY_DAYS)
        
        removed_count = 0
        # Only process image files, skip directories and other files
        for filepath in Path(IMAGE_BASE_DIR).glob('*'):
            if filepath.is_file():
                # Only process image files
                if not filepath.suffix.lower() in ['.jpg', '.jpeg', '.png', '.gif', '.webp']:
                    continue
                try:
                    # Check file modification time
                    mtime = datetime.fromtimestamp(filepath.stat().st_mtime)
                    if mtime < cutoff_date:
                        try:
                            filepath.unlink()
                            removed_count += 1
                        except (OSError, PermissionError) as e:
                            print(f"Error removing old image {filepath}: {e}")
                except (OSError, ValueError) as e:
                    # Skip files that can't be accessed or have invalid timestamps
                    print(f"Error accessing file {filepath}: {e}")
                    continue
        
        if removed_count > 0:
            print(f"Cleaned up {removed_count} old movie images")
        
        return removed_count
    except Exception as e:
        print(f"Error during image cleanup: {e}")
        return 0

def get_image_path(relative_path: str) -> str:
    """
    Get absolute path from relative image path
    
    Args:
        relative_path: Relative path like "/static/movie_images/filename.jpg"
        
    Returns:
        Absolute file path
    """
    if not relative_path or not relative_path.startswith('/static/movie_images/'):
        return None
    
    filename = os.path.basename(relative_path)
    return os.path.join(IMAGE_BASE_DIR, filename)

