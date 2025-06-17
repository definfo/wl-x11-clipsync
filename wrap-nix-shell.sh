#!/usr/bin/env bash

set -euo pipefail

OUTPUT_FILE="clipsync.hs"
SOURCE_FILE="app/Main.hs"

if [[ ! -f $SOURCE_FILE ]]; then
  echo "Error: Source file '$SOURCE_FILE' not found" >&2
  exit 1
fi

if [[ -f $OUTPUT_FILE ]]; then
  read -p "Warning: '$OUTPUT_FILE' already exists. Overwrite? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

{
  printf "#!/usr/bin/env nix-shell\n"
  printf "#! nix-shell -i runghc -p 'haskellPackages.ghcWithPackages (hspkgs: with hspkgs; [ process-extras ])' wl-clipboard xclip clipnotify\n"
  printf "\n"
} >"$OUTPUT_FILE"

cat "$SOURCE_FILE" >>"$OUTPUT_FILE"
chmod +x clipsync.hs

echo "Created executable '$OUTPUT_FILE'"
