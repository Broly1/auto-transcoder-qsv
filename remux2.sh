#!/bin/bash

INPUT="$1"

if [ -z "$INPUT" ]; then
  echo "Usage: ./remux.sh <input file>"
  exit 1
fi

DIR="$(dirname "$INPUT")"
FILE="$(basename "$INPUT")"
NAME="${FILE%.*}"

# Clean up title for metadata tracking
TITLE="$(echo "$NAME" | sed -E 's/_t[0-9]+//g; s/\[.*\]//g; s/\(.*\)//g; s/\./ /g; s/_/ /g; s/  */ /g;' | xargs)"
OUTPUT="$DIR/${TITLE} (AV1 QP16).mkv"

# ==========================================
# 1. CODEC AND AUDIO TRACK PROBING
# ==========================================
echo "Analyzing video codec and audio tracks..."

# Check the video format codec type safely (lowercase & stripped)
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$INPUT" | tr -d '[:space:]"\r\n' | tr '[:upper:]' '[:lower:]')

if [ -z "$VIDEO_CODEC" ]; then
  echo "[CRITICAL ERROR] Could not detect a valid video track. Aborting."
  exit 1
fi

echo "Detected Video Codec: $VIDEO_CODEC"

AUDIO_DATA=$(ffprobe -v error -analyzeduration 250M -probesize 250M \
  -select_streams a \
  -show_entries stream=index,codec_name:stream_tags=language \
  -of csv=p=0 "$INPUT")

BEST_ENG_INDEX=""
BEST_ENG_SCORE=-1
BEST_ENG_CHCOUNT=2

BEST_POR_INDEX=""
BEST_POR_SCORE=-1
BEST_POR_CHCOUNT=2

while IFS=, read -r INDEX CODEC LANG; do
  LANG=$(echo "$LANG" | tr -d '[:space:]"\r\n' | tr '[:upper:]' '[:lower:]')
  CODEC=$(echo "$CODEC" | tr -d '[:space:]"\r\n' | tr '[:upper:]' '[:lower:]')
  INDEX=$(echo "$INDEX" | tr -d '[:space:]"\r\n')

  [ -z "$INDEX" ] && continue

  CH_COUNT=$(ffprobe -v error -select_streams "a:${INDEX}" -show_entries stream=channels -of csv=p=0 "$INPUT" | tr -d '[:space:]"\r\n')
  
  # Safeguard against malformed headers yielding blank or non-numeric channel structures
  if [ -z "$CH_COUNT" ] || ! [[ "$CH_COUNT" =~ ^[0-9]+$ ]] || [ "$CH_COUNT" -eq 0 ]; then
    CH_COUNT=2
  fi

  SCORE=0
  case "$CODEC" in
    truehd|dts-hd*|dtshd*) SCORE=40 ;;
    dts)                  SCORE=30 ;; 
    ac3|eac3)             SCORE=20 ;;
    aac|mp3|flac)         SCORE=10 ;;
    opus)                 SCORE=5  ;;
  esac
  SCORE=$((SCORE + CH_COUNT))

  if [ "$LANG" = "eng" ] || [ "$LANG" = "english" ]; then
    if [ "$SCORE" -gt "$BEST_ENG_SCORE" ]; then
      BEST_ENG_SCORE="$SCORE"
      BEST_ENG_INDEX="$INDEX"
      BEST_ENG_CHCOUNT="$CH_COUNT"
    fi
  elif [ "$LANG" = "por" ] || [ "$LANG" = "portuguese" ] || [ "$LANG" = "ptbr" ] || [ "$LANG" = "pt-br" ]; then
    if [ "$SCORE" -gt "$BEST_POR_SCORE" ]; then
      BEST_POR_SCORE="$SCORE"
      BEST_POR_INDEX="$INDEX"
      BEST_POR_CHCOUNT="$CH_COUNT"
    fi
  fi
done <<< "$AUDIO_DATA"

# ==========================================
# 2. STREAM MAP & FILTER GENERATION
# ==========================================
AUDIOMAPS=""
AUDIO_PARAMS="-c:a libopus -vbr on -mapping_family 1"
MAX_CHANNELS=2

if [ -n "$BEST_ENG_INDEX" ]; then
  echo "Selected English audio track (Stream #0:$BEST_ENG_INDEX, Channels: $BEST_ENG_CHCOUNT)"
  AUDIOMAPS="-map 0:$BEST_ENG_INDEX"
  [ "$BEST_ENG_CHCOUNT" -gt "$MAX_CHANNELS" ] && MAX_CHANNELS=$BEST_ENG_CHCOUNT
else
  echo "Warning: No English tracks found. Defaulting to stream 0:a:0"
  AUDIOMAPS="-map 0:a:0"
  
  BACKUP_CH=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$INPUT" | head -n1 | tr -d '[:space:]')
  if [ -n "$BACKUP_CH" ] && [[ "$BACKUP_CH" =~ ^[0-9]+$ ]] && [ "$BACKUP_CH" -gt 0 ]; then
    MAX_CHANNELS=$BACKUP_CH
  fi
fi

if [ -n "$BEST_POR_INDEX" ]; then
  echo "Selected Portuguese audio track (Stream #0:$BEST_POR_INDEX, Channels: $BEST_POR_CHCOUNT)"
  AUDIOMAPS="$AUDIOMAPS -map 0:$BEST_POR_INDEX"
  [ "$BEST_POR_CHCOUNT" -gt "$MAX_CHANNELS" ] && MAX_CHANNELS=$BEST_POR_CHCOUNT
fi

METADATA_TITLES=()
if [ "$MAX_CHANNELS" -gt 2 ]; then
  echo "-> Multi-channel surround audio detected ($MAX_CHANNELS ch max). Enforcing standard 5.1 layout pipeline..."
  AUDIO_PARAMS="$AUDIO_PARAMS -b:a 384k -af aformat=channel_layouts=5.1"
  
  METADATA_TITLES+=("-metadata:s:a:0" "title=Surround 5.1 (Opus)")
  if [ -n "$BEST_POR_INDEX" ]; then
    METADATA_TITLES+=("-metadata:s:a:1" "title=Surround 5.1 (Opus)")
  fi
else
  echo "-> Clean Stereo audio profiles matched. Optimizing for 2.0 channel encoding..."
  AUDIO_PARAMS="-c:a libopus -b:a 128k -vbr on -mapping_family 0"
  
  METADATA_TITLES+=("-metadata:s:a:0" "title=Stereo 2.0 (Opus)")
  if [ -n "$BEST_POR_INDEX" ]; then
    METADATA_TITLES+=("-metadata:s:a:1" "title=Stereo 2.0 (Opus)")
  fi
fi

# ==========================================
# 3. SUBTITLE SELECTION
# ==========================================
echo "Analyzing subtitle tracks..."

SUB_ENG=$(ffprobe -v error -analyzeduration 250M -probesize 250M \
  -select_streams s \
  -show_entries stream=index:stream_tags=language \
  -of csv=p=0 "$INPUT" | \
  awk -F',' '$2~/eng|english/{print $1; exit}' | tr -d '[:space:]')

SUB_POR=$(ffprobe -v error -analyzeduration 250M -probesize 250M \
  -select_streams s \
  -show_entries stream=index:stream_tags=language \
  -of csv=p=0 "$INPUT" | \
  awk -F',' '$2~/por|portuguese|pt/{print $1; exit}' | tr -d '[:space:]')

SUBMAPS=""
if [ -n "$SUB_ENG" ]; then
  echo "Found English subtitle (Stream #0:$SUB_ENG)"
  SUBMAPS="$SUBMAPS -map 0:$SUB_ENG"
fi
if [ -n "$SUB_POR" ]; then
  echo "Found Portuguese subtitle (Stream #0:$SUB_POR)"
  SUBMAPS="$SUBMAPS -map 0:$SUB_POR"
fi

# ==========================================
# 4. DETERMINING HARDWARE ACCELERATION ENGINE
# ==========================================
# Comprehensive format detection matrix to catch all legacy, rare, or problematic codecs
case "$VIDEO_CODEC" in
  h264|hevc|vp9)
    echo "-> Modern native format detected. Enabling full Intel QSV Hardware Decode + Encode."
    HWACCEL_FLAGS="-hwaccel qsv -hwaccel_output_format qsv -qsv_device /dev/dri/renderD128"
    ;;
  *)
    # Automatically intercepts vc1, mpeg2video, mpeg1video, wmv3, msmpeg4v3, rv40, flv1, or unknown codecs
    echo "-> Legacy, complex, or lesser-known format ($VIDEO_CODEC) detected. Using Software Decode -> Intel QSV AV1 Encode for stability."
    HWACCEL_FLAGS="-qsv_device /dev/dri/renderD128"
    ;;
esac

# ==========================================
# 5. EXECUTE TRANSCODE
# ==========================================
echo "Processing transcode (Intel Arc QSV AV1 Encoding)..."

ffmpeg $HWACCEL_FLAGS \
-analyzeduration 250M -probesize 250M -i "$INPUT" \
-map 0:v:0 \
$AUDIOMAPS \
$SUBMAPS \
-map_chapters 0 \
-metadata "title=$TITLE" \
"${METADATA_TITLES[@]}" \
-c:v av1_qsv \
-global_quality:v 16 \
-preset medium \
-extra_hw_frames 24 \
$AUDIO_PARAMS \
-c:s copy \
-max_interleave_delta 0 \
-y \
"$OUTPUT"