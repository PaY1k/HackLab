#!/usr/bin/env bash
# Put music on a microSD card for the player (tracks 04 and 05 on the board).
#
# The card must be FAT32 (most cards up to 32 GB already are; otherwise format
# it as FAT32 / "MS-DOS (FAT)" in the OS). The player plays the first two
# *.WAV files of the root folder, 8 or 16 bit, mono or stereo, any rate.
# This script converts any audio (MP3, FLAC, M4A ...) to 16-bit mono 48 kHz WAV.
#
# The name on the screen is the 8.3 file name: give it after "=" (up to 8
# letters / digits), otherwise the files are TRACK1.WAV, TRACK2.WAV.
#
# Usage:  tools/prepare_sd.sh <card folder> <file>[=NAME] [<file>[=NAME]]
#   tools/prepare_sd.sh /media/$USER/SDCARD "Playboi Carti - song.mp3=CARTI" other.mp3=MYTRACK
#   (macOS: /Volumes/NAME)
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <card mount folder> <audio file>[=NAME] [<audio file>[=NAME]]"
  exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg not found: sudo apt install ffmpeg"; exit 1; }

dst="$1"; shift
[ -d "$dst" ] || { echo "folder $dst not found: is the card mounted?"; exit 1; }

n=1
for arg in "$@"; do
  src="${arg%=*}"
  name=""
  [ "$src" != "$arg" ] && name="${arg##*=}"
  # 8.3 name: upper case letters, digits and _ only, max 8 characters
  name=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_' | cut -c1-8)
  [ -n "$name" ] || name="TRACK$n"
  [ -f "$src" ] || { echo "file not found: $src"; exit 1; }
  out="$dst/$name.WAV"
  echo "$src -> $out"
  ffmpeg -v error -y -i "$src" -ac 1 -ar 48000 -c:a pcm_s16le -map_metadata -1 "$out"
  n=$((n + 1))
  [ $n -gt 2 ] && break
done
sync
echo "done. The first two .WAV files of the card root are tracks 04 and 05."
echo "Remove other .WAV files from the card root if the wrong ones show up."
