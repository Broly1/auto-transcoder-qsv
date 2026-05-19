#!/bin/bash

# =========================================================
# x265 ULTRA ARCHIVAL MODE (Blu-ray Transparent)
# - Grain-preserving tuning
# - HDR-safe pipeline
# - Psycho-visual optimized
# - CRF 16–17 sweet spot
# =========================================================

INPUT="$1"

if [ -z "$INPUT" ]; then
  echo "Usage: ./archive.sh <input file>"
  exit 1
fi

DIR="$(dirname "$INPUT")"
FILE="$(basename "$INPUT")"
NAME="${FILE%.*}"

TITLE="$(echo "$NAME" | sed -E \
's/_t[0-9]+//g;
 s/\[.*\]//g;
 s/\(.*\)//g;
 s/\./ /g;
 s/_/ /g;
 s/  */ /g;' | xargs)"

OUTPUT="$DIR/${TITLE} (x265).mkv"

echo "================================================="
echo " x265 ULTRA ARCHIVAL MODE"
echo "================================================="
echo "Input : $INPUT"
echo "Output: $OUTPUT"
echo ""

# =========================================================
# VIDEO ANALYSIS (HDR detection only)
# =========================================================

COLOR_TRANSFER=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=color_transfer \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

COLOR_PRIMARIES=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=color_primaries \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

COLOR_SPACE=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=colorspace \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

# =========================================================
# HDR SAFE PRESERVATION
# =========================================================

HDR_PARAMS=""

case "$COLOR_TRANSFER" in
  smpte2084|arib-std-b67)
    echo "HDR detected → full metadata preservation"

    HDR_PARAMS="\
-x265-params hdr-opt=1:repeat-headers=1:\
colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:chromaloc=2"
    ;;
  *)
    echo "SDR detected"
    ;;
esac

# =========================================================
# 🎯 ARCHIVAL QUALITY SETTINGS
# =========================================================

# CRF RANGE:
# 16 = near lossless (huge files)
# 17 = recommended archival sweet spot
# 18 = still transparent, smaller

CRF=17

# =========================================================
# 🔥 CORE X265 ARCHIVAL TUNING
# =========================================================

VIDEO_OPTS="\
-c:v libx265 \
-preset veryslow \
-crf $CRF \
-profile:v main10 \
-pix_fmt yuv420p10le \
-x265-params \
log-level=error:\
aq-mode=3:aq-strength=1.2:\
psy-rd=2.5:psy-rdoq=1.5:\
rdoq-level=2:\
rd=4:\
deblock=-1,-1:\
strong-intra-smoothing=1:\
cutree=1:\
rect=1:amp=1:\
me=3:subme=5:merange=57:\
max-tu-size=32:\
ref=5"

# =========================================================
# 🔊 AUDIO (LOSSLESS ALWAYS)
# =========================================================

AUDIO_OPTS="-c:a copy"

# =========================================================
# 💬 SUBTITLES (RAW COPY)
# =========================================================

SUB_OPTS="-c:s copy"

# =========================================================
# EXECUTION
# =========================================================

ffmpeg -nostdin \
-analyzeduration 6G \
-probesize 6G \
-i "$INPUT" \
-map 0:v:0 \
-map 0:a? \
-map 0:s? \
-map 0:t? \
-map_chapters 0 \
-metadata title="$TITLE" \
$VIDEO_OPTS \
$HDR_PARAMS \
$AUDIO_OPTS \
$SUB_OPTS \
-max_interleave_delta 0 \
-y \
"$OUTPUT"

echo ""
echo "================================================="
echo " ARCHIVAL COMPLETE"
echo "================================================="
echo "$OUTPUT"
echo "================================================="