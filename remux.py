#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

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


def codec_rank(codec_name):
    return CODEC_RANK.get((codec_name or "").lower(), 1)


def match_lang(lang_tag, target):
    """Check if a language tag matches a target language group."""
    return (lang_tag or "").lower() in LANG_ALIASES.get(target, [target])


def probe_streams(input_file, stream_type, entries):
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-analyzeduration",
        "500M",
        "-probesize",
        "500M",
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
    """
    Auto-select best English and best PT-BR track.
    Prefers highest codec rank, then most channels.
    Returns list of stream dicts for selected tracks.
    """
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
    """
    Auto-select English and PT-BR subtitle tracks.
    Prefers Forced, then SDH/Full, skipping commentary/description tracks.
    Returns list of stream index strings.
    """
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

        # Pick forced track if available, otherwise best scored
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


def build_audio_args(selected_tracks, is_4k):
    """
    Build ffmpeg audio map + codec args.
    4K  -> AAC (avoids Opus/TrueHD mux issues in 4K MKV containers)
    HD/SD -> Opus
    """
    audio_args = []
    for i, track in enumerate(selected_tracks):
        ch = track["channels"]
        lang = track["lang"]
        codec = track["codec"]
        idx = track["index"]
        is_surround = ch > 2
        lang_label = lang.upper()

        audio_args.extend(["-map", f"0:{idx}"])

        if is_4k:
            # AAC for 4K — safe with all container/player combos
            bitrate = "448k" if is_surround else "256k"
            ch_count = "6" if is_surround else "2"
            ch_label = "5.1" if is_surround else "2.0"
            audio_args.extend(
                [
                    f"-c:a:{i}",
                    "aac",
                    f"-b:a:{i}",
                    bitrate,
                    f"-ac:a:{i}",
                    ch_count,
                    f"-metadata:s:a:{i}",
                    f"title={lang_label} AAC {ch_label}",
                    f"-metadata:s:a:{i}",
                    f"language={lang}",
                ]
            )
            print(
                f"  [AUDIO] Track {i + 1}: {lang_label} -> AAC {ch_label} @ {bitrate}"
            )
        else:
            # Opus for HD/SD
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
            print(
                f"  [AUDIO] Track {i + 1}: {lang_label} -> Opus {ch_label} @ {bitrate}"
            )

    return audio_args


def main():
    if len(sys.argv) < 2:
        print("Error: Please drag and drop a video file onto this script.")
        sys.exit(1)

    input_file = sys.argv[1]
    input_dir = os.path.dirname(input_file)
    input_base = os.path.splitext(os.path.basename(input_file))[0]

    # Clean MakeMKV naming artifacts
    movie_title = input_base.replace("_t00", "").replace("_T00", "")
    movie_title = " ".join(movie_title.replace(".", " ").replace("_", " ").split())
    cover_file = os.path.join(input_dir, "COVER.jpg")

    # ============================================================
    # TMDB LOOKUP
    # ============================================================
    tmdb_token = ""  # Paste your TMDb Bearer token here
    release_date = ""
    overview = ""

    print(f"\nSearching TMDb for: '{movie_title}'...")
    if tmdb_token and tmdb_token != "PASTE_YOUR_LONG_ACCESS_TOKEN_HERE":
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
                    if overview:
                        print(f"  Synopsis     : {overview[:80]}...")
        except Exception as e:
            print(f"  [WARNING] TMDb lookup failed ({e}). Proceeding without metadata.")

    # ============================================================
    # STEP 1: CHOOSE PROFILE
    # ============================================================
    print("\n--------------------------------------------------")
    print(" Select Output Profile:")
    print("   1) 4K UHD  (_4k.mkv  — HEVC QSV hardware, AAC audio)")
    print("   2) HD 1080p (_HD.mkv  — SVT-AV1 software, Opus audio)")
    print("   3) SD 480p  (_SD.mkv  — SVT-AV1 software, Opus audio)")
    print("--------------------------------------------------")
    while True:
        video_choice = input("Choose option (1-3): ").strip()
        if video_choice in ["1", "2", "3"]:
            break
        print("Invalid choice. Please enter 1, 2, or 3.")

    is_4k = video_choice == "1"
    suffix = "_4k" if video_choice == "1" else ("_HD" if video_choice == "2" else "_SD")
    output_file = os.path.join(input_dir, f"{movie_title}{suffix}.mkv")

    # ============================================================
    # STEP 2: PROBE AUDIO STREAMS
    # ============================================================
    print("\n--------------------------------------------------")
    print(" Scanning audio tracks...")
    print("--------------------------------------------------")

    raw_audio = probe_streams(
        input_file, "a", "stream=index,codec_name,channels:stream_tags=language,title"
    )
    if not raw_audio:
        print("[CRITICAL] No audio tracks found. Aborting.")
        sys.exit(1)

    audio_streams = []
    print(" All available audio tracks:")
    for s in raw_audio:
        tags = s.get("tags", {})
        lang = (tags.get("language") or tags.get("LANGUAGE") or "unknown").lower()
        title = tags.get("title") or tags.get("TITLE") or f"Track {s['index']}"
        codec = s.get("codec_name", "unknown")
        channels = int(s.get("channels") or 2)
        entry = {
            "index": str(s["index"]),
            "codec": codec,
            "channels": channels,
            "lang": lang,
            "title": title,
        }
        audio_streams.append(entry)
        print(
            f"   Stream #0:{s['index']} [{lang.upper()}] [{channels}ch] "
            f'({codec}) - "{title}"'
        )

    print("\n Auto-selecting best English + PT-BR tracks...")
    selected_audio = auto_select_audio(audio_streams)

    if not selected_audio:
        print("[CRITICAL] No usable audio tracks selected. Aborting.")
        sys.exit(1)

    print(
        "\n Override auto-selection? (press Enter to accept, or type track numbers e.g. '1 3')"
    )
    override = input(" Selection [auto]: ").strip()
    if override:
        manual = []
        for tok in override.split():
            if tok.isdigit():
                i = int(tok) - 1
                if 0 <= i < len(audio_streams):
                    manual.append(audio_streams[i])
        if manual:
            selected_audio = manual
            print(f" Using manual selection: {[s['index'] for s in manual]}")

    # ============================================================
    # STEP 3: PROBE SUBTITLE STREAMS
    # ============================================================
    print("\n--------------------------------------------------")
    print(" Scanning subtitle tracks...")
    print("--------------------------------------------------")

    raw_subs = probe_streams(
        input_file, "s", "stream=index,codec_name:stream_tags=language,title"
    )

    sub_streams = []
    if raw_subs:
        print(" All available subtitle tracks:")
        for s in raw_subs:
            tags = s.get("tags", {})
            lang = (tags.get("language") or tags.get("LANGUAGE") or "unknown").lower()
            title = tags.get("title") or tags.get("TITLE") or ""
            codec = s.get("codec_name", "unknown")
            entry = {
                "index": str(s["index"]),
                "codec": codec,
                "lang": lang,
                "title": title,
            }
            sub_streams.append(entry)
            print(f'   Stream #0:{s["index"]} [{lang.upper()}] ({codec}) - "{title}"')

        print("\n Auto-selecting English + PT-BR subtitles...")
        selected_subs = auto_select_subtitles(sub_streams)
    else:
        print(" No subtitle tracks found.")
        selected_subs = []

    # ============================================================
    # BUILD FFMPEG COMMAND
    # ============================================================
    print("\n--------------------------------------------------")
    print(f" Building FFmpeg command for: {suffix} profile")
    print("--------------------------------------------------")

    cmd = ["ffmpeg", "-hide_banner", "-probesize", "2G", "-analyzeduration", "2G"]

    if is_4k:
        cmd.extend(["-hwaccel", "qsv", "-hwaccel_output_format", "qsv"])

    cmd.extend(["-i", input_file])

    if os.path.exists(cover_file):
        cmd.extend(
            [
                "-attach",
                cover_file,
                "-metadata:s:t:0",
                "filename=cover.jpg",
                "-metadata:s:t:0",
                "mimetype=image/jpeg",
            ]
        )

    # Video map + encode
    cmd.extend(["-map", "0:v:0"])

    if is_4k:
        print(" Video: HEVC QSV hardware (4K HDR)")
        cmd.extend(
            [
                "-c:v",
                "hevc_qsv",
                "-preset",
                "veryslow",
                "-global_quality",
                "18",
                "-look_ahead",
                "1",
                "-pix_fmt",
                "qsv",
                "-color_primaries",
                "bt2020",
                "-color_trc",
                "smpte2084",
                "-colorspace",
                "bt2020nc",
            ]
        )
    else:
        # Detect HDR for SVT-AV1 params
        color_info = probe_streams(
            input_file, "v:0", "stream=color_transfer,color_primaries,color_space"
        )
        color_transfer = ""
        if color_info:
            color_transfer = color_info[0].get("color_transfer", "")

        svt_params = "tune=0"
        if color_transfer == "smpte2084":
            print(" Video: SVT-AV1 software (HDR detected — enabling HDR params)")
            svt_params += ":enable-hdr=1:color-primaries=9:transfer-characteristics=16:matrix-coefficients=9"
        else:
            print(" Video: SVT-AV1 software (SDR)")

        crf = "18" if video_choice == "2" else "24"
        cmd.extend(
            [
                "-c:v",
                "libsvtav1",
                "-preset",
                "4",
                "-crf",
                crf,
                "-g",
                "240",
                "-pix_fmt",
                "yuv420p10le",
                "-svtav1-params",
                svt_params,
            ]
        )

    # Audio
    print("\n Audio encoding:")
    audio_args = build_audio_args(selected_audio, is_4k)
    cmd.extend(audio_args)

    # Subtitles — map only selected tracks
    if selected_subs:
        for s in selected_subs:
            cmd.extend(["-map", f"0:{s['index']}"])
        cmd.extend(["-c:s", "copy"])
    else:
        # Fall back: copy all subs if none auto-selected
        cmd.extend(["-map", "0:s?", "-c:s", "copy"])

    # Chapters, attachments, global metadata
    comment_text = "HEVC QSV Hardware 4K" if is_4k else "SVT-AV1 Software"
    cmd.extend(
        [
            "-map",
            "0:t?",
            "-map_metadata",
            "0",
            "-map_chapters",
            "0",
            "-metadata",
            f"title={movie_title}",
            "-metadata",
            f"DATE_RELEASED={release_date}",
            "-metadata",
            f"DESCRIPTION={overview}",
            "-metadata",
            f"COMMENT=Encoded via {comment_text}",
            "-metadata:s:v:0",
            "language=eng",
            "-ignore_unknown",
            output_file,
        ]
    )

    # ============================================================
    # CONFIRM + RUN
    # ============================================================
    print("\n--------------------------------------------------")
    print(f" Output file : {output_file}")
    print(
        f" Audio tracks: {len(selected_audio)} | Subtitle tracks: {len(selected_subs)}"
    )
    print("--------------------------------------------------")
    confirm = input(" Start encode? (y/n): ").strip().lower()
    if confirm != "y":
        print("Aborted.")
        sys.exit(0)

    print("\nStarting FFmpeg...\n")
    try:
        subprocess.run(cmd, check=True)
        print(f"\nDone! Saved to: {output_file}")
    except subprocess.CalledProcessError as e:
        print(f"\n[ERROR] FFmpeg failed with exit code: {e.returncode}")
        sys.exit(1)


if __name__ == "__main__":
    main()
