#!/usr/bin/env bash
set -euo pipefail

INPUT="/music"
FIXED="/fixed"
FAILED="/failed"
ALL="/all"
LOG="/config/import.log"
SUPPORTED_EXT="mp3|flac|m4a|ogg|opus|wma|aac"

mkdir -p "$FIXED" "$FAILED" "$ALL"

# ── Install inotify-tools if not present ─────────────────────────────────────
if ! command -v inotifywait &>/dev/null; then
  echo "[setup] Installing inotify-tools..."
  apt-get update -qq && apt-get install -y -qq inotify-tools 2>/dev/null \
    || apk add --no-cache inotify-tools 2>/dev/null \
    || { echo "ERROR: cannot install inotify-tools"; exit 1; }
fi

# ── Clean YouTube-style filenames ─────────────────────────────────────────────
clean_filename() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  local name
  name="$(basename "$file")"
  local ext="${name##*.}"
  local base="${name%.*}"

  base=$(echo "$base" | sed \
    -e 's/([^)]*Official[^)]*)//gI' \
    -e 's/([^)]*Video[^)]*)//gI' \
    -e 's/([^)]*Audio[^)]*)//gI' \
    -e 's/([^)]*Lyrics[^)]*)//gI' \
    -e 's/([^)]*HD[^)]*)//gI' \
    -e 's/([^)]*HQ[^)]*)//gI' \
    -e 's/([^)]*4K[^)]*)//gI' \
    -e 's/([^)]*ft\.[^)]*)//gI' \
    -e 's/([^)]*feat\.[^)]*)//gI' \
    -e 's/\[[^]]*\]//g' \
    -e 's/♫//g' -e 's/🎶//g' -e 's/⭐//g' -e 's/❤//g' \
    -e 's/[0-9]\+\+ YEARS//gI' \
    -e 's/ - [A-Z][^-]*Channel.*//I' \
    -e 's/  */ /g' \
    -e 's/^ //g' -e 's/ $//g')

  local newfile="$dir/$base.$ext"
  if [[ "$file" != "$newfile" ]]; then
    mv "$file" "$newfile"
    echo "$newfile"
  else
    echo "$file"
  fi
}

# ── Process a single file ─────────────────────────────────────────────────────
process_file() {
  local file="$1"
  local filename
  filename="$(basename "$file")"

  # Skip if not a supported audio format
  if ! echo "$filename" | grep -qiE "\.($SUPPORTED_EXT)$"; then
    return
  fi

  # Wait until the file is fully written (no size change for 2s)
  local prev_size=-1
  local curr_size
  while true; do
    curr_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    [[ "$curr_size" -eq "$prev_size" ]] && break
    prev_size=$curr_size
    sleep 2
  done

  # Clean YouTube-style filename before passing to beets
  file=$(clean_filename "$file")
  filename="$(basename "$file")"

  echo "[$(date '+%H:%M:%S')] Processing: $filename"

  # Count files in /fixed before import
  local before_count
  before_count=$(find "$FIXED" -type f | wc -l)

  # Touch log so -newer comparison works reliably
  touch "$LOG"

  # Run beets import on the single file
  beet import -q "$file" >> "$LOG" 2>&1 || true

  # Count files in /fixed after import
  local after_count
  after_count=$(find "$FIXED" -type f | wc -l)

  if [[ "$after_count" -gt "$before_count" ]]; then
    # Beets matched and moved it to /fixed — mirror to /all
    echo "  ✓ Tagged and moved to /fixed"
    find "$FIXED" -type f -newer "$LOG" | while read -r tagged; do
      local rel="${tagged#$FIXED/}"
      local dest="$ALL/$rel"
      mkdir -p "$(dirname "$dest")"
      cp "$tagged" "$dest"
    done
  else
    # Beets didn't move it — move to /failed manually
    local rel_path="${file#$INPUT/}"
    local failed_dest="$FAILED/$rel_path"
    local all_dest="$ALL/failed/$rel_path"
    mkdir -p "$(dirname "$failed_dest")" "$(dirname "$all_dest")"
    mv "$file" "$failed_dest"
    cp "$failed_dest" "$all_dest"
    echo "  ✗ No match — moved to /failed"
  fi

  # Remove now-empty subdirs from input
  find "$INPUT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# ── Process any files already in /input on startup ───────────────────────────
echo "[startup] Scanning for existing files in $INPUT..."
while IFS= read -r -d '' file; do
  process_file "$file"
done < <(find "$INPUT" -type f -print0)

# ── Watch for new files ───────────────────────────────────────────────────────
echo "[watch] Monitoring $INPUT for new files..."
inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$INPUT" \
| while IFS= read -r filepath; do
    process_file "$filepath"
  done
