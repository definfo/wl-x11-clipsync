# Wayland ↔ X11 Clipboard Sync

This Haskell script synchronizes the clipboard between Wayland (via `wl-copy`/`wl-paste`) and X11 (via `xclip`). It listens for clipboard changes using `clipnotify` and automatically transfers new data from one side to the other, handling text, HTML, images, and file URIs.

## Features

- **Automatic two-way sync** between Wayland and X11 clipboards.
- **MIME priority**: 
  - First tries `text/uri-list` for file transfers, 
  - then `text/html` (some applications, like Firefox, provide images as HTML),
  - then raw images `image/*`, 
  - and finally `text/plain`.
- **Text normalization**: removes extra newlines/trailing spaces to avoid duplicate triggers (especially from Firefox).
- **No polling**: uses `clipnotify` to react to clipboard events. 

## Requirements

This script only requires `Nix` to be installed.

## Usage

1. Clone or download the `clipsync.hs` script.
2. Make it executable if not:
`chmod +x clipsync.hs`
3. Run it in a terminal or background process:
`./clipsync.hs`

Now, whenever you copy something in a Wayland-native app, the same data becomes available to X11 apps, and vice versa.

## Notes and Caveats

  - Copying images to X11 works really badly.
  - For file copy-paste, this script prioritizes text/uri-list only. Some DEs (like GNOME/KDE) may use other formats (`application/x-gnome-copied-files`, etc.). If needed, add them to the priority in the script.
  - If both Wayland and X11 clipboards change "simultaneously", the script gives priority to Wayland content to resolve conflicts.

## Contributing

Feel free to open issues or pull requests if you have additional MIME formats, suggestions, or improvements. This script is provided as-is, in the hope it helps anyone needing bridging between Wayland and X11 clipboards.

Enjoy seamless clipboard sharing between Wayland and X11!
