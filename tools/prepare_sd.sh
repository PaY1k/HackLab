#!/usr/bin/env bash
# Put music on a microSD card for the player (tracks 4 and 5 on the board).
#
# The card must be FAT32 (most cards up to 32 GB already are; otherwise format
# it as FAT32 / "MS-DOS (FAT)" in the OS). The player plays the first two
# *.WAV files of the root folder, 8 or 16 bit, mono or stereo, any rate.
# This script converts any audio (MP3 from the organizers' card too) to
# 16-bit mono 48 kHz WAV with short names TRACK1.WAV, TRACK2.WAV.
#
# Usage:  tools/prepare_sd.sh /media/$USER/SDCARD song1.mp3 song2.mp3
#         (macOS: /Volumes/NAME)
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <card mount folder> <audio file> [audio file]"
  exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg not found: sudo apt install ffmpeg"; exit 1; }

dst="$1"; shift
n=1
for f in "$@"; do
  out="$dst/TRACK$n.WAV"
  echo "$f -> $out"
  ffmpeg -v error -y -i "$f" -ac 1 -ar 48000 -c:a pcm_s16le -map_metadata -1 "$out"
  n=$((n + 1))
  [ $n -gt 2 ] && break
done
sync
echo "done. The player shows the files as TRACK1.WAV / TRACK2.WAV (tracks 04 and 05)."
