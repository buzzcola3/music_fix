#!/usr/bin/env bash
set -euo pipefail

INPUT="/music"
FIXED="/fixed"
FAILED="/failed"
ALL="/all"
LOG="/config/import.log"
SUPPORTED_EXT="mp3|flac|m4a|ogg|opus|wma|aac"

mkdir -p "$FIXED" "$FAILED" "$ALL"

# ── Install runtime helpers if not present ────────────────────────────────────
if ! command -v inotifywait &>/dev/null; then
  echo "[setup] Installing inotify-tools..."
  apt-get update -qq && apt-get install -y -qq inotify-tools 2>/dev/null \
    || apk add --no-cache inotify-tools 2>/dev/null \
    || { echo "ERROR: cannot install inotify-tools"; exit 1; }
fi

# The Docker image should provide fpcalc via chromaprint. Warn loudly if it is
# missing because Beets' chroma plugin cannot fingerprint audio without it.
if ! command -v fpcalc &>/dev/null; then
  echo "WARNING: fpcalc was not found. Fingerprint matching is disabled."
  echo "         Rebuild the container image so chromaprint is installed."
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

  # Avoid renaming to an empty basename if a noisy filename is stripped entirely.
  if [[ -z "$base" ]]; then
    echo "$file"
    return
  fi

  local newfile="$dir/$base.$ext"
  if [[ "$file" != "$newfile" ]]; then
    mv "$file" "$newfile"
    echo "$newfile"
  else
    echo "$file"
  fi
}

import_with_beets() {
  local file="$1"

  # These downloads are individual tracks, not albums. Singleton mode lets Beets
  # match the track recording directly with chroma/AcoustID instead of treating
  # each file as a one-track album candidate. --incremental-skip-later keeps
  # skipped files retryable on future runs after config/dependency changes.
  beet import -s -q --incremental-skip-later "$file" >> "$LOG" 2>&1 || true
}

fixed_count() {
  find "$FIXED" -type f | wc -l
}

mirror_new_fixed_files() {
  find "$FIXED" -type f -newer "$LOG" | while read -r tagged; do
    local rel="${tagged#$FIXED/}"
    local dest="$ALL/$rel"
    mkdir -p "$(dirname "$dest")"
    cp "$tagged" "$dest"
  done
}

move_to_failed() {
  local file="$1"
  local source_root="${2:-$INPUT}"
  local rel_path="${file#$source_root/}"
  local failed_dest="$FAILED/$rel_path"
  local all_dest="$ALL/failed/$rel_path"

  mkdir -p "$(dirname "$failed_dest")" "$(dirname "$all_dest")"

  # If this file was already in /failed during a startup re-run, keep it there
  # instead of trying to move it onto itself. Refresh the /all/failed mirror.
  if [[ "$file" == "$failed_dest" ]]; then
    cp "$file" "$all_dest"
    return
  fi

  mv "$file" "$failed_dest"
  cp "$failed_dest" "$all_dest"
}

cleanup_empty_dirs() {
  find "$INPUT" "$FAILED" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# ── Process a single file ─────────────────────────────────────────────────────
process_file() {
  local file="$1"
  local source_root="${2:-$INPUT}"
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

  filename="$(basename "$file")"
  echo "[$(date '+%H:%M:%S')] Processing: $filename"

  if [[ "$source_root" == "$FAILED" ]]; then
    echo "  → Re-running analysis from /failed"
  fi

  # Touch log so -newer comparison works reliably
  touch "$LOG"

  # First pass: let Beets identify the actual audio using chroma/AcoustID before
  # altering the filename. This avoids making filename text the primary signal.
  local before_count
  before_count=$(fixed_count)
  echo "  → Trying fingerprint-based singleton Beets import"
  import_with_beets "$file"

  local after_count
  after_count=$(fixed_count)
  if [[ "$after_count" -gt "$before_count" ]]; then
    echo "  ✓ Fingerprint/metadata match tagged and moved to /fixed"
    mirror_new_fixed_files
    cleanup_empty_dirs
    return
  fi

  # Second pass: clean noisy YouTube-style names and retry. This is only a
  # fallback for files that AcoustID/MusicBrainz cannot confidently identify.
  if [[ -f "$file" ]]; then
    file=$(clean_filename "$file")
    filename="$(basename "$file")"
    echo "  → No fingerprint match; retrying with cleaned filename: $filename"

    before_count=$(fixed_count)
    import_with_beets "$file"
    after_count=$(fixed_count)

    if [[ "$after_count" -gt "$before_count" ]]; then
      echo "  ✓ Filename fallback tagged and moved to /fixed"
      mirror_new_fixed_files
      cleanup_empty_dirs
      return
    fi
  fi

  # Beets did not move it — move new input files to /failed, or leave existing
  # failed files in place so they can be retried again on the next container run.
  if [[ -f "$file" ]]; then
    move_to_failed "$file" "$source_root"
    if [[ "$source_root" == "$FAILED" ]]; then
      echo "  ✗ Still no match — left in /failed for future retries"
    else
      echo "  ✗ No match — moved to /failed"
    fi
  else
    echo "  ✗ No match and source file is missing — check $LOG"
  fi

  cleanup_empty_dirs
}

process_existing_tree() {
  local root="$1"
  local label="$2"

  if [[ ! -d "$root" ]]; then
    return
  fi

  echo "[startup] Scanning for existing files in $label..."
  while IFS= read -r -d '' file; do
    process_file "$file" "$root"
  done < <(find "$root" -type f -print0)
}

# ── Process files already present on startup ──────────────────────────────────
process_existing_tree "$INPUT" "$INPUT"
process_existing_tree "$FAILED" "$FAILED"

# ── Watch for new files ───────────────────────────────────────────────────────
echo "[watch] Monitoring $INPUT for new files..."
inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$INPUT" \
| while IFS= read -r filepath; do
    process_file "$filepath" "$INPUT"
  done
