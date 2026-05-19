#!/bin/bash

# =========================================================
# AV1 QSV Blu-ray Transparent Preset (FIXED)
# - Proper QSV device context (FIX)
# - Grain-safe 10-bit pipeline
# - Q12–Q14 quality range
# =========================================================

INPUT="$1"

if [ -z "$INPUT" ]; then
  echo "Usage: ./encode.sh <input file>"
  exit 1
fi

# =========================================================
# PATHS
# =========================================================

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

OUTPUT="$DIR/${TITLE} (AV1).mkv"

echo "================================================="
echo " AV1 QSV BLU-RAY FIXED PIPELINE"
echo "================================================="
echo "Input : $INPUT"
echo "Output: $OUTPUT"
echo ""

# =========================================================
# VIDEO INFO
# =========================================================

VIDEO_CODEC=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=codec_name \
-of csv=p=0 "$INPUT" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

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

echo "Codec    : $VIDEO_CODEC"
echo "Transfer : $COLOR_TRANSFER"
echo ""

# =========================================================
# 🔥 FIX #1: PROPER QSV DEVICE CONTEXT (CRITICAL)
# =========================================================

HWDEVICE="-init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw"

# =========================================================
# 🔥 FIX #2: GRADIENT + GRAIN SAFE PIPELINE
# =========================================================

# IMPORTANT:
# hwupload MUST be linked to QSV device via filter_hw_device
VIDEO_FILTERS='-vf format=p010,hwupload'

# =========================================================
# HDR HANDLING
# =========================================================

HDR_PARAMS=""

case "$COLOR_TRANSFER" in
  smpte2084|arib-std-b67)
    echo "HDR detected (passthrough)"

    HDR_PARAMS="\
-color_primaries ${COLOR_PRIMARIES:-bt2020} \
-color_trc ${COLOR_TRANSFER} \
-colorspace ${COLOR_SPACE:-bt2020nc}"
    ;;
  *)
    echo "SDR detected"
    ;;
esac

# =========================================================
# AUDIO (LOSSLESS BY DEFAULT)
# =========================================================

AUDIO_PARAMS="-c:a copy"

# =========================================================
# SUBTITLES (Blu-ray safe)
# =========================================================

SUB_PARAMS="-c:s copy"

# =========================================================
# 🎯 QUALITY CONTROL (Q12–Q14 RANGE)
# =========================================================

# Recommended:
# Q14 = safer
# Q13 = best balance
# Q12 = max quality

AV1_QP=13

echo "AV1 QSV Quality: Q$AV1_QP"

# =========================================================
# EXECUTION
# =========================================================

echo "[1/3] Encoding..."

ffmpeg -nostdin \
-analyzeduration 2G \
-probesize 2G \
$HWDEVICE \
-i "$INPUT" \
-map 0:v:0 \
-map 0:a? \
-map 0:s? \
-map_chapters 0 \
-metadata title="$TITLE" \
$VIDEO_FILTERS \
-c:v av1_qsv \
-global_quality:v $AV1_QP \
-preset medium \
-look_ahead 1 \
-look_ahead_depth 40 \
-low_power 0 \
-async_depth 4 \
-extra_hw_frames 128 \
$HDR_PARAMS \
$AUDIO_PARAMS \
$SUB_PARAMS \
-max_interleave_delta 0 \
-y \
"$OUTPUT"

echo ""
echo "================================================="
echo " DONE"
echo "================================================="
echo "$OUTPUT"
echo "================================================="