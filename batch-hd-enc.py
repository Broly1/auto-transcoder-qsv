#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
import re

# ============================================================
# CODEC QUALITY RANKING (higher = better, for auto-selection)
# ============================================================
CODEC_RANK = {
    "truehd": 10,
    "mlp": 10,  # Dolby TrueHD / Atmos
    "dts": 8,  # DTS-MA or DTS (ffprobe reports both as 'dts')
    "eac3": 6,  # Dolby Digital Plus / Atmos lossy
    "ac3": 4,  # Dolby Digital 5.1
    "aac": 3,
    "mp3": 2,
    "vorbis": 2,
    "opus": 2,
    "pcm_s24le": 9,
    "pcm_s16le": 7,  # Raw PCM (uncommon in remux but ranked high)
}

LANG_ALIASES = {
    "eng": ["eng", "en", "english"],
    "por": ["por", "pt", "ptbr", "pt-br", "portuguese", "portugues"],
}

# Bumped from 500M -> 2000M per user request (plenty of RAM available).
# Used consistently for ffprobe AND both ffmpeg passes below.
PROBE_SIZE = "2000M"
ANALYZE_DURATION = "2000M"


def codec_rank(codec_name):
    return CODEC_RANK.get((codec_name or "").lower(), 1)


def match_lang(lang_tag, target):
    """Check if a language tag matches a target language group."""
    return (lang_tag or "").lower() in LANG_ALIASES.get(target, [target])


def get_output_dir():
    """Prompt for an output directory, remembering the last one used."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    cache_path = os.path.join(script_dir, ".last_output_dir")

    last_used = ""
    if os.path.exists(cache_path):
        with open(cache_path) as f:
            last_used = f.read().strip()

    prompt = "Enter output directory"
    prompt += f" [{last_used}]: " if last_used else ": "

    user_input = input(prompt).strip().strip('"').strip("'")
    output_dir = user_input or last_used

    if not output_dir:
        print("[ERROR] No output directory provided.")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    with open(cache_path, "w") as f:
        f.write(output_dir)

    return output_dir


def probe_streams(input_file, stream_type, entries):
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-analyzeduration",
        ANALYZE_DURATION,
        "-probesize",
        PROBE_SIZE,
        "-select_streams",
        stream_type,
        "-show_entries",
        entries,
        "-of",
        "json",
        input_file,
    ]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode("utf-8")
        return json.loads(out).get("streams", [])
    except Exception as e:
        print(f"[WARNING] ffprobe failed for {stream_type}: {e}")
        return []


def auto_select_audio(audio_streams):
    eng_candidates = [s for s in audio_streams if match_lang(s.get("lang"), "eng")]
    por_candidates = [s for s in audio_streams if match_lang(s.get("lang"), "por")]

    def best(candidates):
        if not candidates:
            return None
        return max(candidates, key=lambda s: (codec_rank(s["codec"]), s["channels"]))

    selected = []
    best_eng = best(eng_candidates)
    best_por = best(por_candidates)

    if best_eng:
        selected.append(best_eng)
        print(
            f"  [AUTO] Best English : Stream #0:{best_eng['index']} "
            f'[{best_eng["channels"]}ch] ({best_eng["codec"]}) - "{best_eng["title"]}"'
        )
    else:
        print("  [AUTO] No English audio track found.")

    if best_por:
        selected.append(best_por)
        print(
            f"  [AUTO] Best PT-BR   : Stream #0:{best_por['index']} "
            f'[{best_por["channels"]}ch] ({best_por["codec"]}) - "{best_por["title"]}"'
        )
    else:
        print("  [AUTO] No Portuguese audio track found.")

    return selected


def auto_select_subtitles(sub_streams):
    skip_keywords = ["comment", "description", "director", "sdh+", "hearing impaired+"]
    selected = []
    seen_langs = {}

    def score_sub(s):
        title = (s.get("title") or "").lower()
        forced = 1 if "forced" in title else 0
        sdh = 1 if any(k in title for k in ["sdh", "hearing"]) else 0
        return (forced * 10) + sdh

    for target_lang in ["eng", "por"]:
        candidates = [
            s
            for s in sub_streams
            if match_lang(s.get("lang"), target_lang)
            and not any(k in (s.get("title") or "").lower() for k in skip_keywords)
        ]
        if not candidates:
            continue

        forced = [s for s in candidates if "forced" in (s.get("title") or "").lower()]
        full = [s for s in candidates if "forced" not in (s.get("title") or "").lower()]

        picks = []
        if forced:
            picks.append(max(forced, key=score_sub))
        if full:
            picks.append(max(full, key=score_sub))

        for s in picks:
            if s["index"] not in seen_langs:
                seen_langs[s["index"]] = True
                selected.append(s)
                print(
                    f"  [AUTO] Subtitle [{target_lang.upper()}]: Stream #0:{s['index']} "
                    f'({s["codec"]}) - "{s.get("title", "untitled")}"'
                )

    if not selected:
        print("  [AUTO] No matching subtitle tracks found.")

    return selected


def build_audio_args(selected_tracks):
    audio_args = []
    for i, track in enumerate(selected_tracks):
        ch = track["channels"]
        lang = track["lang"]
        idx = track["index"]
        is_surround = ch > 2
        lang_label = lang.upper()

        audio_args.extend(["-map", f"0:{idx}"])

        bitrate = "384k" if is_surround else "128k"
        ch_count = "6" if is_surround else "2"
        ch_label = "5.1" if is_surround else "2.0"
        audio_args.extend(
            [
                f"-c:a:{i}",
                "libopus",
                f"-b:a:{i}",
                bitrate,
                f"-ac:a:{i}",
                ch_count,
                f"-metadata:s:a:{i}",
                f"title={lang_label} Opus {ch_label}",
                f"-metadata:s:a:{i}",
                f"language={lang}",
            ]
        )
        print(f"  [AUDIO] Track {i + 1}: {lang_label} -> Opus {ch_label} @ {bitrate}")

    return audio_args


def run_ffmpeg_pass(cmd, label):
    print(f"\n  >>> {label}")
    try:
        subprocess.run(cmd, check=True)
        return True
    except subprocess.CalledProcessError as e:
        print(f"\n[ERROR] {label} failed with exit code: {e.returncode}")
        return False


def process_movie(input_file, input_dir, tmdb_token):
    """Processes a single movie file."""
    input_base = os.path.splitext(os.path.basename(input_file))[0]

    # Clean MakeMKV naming artifacts (t001, t002, etc. case-insensitively)
    movie_title = re.sub(r'[_.]t\d+', '', input_base, flags=re.IGNORECASE)
    movie_title = " ".join(movie_title.replace(".", " ").replace("_", " ").split())

    # Give each movie its own output folder
    movie_dir = os.path.join(input_dir, movie_title)
    os.makedirs(movie_dir, exist_ok=True)

    cover_file = os.path.join(movie_dir, f"{movie_title}.jpg")
    output_file = os.path.join(movie_dir, f"{movie_title}.mkv")

    # Temp intermediate files for the 3-pass pipeline (audio/video encoded
    # separately so the lossless audio decoder never has to compete with
    # SVT-AV1 for CPU time in the same process -- this is what was causing
    # TrueHD/DTS-HD MA tracks to mute partway through the movie)
    audio_temp_file = os.path.join(movie_dir, f".{movie_title}.audio_temp.mkv")
    video_temp_file = os.path.join(movie_dir, f".{movie_title}.video_temp.mkv")

    print("\n" + "=" * 60)
    print(f" PROCESSING: {movie_title}")
    print(f" Input File: {input_file}")
    print(f" Output Dir: {movie_dir}")
    print("=" * 60)

    # Skip if output already exists to prevent losing progress on huge batches
    if os.path.exists(output_file):
        print(f"[SKIP] Output file already exists: {output_file}")
        return

    # ============================================================
    # TMDB LOOKUP
    # ============================================================
    release_date = ""
    overview = ""

    if tmdb_token and tmdb_token != "PASTE_YOUR_LONG_ACCESS_TOKEN_HERE":
        print(f"\nSearching TMDb for: '{movie_title}'...")
        try:
            url_title = urllib.parse.quote(movie_title)
            url = (
                f"https://api.themoviedb.org/3/search/movie"
                f"?query={url_title}&include_adult=false&language=en-US&page=1"
            )
            req = urllib.request.Request(url)
            req.add_header("Authorization", f"Bearer {tmdb_token}")
            req.add_header("accept", "application/json")
            with urllib.request.urlopen(req, timeout=5) as response:
                data = json.loads(response.read().decode())
                if data.get("results"):
                    result = data["results"][0]
                    poster_path = result.get("poster_path")
                    release_date = result.get("release_date", "")
                    overview = result.get("overview", "")
                    if not os.path.exists(cover_file) and poster_path:
                        print("  Found cover art — downloading poster...")
                        poster_url = f"https://image.tmdb.org/t/p/w600_and_h900_bestv2{poster_path}"
                        urllib.request.urlretrieve(poster_url, cover_file)
                    if release_date:
                        print(f"  Release Date : {release_date}")
        except Exception as e:
            print(f"  [WARNING] TMDb lookup failed ({e}).")

    # ============================================================
    # PROBE AUDIO
    # ============================================================
    raw_audio = probe_streams(
        input_file, "a", "stream=index,codec_name,channels:stream_tags=language,title"
    )
    if not raw_audio:
        print(f"[ERROR] No audio tracks found for {movie_title}. Skipping.")
        return

    audio_streams = []
    for s in raw_audio:
        tags = s.get("tags", {})
        lang = (tags.get("language") or tags.get("LANGUAGE") or "unknown").lower()
        title = tags.get("title") or tags.get("TITLE") or f"Track {s['index']}"
        entry = {
            "index": str(s["index"]),
            "codec": s.get("codec_name", "unknown"),
            "channels": int(s.get("channels") or 2),
            "lang": lang,
            "title": title,
        }
        audio_streams.append(entry)

    selected_audio = auto_select_audio(audio_streams)
    if not selected_audio:
        print(f"[ERROR] No usable audio tracks selected for {movie_title}. Skipping.")
        return

    # ============================================================
    # PROBE SUBTITLES
    # ============================================================
    raw_subs = probe_streams(
        input_file, "s", "stream=index,codec_name:stream_tags=language,title"
    )
    sub_streams = []
    if raw_subs:
        for s in raw_subs:
            tags = s.get("tags", {})
            sub_streams.append(
                {
                    "index": str(s["index"]),
                    "codec": s.get("codec_name", "unknown"),
                    "lang": (tags.get("language") or "unknown").lower(),
                    "title": tags.get("title") or "",
                }
            )
        selected_subs = auto_select_subtitles(sub_streams)
    else:
        selected_subs = []

    # ============================================================
    # PASS 1/3: AUDIO + SUBTITLES ONLY
    # No video encode running here -- the lossless audio decoder
    # (TrueHD / DTS-HD MA) gets the CPU to itself instead of fighting
    # SVT-AV1 for scheduling, which is what caused the mid-movie mute.
    # ============================================================
    print("\n  --- PASS 1/3: Encoding audio + copying subtitles ---")

    audio_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-probesize",
        PROBE_SIZE,
        "-analyzeduration",
        ANALYZE_DURATION,
        "-i",
        input_file,
    ]

    audio_args = build_audio_args(selected_audio)
    audio_cmd.extend(audio_args)

    if selected_subs:
        for s in selected_subs:
            audio_cmd.extend(["-map", f"0:{s['index']}"])
        audio_cmd.extend(["-c:s", "copy"])
    else:
        audio_cmd.extend(["-map", "0:s?", "-c:s", "copy"])

    audio_cmd.extend(["-ignore_unknown", audio_temp_file])

    if not run_ffmpeg_pass(audio_cmd, "PASS 1 (audio + subtitles)"):
        return

    # ============================================================
    # PASS 2/3: VIDEO ONLY
    # No audio decode running here -- SVT-AV1 gets the CPU to itself.
    # ============================================================
    print("\n  --- PASS 2/3: Encoding video ---")

    video_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-probesize",
        PROBE_SIZE,
        "-analyzeduration",
        ANALYZE_DURATION,
        "-i",
        input_file,
        "-map",
        "0:v:0",
    ]

    color_info = probe_streams(input_file, "v:0", "stream=color_transfer")
    color_transfer = color_info[0].get("color_transfer", "") if color_info else ""

    svt_params = "tune=0"
    if color_transfer == "smpte2084":
        svt_params += ":enable-hdr=1:color-primaries=9:transfer-characteristics=16:matrix-coefficients=9"

    video_cmd.extend(
        [
            "-c:v",
            "libsvtav1",
            "-preset",
            "4",
            "-crf",
            "18",
            "-g",
            "240",
            "-pix_fmt",
            "yuv420p10le",
            "-svtav1-params",
            svt_params,
        ]
    )

    video_cmd.extend(["-ignore_unknown", video_temp_file])

    if not run_ffmpeg_pass(video_cmd, "PASS 2 (video)"):
        return

    # ============================================================
    # PASS 3/3: REMUX
    # Combine the already-encoded video + audio/subs, add cover art,
    # chapters, and metadata. Everything here is a stream copy, so
    # it's fast and never touches a codec.
    # ============================================================
    print("\n  --- PASS 3/3: Remuxing final file ---")

    remux_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-y",
        "-i",
        video_temp_file,
        "-i",
        audio_temp_file,
        "-i",
        input_file,  # only used for chapters + global metadata + attachment source
    ]

    if os.path.exists(cover_file):
        remux_cmd.extend(
            [
                "-attach",
                cover_file,
                "-metadata:s:t:0",
                "filename=cover.jpg",
                "-metadata:s:t:0",
                "mimetype=image/jpeg",
            ]
        )

    remux_cmd.extend(
        [
            "-map",
            "0:v",
            "-map",
            "1:a",
            "-map",
            "1:s?",
            "-c",
            "copy",
            "-map_metadata",
            "2",
            "-map_chapters",
            "2",
            "-metadata",
            f"title={movie_title}",
            "-metadata",
            f"DATE_RELEASED={release_date}",
            "-metadata",
            f"DESCRIPTION={overview}",
            "-metadata",
            "COMMENT=Encoded via SVT-AV1 Software",
            "-metadata:s:v:0",
            "language=eng",
            "-ignore_unknown",
            output_file,
        ]
    )

    if not run_ffmpeg_pass(remux_cmd, "PASS 3 (remux)"):
        return

    # Clean up temp files
    for f in (audio_temp_file, video_temp_file):
        try:
            os.remove(f)
        except OSError:
            pass

    print(f"[SUCCESS] Saved: {output_file}\n")


def main():
    if len(sys.argv) < 2:
        print("Error: Please drag and drop one or more video files onto this script.")
        sys.exit(1)

    # Get list of all dropped files
    input_files = sys.argv[1:]

    # Ask for output directory (remembers last-used path)
    target_output_dir = get_output_dir()

    # Optional TMDb configuration
    tmdb_token = ""
    print(f"Batch mode initialized. Found {len(input_files)} file(s) to process.")
    print(f"All outputs will land in: {target_output_dir}\n")

    for index, file_path in enumerate(input_files, start=1):
        print(f"Progress: Movie {index} of {len(input_files)}")
        if not os.path.exists(file_path):
            print(f"[ERROR] File does not exist, skipping: {file_path}")
            continue
        process_movie(file_path, target_output_dir, tmdb_token)

    print("\n" + "=" * 60)
    print(" ALL BATCH JOBS COMPLETE!")
    print("=" * 60)


if __name__ == "__main__":
    main()
