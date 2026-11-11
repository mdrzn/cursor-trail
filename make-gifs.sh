#!/bin/bash
# Genera le GIF dimostrative in docs/ (serve ffmpeg). Nessuna registrazione dello schermo:
# l'app disegna fuori schermo, con lo stesso motore, il cursore che percorre un otto.
set -e
cd "$(dirname "$0")"
[ -d CursorTrail.app ] || ./build.sh
rm -rf demo-frames; mkdir -p demo-frames docs
./CursorTrail.app/Contents/MacOS/CursorTrail --demo demo-frames
for d in demo-frames/*/; do
  name=$(basename "$d")
  ffmpeg -loglevel error -y -framerate 50 -i "$d%04d.png" \
    -vf "scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    -loop 0 "docs/$name.gif"
  echo "docs/$name.gif $(du -h "docs/$name.gif" | cut -f1)"
done
rm -rf demo-frames
