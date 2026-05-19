#!/bin/bash

INPUT="$1"

if [ -z "$INPUT" ]; then
  echo "Usage: ./remuxupsl.sh <input file>"
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
 s/   */ /g;' | xargs)"

OUTPUT="$DIR/${TITLE} (4K AV1 QSV).mkv"

echo "================================="
echo "Analyzing media..."
echo "================================="

# ==========================================
# VIDEO INFO
# ==========================================

VIDEO_CODEC=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=codec_name \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

WIDTH=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=width \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

HEIGHT=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=height \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

PIX_FMT=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=pix_fmt \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

COLOR_TRANSFER=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=color_transfer \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

BIT_DEPTH=$(ffprobe -v error \
-select_streams v:0 \
-show_entries stream=bits_per_raw_sample \
-of csv=p=0 "$INPUT" | tr -d '[:space:]')

if [ -z "$VIDEO_CODEC" ]; then
  echo "ERROR: No video stream detected."
  exit 1
fi

echo "Codec: $VIDEO_CODEC"
echo "Resolution: ${WIDTH}x${HEIGHT}"
echo "Pixel Format: $PIX_FMT"
echo "Transfer: $COLOR_TRANSFER"
echo "Bit Depth: $BIT_DEPTH"

# ==========================================
# UPSCALE TARGET
# ==========================================

if [ "$WIDTH" -ge 3840 ] || [ "$HEIGHT" -ge 2160 ]; then
  SCALE_WIDTH="$WIDTH"
  SCALE_HEIGHT="$HEIGHT"
  echo "Source already 4K+"
else
  SCALE_WIDTH=3840
  SCALE_HEIGHT=2160
  echo "Upscaling to 3840x2160"
fi

# ==========================================
# HDR DETECTION
# ==========================================

HDR_PARAMS=""
SCALE_FORMAT="nv12"

case "$COLOR_TRANSFER" in
  smpte2084|arib-std-b67)

    echo "HDR source detected"

    SCALE_FORMAT="p010"

    HDR_PARAMS="\
-color_primaries bt2020 \
-color_trc smpte2084 \
-colorspace bt2020nc"

    ;;
esac

# ==========================================
# AUDIO DETECTION
# ==========================================

echo ""
echo "Scanning audio streams..."

AUDIO_DATA=$(ffprobe -v error \
-select_streams a \
-show_entries stream=index,codec_name:stream_tags=language \
-of csv=p=0 "$INPUT")

BEST_AUDIO="0:a:0"
BEST_SCORE=-1
MAX_CHANNELS=2
STREAM_LOOP_COUNT=0

while IFS=, read -r INDEX CODEC LANG; do

  [ -z "$INDEX" ] && continue

  INDEX=$(echo "$INDEX" | tr -d '[:space:]')
  CODEC=$(echo "$CODEC" | tr '[:upper:]' '[:lower:]')
  LANG=$(echo "$LANG" | tr '[:upper:]' '[:lower:]')

  if [ -z "$LANG" ]; then
    LANG="und"
  fi

  case "$LANG" in
    eng|english|por|pt|pt-br|portuguese|und)
      ;;
    *)
      echo "Skipping audio stream $INDEX ($LANG)"
      STREAM_LOOP_COUNT=$((STREAM_LOOP_COUNT + 1))
      continue
      ;;
  esac

  CH_COUNT=$(ffprobe -v error \
  -select_streams "a:${STREAM_LOOP_COUNT}" \
  -show_entries stream=channels \
  -of csv=p=0 "$INPUT" | tr -d '[:space:]')

  # Safety fallback
  if [ -z "$CH_COUNT" ] || ! [[ "$CH_COUNT" =~ ^[0-9]+$ ]] || [ "$CH_COUNT" -eq 0 ]; then
    CH_COUNT=2
  fi

  SCORE=$CH_COUNT

  case "$CODEC" in
    truehd|dts-hd*|dtshd*)
      SCORE=$((SCORE + 40))
      ;;
    dts)
      SCORE=$((SCORE + 30))
      ;;
    ac3|eac3)
      SCORE=$((SCORE + 20))
      ;;
    flac)
      SCORE=$((SCORE + 15))
      ;;
    aac|mp3)
      SCORE=$((SCORE + 10))
      ;;
  esac

  echo "Audio $INDEX | codec=$CODEC | lang=$LANG | ch=$CH_COUNT | score=$SCORE"

  if [ "$SCORE" -gt "$BEST_SCORE" ]; then
    BEST_SCORE=$SCORE
    MAX_CHANNELS=$CH_COUNT
    BEST_AUDIO="0:a:${STREAM_LOOP_COUNT}"
  fi

  STREAM_LOOP_COUNT=$((STREAM_LOOP_COUNT + 1))

done <<< "$AUDIO_DATA"

echo ""
echo "Selected audio: $BEST_AUDIO"
echo "Channels: $MAX_CHANNELS"

AUDIOMAPS="-map $BEST_AUDIO"

# ==========================================
# AUDIO SETTINGS
# ==========================================

if [ "$MAX_CHANNELS" -gt 2 ]; then

  echo "Using 5.1 Opus"

  AUDIO_PARAMS="\
-c:a libopus \
-af channelmap=channel_layout=5.1 \
-b:a 384k \
-vbr on \
-ac 6 \
-application audio"

else

  echo "Using Stereo Opus"

  AUDIO_PARAMS="\
-c:a libopus \
-b:a 128k \
-vbr on \
-ac 2 \
-application audio"

fi

# ==========================================
# SUBTITLE FILTERING
# ==========================================

echo ""
echo "Scanning subtitle streams..."

SUBMAPS=""
SUB_LOOP_COUNT=0

while IFS=, read -r INDEX LANG; do

  [ -z "$INDEX" ] && continue

  INDEX=$(echo "$INDEX" | tr -d '[:space:]')
  LANG=$(echo "$LANG" | tr '[:upper:]' '[:lower:]')

  if [ -z "$LANG" ]; then
    LANG="und"
  fi

  case "$LANG" in
    eng|english|por|pt|pt-br|portuguese|und)

      echo "Keeping subtitle stream: $INDEX ($LANG)"

      SUBMAPS="$SUBMAPS -map 0:s:${SUB_LOOP_COUNT}"
      ;;

  esac

  SUB_LOOP_COUNT=$((SUB_LOOP_COUNT + 1))

done < <(
ffprobe -v error \
-select_streams s \
-show_entries stream=index:stream_tags=language \
-of csv=p=0 "$INPUT"
)

# ==========================================
# QSV CONFIG
# ==========================================

echo ""
echo "Initializing Intel QSV..."

HWACCEL_FLAGS="\
-init_hw_device qsv=hw:/dev/dri/renderD128 \
-filter_hw_device hw \
-hwaccel qsv \
-hwaccel_output_format qsv"

case "$VIDEO_CODEC" in

  h264|hevc|vp9|av1)

    VIDEO_FILTERS="-vf scale_qsv=w=${SCALE_WIDTH}:h=${SCALE_HEIGHT}"

    ;;

  *)

    echo "Using software decode upload path"

    VIDEO_FILTERS="-vf format=${SCALE_FORMAT},hwupload=extra_hw_frames=64,scale_qsv=w=${SCALE_WIDTH}:h=${SCALE_HEIGHT}"

    ;;

esac

# ==========================================
# EXECUTE
# ==========================================

echo ""
echo "================================="
echo "Starting AV1 QSV transcode..."
echo "================================="
echo ""

ffmpeg -nostdin \
-analyzeduration 1G \
-probesize 1G \
$HWACCEL_FLAGS \
-i "$INPUT" \
-map 0:v:0 \
$AUDIOMAPS \
$SUBMAPS \
-map_chapters 0 \
$VIDEO_FILTERS \
-metadata "title=$TITLE" \
-c:v av1_qsv \
-global_quality:v 20 \
-preset medium \
-low_power 0 \
-async_depth 4 \
-extra_hw_frames 64 \
$HDR_PARAMS \
$AUDIO_PARAMS \
-c:s copy \
-max_interleave_delta 0 \
-y \
"$OUTPUT"

STATUS=$?

echo ""

if [ "$STATUS" -eq 0 ]; then

  echo "================================="
  echo "4K AV1 QSV encode complete."
  echo "$OUTPUT"
  echo "================================="

else

  echo "================================="
  echo "Transcode failed."
  echo "================================="

fi