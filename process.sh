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

# ── Startup verification ──────────────────────────────────────────────────────
STARTUP_CHECK_FAILED=0
STARTUP_CHECK_WARNED=0

startup_pass() {
  echo "  ✓ $1"
}

startup_warn() {
  echo "  ! $1"
  STARTUP_CHECK_WARNED=1
}

startup_fail() {
  echo "  ✗ $1"
  STARTUP_CHECK_FAILED=1
}

check_command() {
  local cmd="$1"
  local help="$2"

  if command -v "$cmd" &>/dev/null; then
    startup_pass "$cmd found: $(command -v "$cmd")"
  else
    startup_fail "$cmd missing - $help"
  fi
}

check_writable_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    startup_fail "$dir missing or not mounted"
    return
  fi

  if [[ ! -w "$dir" ]]; then
    startup_fail "$dir is not writable"
    return
  fi

  startup_pass "$dir exists and is writable"
}

check_beets_plugins() {
  local version_output
  version_output="$(beet version 2>&1 || true)"
  local plugins_line
  plugins_line="$(printf '%s\n' "$version_output" | awk '/^plugins:/ {print; exit}')"

  if printf '%s\n' "$version_output" | grep -q '^beets version '; then
    startup_pass "$(printf '%s\n' "$version_output" | awk '/^beets version / {print; exit}')"
  else
    startup_fail "beet version did not run successfully"
    printf '%s\n' "$version_output" | sed 's/^/    /'
    return
  fi

  if [[ -z "$plugins_line" ]]; then
    startup_fail "beet version did not report loaded plugins"
    return
  fi

  echo "  beet plugins: ${plugins_line#plugins: }"

  for plugin in chroma musicbrainz fromfilename; do
    if printf '%s\n' "$plugins_line" | grep -Eq "(^|[,[:space:]])${plugin}([,[:space:]]|$)"; then
      startup_pass "required Beets plugin loaded: $plugin"
    else
      startup_fail "required Beets plugin not loaded: $plugin"
    fi
  done
}

check_beets_config() {
  if [[ ! -f /config/config.yaml ]]; then
    startup_fail "/config/config.yaml missing"
    return
  fi
  startup_pass "/config/config.yaml mounted"

  local config_output
  config_output="$(beet config 2>&1 || true)"

  if printf '%s\n' "$config_output" | grep -q '^plugins:'; then
    startup_pass "beet config loaded"
  else
    startup_fail "beet config did not load correctly"
    printf '%s\n' "$config_output" | sed 's/^/    /'
    return
  fi

  for plugin in chroma musicbrainz fromfilename; do
    if printf '%s\n' "$config_output" | grep -Eq "^- ${plugin}$"; then
      startup_pass "config enables plugin: $plugin"
    else
      startup_fail "config does not enable plugin: $plugin"
    fi
  done

  if printf '%s\n' "$config_output" | grep -q '^    apikey: .\+'; then
    startup_pass "beet config has an AcoustID API key value"
  else
    startup_fail "beet config does not show an AcoustID API key value"
  fi
}

check_pyacoustid() {
  local output
  if output="$(python3 - <<'PY' 2>&1
import acoustid
print(getattr(acoustid, '__version__', 'unknown'))
PY
)"; then
    startup_pass "pyacoustid import OK: $output"
  else
    startup_fail "pyacoustid import failed"
    printf '%s\n' "$output" | sed 's/^/    /'
  fi
}

check_fpcalc_smoke_test() {
  local sample=""

  sample="$(find "$FAILED" "$INPUT" -type f 2>/dev/null | grep -Ei "\.($SUPPORTED_EXT)$" | head -n 1 || true)"
  if [[ -z "$sample" ]]; then
    startup_warn "no audio sample found in $FAILED or $INPUT for fpcalc smoke test"
    return
  fi

  echo "  smoke sample: $sample"

  local output status
  if command -v timeout &>/dev/null; then
    output="$(timeout 30 fpcalc "$sample" 2>&1)" || status=$?
  else
    output="$(fpcalc "$sample" 2>&1)" || status=$?
  fi
  status="${status:-0}"

  if [[ "$status" -eq 0 ]] && printf '%s\n' "$output" | grep -q '^FINGERPRINT='; then
    local duration
    duration="$(printf '%s\n' "$output" | awk -F= '/^DURATION=/ {print $2; exit}')"
    startup_pass "fpcalc smoke test produced a fingerprint${duration:+, duration ${duration}s}"
  else
    startup_fail "fpcalc smoke test failed for sample audio"
    printf '%s\n' "$output" | sed 's/^/    /'
  fi
}

startup_diagnostics() {
  echo "[startup] Full Beets/Chromaprint/AcoustID verification:"

  check_command beet "Beets must be installed in the image"
  check_command fpcalc "install chromaprint in the image"
  check_command ffmpeg "install ffmpeg so fpcalc can decode downloaded audio"
  check_command python3 "Python is required for pyacoustid"
  check_command inotifywait "inotify-tools is required for folder watching"

  check_writable_dir /config
  check_writable_dir "$INPUT"
  check_writable_dir "$FIXED"
  check_writable_dir "$FAILED"
  check_writable_dir "$ALL"

  if command -v beet &>/dev/null; then
    check_beets_plugins
    check_beets_config
  fi

  if command -v python3 &>/dev/null; then
    check_pyacoustid
  fi

  if command -v fpcalc &>/dev/null; then
    fpcalc -version 2>&1 | sed 's/^/  fpcalc version: /' || startup_fail "fpcalc version check failed"
  fi

  if command -v ffmpeg &>/dev/null; then
    ffmpeg -version 2>&1 | head -n 1 | sed 's/^/  ffmpeg version: /' || startup_fail "ffmpeg version check failed"
  fi

  if [[ -z "${ACOUSTID_API_KEY:-}" ]]; then
    startup_fail "ACOUSTID_API_KEY is missing"
  else
    startup_pass "ACOUSTID_API_KEY is set"
  fi

  if command -v fpcalc &>/dev/null; then
    check_fpcalc_smoke_test
  fi

  if [[ "$STARTUP_CHECK_FAILED" -ne 0 ]]; then
    echo "[startup] ERROR: one or more required startup checks failed; refusing to process files."
    echo "[startup] Fix the failed checks above, rebuild/recreate the container, and restart."
    exit 1
  fi

  if [[ "$STARTUP_CHECK_WARNED" -ne 0 ]]; then
    echo "[startup] Startup checks passed with warnings."
  else
    echo "[startup] All startup checks passed."
  fi
}

startup_diagnostics

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
  # -v is intentional: it writes the real Beets/chroma reason to /config/import.log.
  beet -v import -s -q --incremental-skip-later "$file" >> "$LOG" 2>&1 || true
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
    echo "  → No automatic import; retrying with cleaned filename: $filename"

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
      echo "  ✗ Still no automatic import — left in /failed for future retries"
    else
      echo "  ✗ No automatic import — moved to /failed"
    fi
    echo "    Check $LOG for the verbose Beets/chroma reason."
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
