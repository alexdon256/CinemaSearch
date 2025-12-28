# Firefox and Video Codecs Installation Script

This script installs and configures Firefox with full video codec support on CachyOS (Arch-based).

## Features

- Installs Firefox browser
- Installs multimedia codec bundles (audio and video)
- Installs GStreamer plugins for video playback
- Installs FFmpeg codecs
- Configures Firefox for optimal video playback
- Creates a launcher script with proper environment variables

## Usage

```bash
sudo ./scripts/install_firefox_codecs.sh
```

## What It Does

1. **Updates system** - Ensures system is up to date
2. **Installs Firefox** - Installs Firefox browser via pacman
3. **Installs Codecs** - Installs multimedia packages including:
   - Audio codecs
   - Video codecs (H.264, VP8, VP9, etc.)
   - GStreamer plugins
   - FFmpeg libraries
4. **Configures Firefox** - Sets up environment for video playback
5. **Creates Launcher** - Creates `firefox-video` command with optimal settings
6. **Creates Desktop Shortcut** - Creates Firefox shortcut on desktop for all users

## Video Formats Supported

After installation, Firefox will support:
- **WebM** (VP8, VP9 codecs)
- **MP4** (H.264 codec)
- **Ogg** (Theora, Vorbis codecs)
- **H.265/HEVC** (if codecs available)

## Usage After Installation

### Desktop Shortcut
After installation, a **Firefox** shortcut will appear on your desktop. Simply double-click it to launch Firefox with full video codec support.

### Command Line

#### Standard Firefox
```bash
firefox
```

#### Firefox with Video Support (Recommended)
```bash
firefox-video
```

The `firefox-video` launcher includes:
- Proper GStreamer plugin paths
- Hardware acceleration support
- WebRender rendering engine

**Note:** The desktop shortcut uses the `firefox-video` launcher automatically, so you get optimal video playback when launching from the desktop.

## Testing Video Playback

1. Launch Firefox: `firefox-video`
2. Visit test sites:
   - https://www.youtube.com
   - https://www.html5test.com
   - https://www.w3.org/2010/05/video/mediaevents.html

## Troubleshooting

### Video Still Not Playing

1. **Check codec installation:**
   ```bash
   gst-inspect-1.0 | grep -i video
   ```

2. **Verify Firefox version:**
   ```bash
   firefox --version
   ```

3. **Check for missing libraries:**
   ```bash
   ldd /usr/bin/firefox | grep -i codec
   ```

### Install Additional Codecs

If specific codecs are missing, you can try:
```bash
sudo pacman -S gst-plugins-rs libvpx libx264 libx265
```

### Flatpak Codecs

The script attempts to install codecs via Flatpak if available:
```bash
flatpak install flathub org.freedesktop.Platform.ffmpeg-full
```

## Requirements

- CachyOS (Arch-based)
- Root/sudo access
- Internet connection for downloads
- At least 2GB free disk space

## Notes

- Some proprietary codecs (like H.264) may require additional licensing
- Arch repositories include open-source codecs by default
- Hardware acceleration depends on your GPU and drivers
- The script creates a desktop file for easy launching from GUI

## Integration with Deployment Script

This script is separate from the main deployment script and can be run independently. It's useful for:
- Setting up development environments
- Configuring servers with GUI access
- Ensuring video playback capabilities for testing

