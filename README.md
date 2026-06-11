# mkv-encode

A Python script for remuxing and re-encoding MKV video files. Probes audio/subtitle tracks, auto-selects the best English and PT-BR streams, fetches metadata from TMDb, and encodes to one of three quality profiles using FFmpeg.

---

## Requirements

- Python 3.6+
- [FFmpeg](https://ffmpeg.org/download.html) (with `ffprobe`) in your `PATH`
- Intel GPU with QSV support (required for the 4K profile only)
- A [TMDb API token](https://developer.themoviedb.org/docs/getting-started) (optional — enables metadata and cover art download)

---

## Setup

1. Clone or download the script.
2. Open the script and paste your TMDb Bearer token into the `tmdb_token` variable (line ~75):
   ```python
   tmdb_token = "your_token_here"
   ```
3. Leave it blank to skip TMDb lookups.

---

## Usage

Run the script and pass your input MKV as the first argument:

```bash
python mkv_encode.py /path/to/movie.mkv
```

On Windows, you can also drag and drop the MKV file onto the script in File Explorer.

The script will walk you through three interactive steps:

### Step 1 — Choose a profile

| # | Profile | Suffix | Video codec | Audio codec |
|---|---------|--------|-------------|-------------|
| 1 | 4K UHD | `_4k.mkv` | HEVC (QSV hardware) | AAC |
| 2 | HD 1080p | `_HD.mkv` | SVT-AV1 (software) | Opus |
| 3 | SD 480p | `_SD.mkv` | SVT-AV1 (software) | Opus |

### Step 2 — Audio track selection

The script scans all audio streams and auto-selects the highest-quality English and PT-BR tracks, ranked by codec quality and channel count. You can review the selection and override it by typing stream numbers (e.g. `1 3`) when prompted, or press Enter to accept.

**Codec quality ranking** (highest to lowest): TrueHD/MLP → PCM 24-bit → DTS → PCM 16-bit → EAC3 → AC3 → AAC → MP3/Vorbis/Opus

### Step 3 — Subtitle track selection

English and PT-BR subtitle tracks are auto-selected. Forced tracks are preferred; SDH/full tracks are included when available. Commentary and description tracks are skipped.

### Confirm and encode

A summary is shown before encoding begins. Press `y` to start or `n` to abort.

---

## Output

The encoded file is saved to the same directory as the input file, named `<Movie Title><suffix>.mkv`. For example:

```
/movies/The Matrix_HD.mkv
```

The output file includes:

- Re-encoded video (HDR parameters preserved automatically if detected)
- Selected audio tracks, re-encoded to AAC (4K) or Opus (HD/SD)
- Selected subtitle tracks (copied as-is)
- Chapters and attachments from the source
- TMDb metadata (title, release date, synopsis) if a token is configured
- Cover art attachment (`cover.jpg`) if found in the source directory or downloaded from TMDb

---

## Notes

- **4K profile** requires an Intel GPU with QSV support. It uses `hevc_qsv` for hardware-accelerated encoding.
- **HD/SD profiles** use `libsvtav1` (software). Encoding is CPU-intensive and may take a while for long files.
- HDR content (PQ/SMPTE 2084 transfer function) is detected automatically and the appropriate color metadata is passed to the encoder.
- If a `COVER.jpg` file already exists in the source directory, it is used as cover art and the TMDb poster is not downloaded.
- MakeMKV naming artifacts (`_t00`, `_T00`) are cleaned from the output filename automatically.
