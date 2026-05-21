#!/bin/bash

if [ -z "$1" ]; then
    echo "Error: Please drag and drop a video file."
    exit 1
fi

INPUT_FILE="$1"
INPUT_DIR=$(dirname "$INPUT_FILE")
INPUT_BASENAME=$(basename "$INPUT_FILE" .mkv)

# Clean up MakeMKV naming artifacts (like _t00, underscores, periods)
MOVIE_TITLE=$(echo "$INPUT_BASENAME" | sed 's/_[tT][0-9]*//g' | sed 's/[._]/ /g' | xargs)

COVER_FILE="$INPUT_DIR/COVER.jpg"
OUTPUT_FILE="$INPUT_DIR/${MOVIE_TITLE}_av1.mkv"

# ========================================================
# YOUR PERSONAL API KEYS (Keep this token secure!)
# ========================================================
TMDB_TOKEN="PASTE_YOUR_LONG_ACCESS_TOKEN_HERE"
# ========================================================

# Initialize fallback metadata variables
RELEASE_DATE=""
OVERVIEW=""

echo "Searching TMDb for: '$MOVIE_TITLE'..."

# Safely URL encode the title for curl
URL_TITLE=$(echo "$MOVIE_TITLE" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')

# 1. Fetch data using your validated bearer auth token
if [ ! -z "$TMDB_TOKEN" ] && [ "$TMDB_TOKEN" != "PASTE_YOUR_LONG_ACCESS_TOKEN_HERE" ]; then
    API_RESPONSE=$(curl -s --request GET \
      --url "https://api.themoviedb.org/3/search/movie?query=${URL_TITLE}&include_adult=false&language=en-US&page=1" \
      --header "Authorization: Bearer ${TMDB_TOKEN}" \
      --header "accept: application/json")
else
    echo "Warning: No TMDb credentials configured. Skipping online metadata lookup."
    API_RESPONSE=""
fi

if [ ! -z "$API_RESPONSE" ]; then
    # 2. Extract Data cleanly from JSON structures using JQ
    POSTER_PATH=$(echo "$API_RESPONSE" | jq -r '.results[0].poster_path // empty')
    RELEASE_DATE=$(echo "$API_RESPONSE" | jq -r '.results[0].release_date // empty')
    OVERVIEW=$(echo "$API_RESPONSE" | jq -r '.results[0].overview // empty')

    # 3. Handle Cover Art Download if file doesn't already exist
    if [ ! -f "$COVER_FILE" ] && [ ! -z "$POSTER_PATH" ] && [ "$POSTER_PATH" != "null" ]; then
        echo "Found cover art! Downloading high-res poster..."
        curl -s -o "$COVER_FILE" "https://image.tmdb.org/t/p/w600_and_h900_bestv2${POSTER_PATH}"
    fi
    
    # Format a nice output for the terminal log
    [ ! -z "$RELEASE_DATE" ] && echo "Found Release Date: $RELEASE_DATE"
    [ ! -z "$OVERVIEW" ] && echo "Found Synopsis: ${OVERVIEW:0:60}..."
fi

# Use Bash Arrays instead of strings for dynamic parameters
FFMPEG_ARGS=()

if [ ! -f "$COVER_FILE" ]; then
    echo "Proceeding without cover attachment..."
else
    echo "Cover art successfully prepared for attachment."
    FFMPEG_ARGS+=("-attach" "$COVER_FILE" "-metadata:s:t:0" "filename=cover.jpg" "-metadata:s:t:0" "mimetype=image/jpeg")
fi

# 4. Query the video height for dynamic encoding parameters
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$INPUT_FILE")

# Tightened CRFs for absolute visual transparency
if [ "$HEIGHT" -ge 2160 ]; then
    CRF=24
    echo "Detected 4K/UHD (${HEIGHT}p). Setting SVT-AV1 CRF to $CRF for pristine quality."
else
    CRF=22
    echo "Detected 1080p or lower (${HEIGHT}p). Setting SVT-AV1 CRF to $CRF for pristine quality."
fi

# ==========================================
# 5. DYNAMIC CODEC AND AUDIO TRACK PROBING
# ==========================================
echo "Analyzing video codec and audio tracks..."

VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$INPUT_FILE" | tr -d '[:space:]"\r\n' | tr '[:upper:]' '[:lower:]')

if [ -z "$VIDEO_CODEC" ]; then
  echo "[CRITICAL ERROR] Could not detect a valid video track. Aborting."
  exit 1
fi

echo "Detected Video Codec: $VIDEO_CODEC"

AUDIO_DATA=$(ffprobe -v error -analyzeduration 250M -probesize 250M \
  -select_streams a \
  -show_entries stream=index,codec_name:stream_tags=language \
  -of csv=p=0 "$INPUT_FILE")

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

  CH_COUNT=$(ffprobe -v error -select_streams "a:${INDEX}" -show_entries stream=channels -of csv=p=0 "$INPUT_FILE" | tr -d '[:space:]"\r\n')
  
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
# 6. STREAM MAP & FILTER GENERATION
# ==========================================
AUDIOMAPS=""
AUDIO_PARAMS=()
MAX_CHANNELS=2

if [ -n "$BEST_ENG_INDEX" ]; then
  echo "Selected English audio track (Stream #0:$BEST_ENG_INDEX, Channels: $BEST_ENG_CHCOUNT)"
  AUDIOMAPS="-map 0:$BEST_ENG_INDEX"
  [ "$BEST_ENG_CHCOUNT" -gt "$MAX_CHANNELS" ] && MAX_CHANNELS=$BEST_ENG_CHCOUNT
else
  echo "Warning: No English tracks found. Defaulting to stream 0:a:0"
  AUDIOMAPS="-map 0:a:0"
  
  BACKUP_CH=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$INPUT_FILE" | head -n1 | tr -d '[:space:]')
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
  echo "-> Multi-channel surround audio detected ($MAX_CHANNELS ch max). Enforcing downmix filter and 5.1 layout pipeline..."
  # -af "pan=5.1..." ensures clean channel-downmixing matrices if an 8-channel (7.1) layout is passed down.
  AUDIO_PARAMS=("-c:a" "libopus" "-b:a" "384k" "-vbr" "on" "-mapping_family" "1" "-af" "pan=5.1|FL=FL|FR=FR|FC=FC|LFE=LFE|BL=SL|BR=SR")
  
  METADATA_TITLES+=("-metadata:s:a:0" "title=Surround 5.1 (Opus)" "-metadata:s:a:0" "language=eng")
  if [ -n "$BEST_POR_INDEX" ]; then
    METADATA_TITLES+=("-metadata:s:a:1" "title=Surround 5.1 (Opus)" "-metadata:s:a:1" "language=por")
  fi
else
  echo "-> Clean Stereo audio profiles matched. Optimizing for 2.0 channel encoding..."
  AUDIO_PARAMS=("-c:a" "libopus" "-b:a" "128k" "-vbr" "on" "-mapping_family" "0" "-ac" "2")
  
  METADATA_TITLES+=("-metadata:s:a:0" "title=Stereo 2.0 (Opus)" "-metadata:s:a:0" "language=eng")
  if [ -n "$BEST_POR_INDEX" ]; then
    METADATA_TITLES+=("-metadata:s:a:1" "title=Stereo 2.0 (Opus)" "-metadata:s:a:1" "language=por")
  fi
fi

# ========================================================
# 6.5 DETECT HDR METADATA & BUILD BITSTREAM INJECTION
# ========================================================
echo "Checking for HDR10 master metadata..."

# Extract VUI Color properties
COLOR_PRIMARIES=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of csv=p=0 "$INPUT_FILE")
COLOR_TRANSFER=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$INPUT_FILE")
COLOR_SPACE=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_space -of csv=p=0 "$INPUT_FILE")

SVT_HDR_PARAMS="tune=0"

# Check if the video transfer characteristics match HDR10 (smpte2084 / PQ)
if [ "$COLOR_TRANSFER" = "smpte2084" ]; then
    echo "-> HDR10 content detected! Extracting mastering parameters..."
    
    # Enable internal HDR structure mapping inside SVT-AV1
    SVT_HDR_PARAMS="$SVT_HDR_PARAMS:enable-hdr=1"
    
    # Map friendly names back to standard enum IDs required by SVT-AV1
    [ "$COLOR_PRIMARIES" = "bt2020" ] && SVT_HDR_PARAMS="$SVT_HDR_PARAMS:color-primaries=9"
    [ "$COLOR_TRANSFER" = "smpte2084" ] && SVT_HDR_PARAMS="$SVT_HDR_PARAMS:transfer-characteristics=16"
    [ "$COLOR_SPACE" = "bt2020nc" ] && SVT_HDR_PARAMS="$SVT_HDR_PARAMS:matrix-coefficients=9"

    # Extract side data block using ffprobe
    SIDE_DATA=$(ffprobe -v error -select_streams v:0 -show_entries side_data -of json "$INPUT_FILE")
    
    # Parse Mastering Display Metadata (Color coordinates)
    MASTER_DISP=$(echo "$SIDE_DATA" | jq -r '.side_data_list[] | select(."side_data_type" == "Mastering display metadata") // empty')
    if [ -n "$MASTER_DISP" ]; then
        # Parse coordinates out to extract standard G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min) format
        G_X=$(echo "$MASTER_DISP" | jq -r '.green_x | split("/") | .[0]/.[1]')
        G_Y=$(echo "$MASTER_DISP" | jq -r '.green_y | split("/") | .[0]/.[1]')
        B_X=$(echo "$MASTER_DISP" | jq -r '.blue_x | split("/") | .[0]/.[1]')
        B_Y=$(echo "$MASTER_DISP" | jq -r '.blue_y | split("/") | .[0]/.[1]')
        R_X=$(echo "$MASTER_DISP" | jq -r '.red_x | split("/") | .[0]/.[1]')
        R_Y=$(echo "$MASTER_DISP" | jq -r '.red_y | split("/") | .[0]/.[1]')
        WP_X=$(echo "$MASTER_DISP" | jq -r '.white_point_x | split("/") | .[0]/.[1]')
        WP_Y=$(echo "$MASTER_DISP" | jq -r '.white_point_y | split("/") | .[0]/.[1]')
        L_MAX=$(echo "$MASTER_DISP" | jq -r '.max_luminance | split("/") | .[0]/.[1]')
        L_MIN=$(echo "$MASTER_DISP" | jq -r '.min_luminance | split("/") | .[0]/.[1]')
        
        SVT_HDR_PARAMS="$SVT_HDR_PARAMS:mastering-display=G($G_X,$G_Y)B($B_X,$B_Y)R($R_X,$R_Y)WP($WP_X,$WP_Y)L($L_MAX,$L_MIN)"
        echo "   Captured Mastering Display profile."
    fi

    # Parse Content Light Level Metadata (MaxCLL / MaxFALL)
    CLL_DATA=$(echo "$SIDE_DATA" | jq -r '.side_data_list[] | select(."side_data_type" == "Content light level metadata") // empty')
    if [ -n "$CLL_DATA" ]; then
        MAX_CLL=$(echo "$CLL_DATA" | jq -r '.max_content // 0')
        MAX_FALL=$(echo "$CLL_DATA" | jq -r '.max_average // 0')
        
        if [ "$MAX_CLL" -gt 0 ]; then
            SVT_HDR_PARAMS="$SVT_HDR_PARAMS:content-light=$MAX_CLL,$MAX_FALL"
            echo "   Captured Light Levels: MaxCLL=$MAX_CLL, MaxFALL=$MAX_FALL"
        fi
    fi
else
    echo "-> Standard Dynamic Range (SDR) detected. Applying standard profile configurations."
fi

# ========================================================
# 7. EXECUTE FFMPEG ENCODE LOOP
# ========================================================
echo "Starting final encode pass..."

# Fixed: -map 0:s? copies all subtitle tracks natively instead of just the first one.
ffmpeg -hide_banner \
-analyzeduration 2G \
-probesize 2G \
-i "$INPUT_FILE" \
"${FFMPEG_ARGS[@]}" \
-map 0:v:0 $AUDIOMAPS -map 0:s? -map 0:t? \
-map_metadata 0 \
-map_chapters 0 \
-metadata title="$MOVIE_TITLE" \
-metadata DATE_RELEASED="$RELEASE_DATE" \
-metadata DESCRIPTION="$OVERVIEW" \
-metadata COMMENT="Encoded via libsvtav1 (Software)" \
-metadata:s:v:0 language=eng \
"${METADATA_TITLES[@]}" \
-c:v libsvtav1 -preset 4 -crf $CRF -g 240 -pix_fmt yuv420p10le -svtav1-params "$SVT_HDR_PARAMS" \
"${AUDIO_PARAMS[@]}" \
-c:s copy \
"$OUTPUT_FILE"