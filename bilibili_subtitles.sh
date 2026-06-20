#!/usr/bin/env bash
# Download all subtitles from a Bilibili video collection and convert to plain text files.
# Usage: ./bilibili_subtitles.sh [URL] [OUTPUT_DIR]
#   URL        - Bilibili video/collection URL (default: https://www.bilibili.com/video/BV12v4y1y7uV/)
#   OUTPUT_DIR - Directory to save text files (default: ./bilibili_subtitles_output)
#
# Requirements: yt-dlp  (pip install yt-dlp)
# Optional:     ffmpeg   (for subtitle format conversion if needed)

set -euo pipefail

URL="${1:-https://www.bilibili.com/video/BV12v4y1y7uV/}"
OUTPUT_DIR="${2:-./bilibili_subtitles_output}"
COOKIES_FILE="${BILIBILI_COOKIES:-}"

mkdir -p "$OUTPUT_DIR"

echo "=== Bilibili Subtitle Downloader ==="
echo "URL        : $URL"
echo "Output dir : $OUTPUT_DIR"
if [[ -n "$COOKIES_FILE" ]]; then
    echo "Cookies    : $COOKIES_FILE"
fi
echo ""

# Build yt-dlp base options
YT_OPTS=(
    --no-check-certificate
    --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    --add-header "Referer:https://www.bilibili.com"
    --extractor-args "bilibili:prefer_multi_p=true"
    --retries 5
    --sleep-interval 2
    --max-sleep-interval 6
)

# Add cookies if available (improves access to restricted content)
if [[ -n "$COOKIES_FILE" && -f "$COOKIES_FILE" ]]; then
    YT_OPTS+=(--cookies "$COOKIES_FILE")
fi

# Step 1: List all episodes in the collection
echo "==> Fetching playlist/collection info..."
mapfile -t ENTRIES < <(
    yt-dlp "${YT_OPTS[@]}" \
        --flat-playlist \
        --print "%(id)s\t%(title)s\t%(webpage_url)s" \
        "$URL" 2>&1 | grep -v '^\[' || true
)

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
    echo "No entries found. Trying as a single video..."
    ENTRIES=("single")
fi

echo "Found ${#ENTRIES[@]} episode(s)."
echo ""

# Step 2: Download subtitles for each episode
SUCCESS=0
SKIPPED=0
FAILED=0

download_and_convert() {
    local video_url="$1"
    local safe_title="$2"
    local subtitle_dir="$OUTPUT_DIR/raw_subs"
    mkdir -p "$subtitle_dir"

    # Try to download all available subtitles (auto-generated + manual)
    # --write-sub        : download available subtitles
    # --write-auto-sub   : download auto-generated subtitles as fallback
    # --sub-langs all    : all available languages
    # --skip-download    : don't download the video
    # --convert-subs srt : convert to SRT for easy text extraction
    yt-dlp "${YT_OPTS[@]}" \
        --write-sub \
        --write-auto-sub \
        --sub-langs "all" \
        --skip-download \
        --convert-subs srt \
        --output "$subtitle_dir/${safe_title}.%(ext)s" \
        "$video_url" 2>&1 || return 1

    # Find downloaded subtitle files for this video
    local found_any=false
    while IFS= read -r -d '' srt_file; do
        found_any=true
        # Strip SRT timing/index lines to produce plain text
        local lang
        lang=$(basename "$srt_file" | sed 's/.*\.\([a-z-]*\)\.srt$/\1/')
        local txt_file="$OUTPUT_DIR/${safe_title}.${lang}.txt"

        # Convert SRT → plain text (remove index numbers, timestamps, blank lines)
        sed -E \
            -e '/^[0-9]+$/d' \
            -e '/^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> /d' \
            -e '/^$/d' \
            -e 's/<[^>]*>//g' \
            "$srt_file" \
        | awk '!seen[$0]++' \
        > "$txt_file"

        echo "  [OK] $txt_file"
    done < <(find "$subtitle_dir" -name "${safe_title}*.srt" -print0 2>/dev/null)

    $found_any && return 0 || return 1
}

if [[ "${ENTRIES[0]}" == "single" ]]; then
    safe_title=$(yt-dlp "${YT_OPTS[@]}" --skip-download --print "%(title)s" "$URL" 2>/dev/null \
        | tr '/:*?"<>|\\' '_' | cut -c1-100)
    safe_title="${safe_title:-video}"
    echo "Processing: $safe_title"
    if download_and_convert "$URL" "$safe_title"; then
        ((SUCCESS++))
    else
        echo "  [SKIP] No subtitles found for: $safe_title"
        ((SKIPPED++))
    fi
else
    for entry in "${ENTRIES[@]}"; do
        IFS=$'\t' read -r vid_id title video_url <<< "$entry"
        safe_title=$(echo "${title:-$vid_id}" | tr '/:*?"<>|\\' '_' | cut -c1-100)
        echo "Processing: $safe_title"

        if download_and_convert "$video_url" "$safe_title"; then
            ((SUCCESS++))
        else
            echo "  [SKIP] No subtitles found"
            ((SKIPPED++))
        fi

        # Polite delay between requests
        sleep 2
    done
fi

# Cleanup raw subtitle files
rm -rf "$OUTPUT_DIR/raw_subs"

echo ""
echo "=== Done ==="
echo "  Success : $SUCCESS episode(s) with subtitles"
echo "  Skipped : $SKIPPED episode(s) without subtitles"
echo "  Failed  : $FAILED episode(s) with errors"
echo "  Output  : $OUTPUT_DIR/"
