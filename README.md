# smart-remux

A smart Bash script that automates video transcoding to AV1. It scans your media files and system capabilities to dynamically choose the fastest, most efficient processing path—leveraging **Intel Arc QSV** hardware acceleration when available, and gracefully falling back to software or direct stream copying when appropriate.

## Features

*   **Smart Codec Scanning:** Automatically detects if a video already uses a modern codec (AV1 or HEVC). If it does, it performs a 100% lossless direct stream copy (`-c:v copy`) in seconds.
*   **Adaptive Hardware Acceleration:** Probes the system using a micro-test frame. If your Intel Arc GPU (`/dev/dri/renderD128`) is active, it runs blazing-fast hardware-accelerated transcoding (`av1_qsv`). 
*   **Reliable CPU Fallback:** If the GPU is busy or unsupported, it automatically pivots to high-quality software encoding via `libsvtav1`.
*   **Intelligent Stream Selection:** Automatically analyzes, scores, and tracks down the best English audio stream (prioritizing TrueHD, DTS, AC3, etc.) and native English subtitles.

## Requirements

*   **Linux OS** (Ubuntu, Debian, Fedora, Arch, etc.)
*   **FFmpeg** & **FFprobe** (compiled with `av1_qsv` and `libsvtav1` support)
*   An Intel GPU supporting QuickSync Video (like Intel Arc) mapped to `/dev/dri/renderD128` (Optional, for hardware acceleration)

## Installation & Setup

1. Clone or download the script:
   ```bash
   git clone [https://github.com/YOUR_USERNAME/smart-remux.git](https://github.com/YOUR_USERNAME/smart-remux.git)
   cd smart-remux