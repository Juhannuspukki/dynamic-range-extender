#!/usr/bin/env zsh
#
# extender.zsh — embed a synthetic gain map in a photo so highlights
# glow brighter on HDR-capable displays, iPhone-style. This does NOT
# recover real extra dynamic range (no bracketing/stacking) — it just
# tells compatible displays how much brighter the highlight pixels are
# allowed to go, same trick Apple/Android "Adaptive"/"Ultra" HDR photos use.
#
# Pipeline:
# 1. ImageMagick builds an SDR base + a grayscale gain-map JPEG.
# 2. ultrahdr_app assembles them into an ISO gain-map JPEG.
# 3. toGainMapHDR (https://github.com/chemharuka/toGainMapHDR) converts
#    that ISO gain-map JPEG into a proper Apple/ISO gain-map HEIC.
#
# Accepts either a single image file or a directory. When given a
# directory, every .jpg/.jpeg/.tif/.tiff inside is processed; add -r
# to also descend into subdirectories.
#
# Requires: brew install imagemagick libultrahdr exiftool
# toGainMapHDR binary on PATH, or set $TOGAINMAPHDR to its path
# (download from https://github.com/chemharuka/toGainMapHDR/releases)

set -euo pipefail
setopt extendedglob

SCRIPT_DIR="${0:A:h}"

# ---------------------------------------------------------------------------
# Logging / progress helpers
# ---------------------------------------------------------------------------
VERBOSE=0
LOGDIR="$SCRIPT_DIR/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/extender-$(date '+%Y-%m-%d_%H-%M-%S').txt"
: > "$LOGFILE"

vlog() {
  (( VERBOSE )) && print -P "%F{8} -> $*%f" >&2
  return 0
}

human_time() {
  local s=$1
  printf '%02d:%02d:%02d' $(( s/3600 )) $(( (s%3600)/60 )) $(( s%60 ))
}

draw_progress() {
  local current=$1 total=$2 start=$3
  local elapsed=$(( SECONDS - start ))
  local width=30
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  local eta=0
  (( current > 0 )) && eta=$(( elapsed * (total - current) / current ))
  printf '\r  [%s] %d/%d (%3d%%)  elapsed %s  ETA %s ' \
    "$bar" "$current" "$total" $(( current*100/total )) \
    "$(human_time $elapsed)" "$(human_time $eta)"
}

fail_log_tail() {
  echo "  ⚠ Failed on $1 — last log lines:" >&2
  tail -n 15 "$LOGFILE" >&2
}


usage() {
cat <<EOF
Usage: ${0:t} [options] <input file or directory> [output]

Embeds a synthetic HDR gain map into JPEG/TIFF photo(s).

For a single file input: output path (default: <input>_EDR.heic /
_EDR.jpg next to the input). For a directory input: output directory
(default: the directory this script lives in, "$SCRIPT_DIR").

Options:
  -t  luminance threshold (0-100) above which pixels start glowing.
      Higher = only the very brightest highlights (sun, bulbs, sky) boost.
      Default: 85
  -s  how many stops brighter the brightest highlights can go on an
      HDR display (2 stops = up to 4x). Default: 2
  -q  toGainMapHDR output quality (0.0-1.0 float). Default: 0.85
  -c  toGainMapHDR output color space: srgb, p3, rec2020. Default: srgb
  -d  toGainMapHDR output color depth (8 or 10). Default: 8
  -r  when input is a directory, recurse into subdirectories too
  -k  keep intermediate files for debugging instead of deleting them on exit
  -j  output a gain-map JPEG instead of HEIC (skips the toGainMapHDR
      step; result is a standard Ultra HDR gain-map JPEG, viewable
      as HDR in Chrome and Android 14+)
  -v  verbose: show every processing step instead of just the progress bar
  -h  show this help

Output is always written as HEIC via toGainMapHDR unless -j is given.
EOF
exit 1
}

THRESHOLD=85
STOPS=2
QUALITY=0.85
HEIC_COLORSPACE=srgb
HEIC_DEPTH=8
RECURSIVE=0
KEEP=0
JPEG_OUTPUT=0

while getopts "t:s:q:c:d:rjkvh" opt; do
  case $opt in
    t) THRESHOLD=$OPTARG ;;
    s) STOPS=$OPTARG ;;
    q) QUALITY=$OPTARG ;;
    c) HEIC_COLORSPACE=$OPTARG ;;
    d) HEIC_DEPTH=$OPTARG ;;
    r) RECURSIVE=1 ;;
    j) JPEG_OUTPUT=1 ;;
    k) KEEP=1 ;;
    v) VERBOSE=1 ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))

[[ $# -lt 1 ]] && usage

INPUT="$1"
OUTPUT_ARG="${2:-}"

if [[ ! -e "$INPUT" ]]; then
  echo "Input not found: $INPUT" >&2
  exit 1
fi

IM=""
if command -v magick >/dev/null 2>&1; then
  IM=magick
elif command -v convert >/dev/null 2>&1; then
  IM=convert
else
  echo "ImageMagick not found. Install with: brew install imagemagick" >&2
  exit 1
fi

if ! command -v ultrahdr_app >/dev/null 2>&1; then
  echo "ultrahdr_app not found. Install with: brew install libultrahdr" >&2
  exit 1
fi

if ! command -v exiftool >/dev/null 2>&1; then
  echo "exiftool not found. Install with: brew install exiftool" >&2
  exit 1
fi

TOGAINMAPHDR="${TOGAINMAPHDR:-toGainMapHDR}"
if ! command -v "$TOGAINMAPHDR" >/dev/null 2>&1; then
  echo "toGainMapHDR not found. Download the binary from:" >&2
  echo "  https://github.com/chemharuka/toGainMapHDR/releases" >&2
  echo "and either put it on your PATH or export TOGAINMAPHDR=/path/to/toGainMapHDR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# process_one INPUT_FILE OUTPUT_FILE
# Converts a single JPEG/TIFF into a gain-map HEIC (or JPEG with -j).
# All step-by-step chatter goes to $LOGFILE; only errors and (with -v)
# progress notes reach the terminal.
# ---------------------------------------------------------------------------
process_one() {
  local IN_FILE="$1"
  local OUT_FILE="$2"

  case "${IN_FILE:l}" in
    *.jpg|*.jpeg|*.tif|*.tiff) ;;
    *)
      echo "⚠ Skipping unsupported type: $IN_FILE" >> "$LOGFILE"
      return 1
      ;;
  esac

  local WORKDIR
  WORKDIR=$(mktemp -d)
  echo "=== $(date '+%H:%M:%S') START $IN_FILE (workdir: $WORKDIR) ===" >> "$LOGFILE"
  if [[ $KEEP -eq 1 ]]; then
    vlog "Keeping intermediate files in: $WORKDIR"
  fi

  local ICC_PROFILE="$WORKDIR/source.icc"
  if ! exiftool -icc_profile -b "$IN_FILE" < /dev/null > "$ICC_PROFILE" 2>>"$LOGFILE" || [[ ! -s "$ICC_PROFILE" ]]; then
    ICC_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
    if [[ ! -f "$ICC_PROFILE" ]]; then
      echo "⚠ sRGB ICC profile not found at: $ICC_PROFILE" >> "$LOGFILE"
      (( KEEP == 0 )) && rm -rf "$WORKDIR"
      return 1
    fi
  fi

  local SDR_JPG="$WORKDIR/sdr.jpg"
  local GAINMAP_JPG="$WORKDIR/gainmap.jpg"
  local METADATA_CFG="$WORKDIR/metadata.cfg"
  local ISO_GAINMAP_JPG="$WORKDIR/iso_gainmap.jpg"
  local EFFECTIVE_QUALITY=100

  [[ $JPEG_OUTPUT -eq 1 ]] && EFFECTIVE_QUALITY=$(printf '%.0f' $(( QUALITY * 100 )))

  echo "-- stage: sdr base --" >> "$LOGFILE"
  vlog "Building SDR base image..."
  if ! "$IM" "$IN_FILE"'[0]' -auto-orient -colorspace sRGB -profile "$ICC_PROFILE" \
      -sampling-factor 4:4:4 -interlace none -quality "$EFFECTIVE_QUALITY" "$SDR_JPG" \
      < /dev/null >>"$LOGFILE" 2>&1; then
    fail_log_tail "$IN_FILE"
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
    return 1
  fi

  echo "-- stage: gain map --" >> "$LOGFILE"
  vlog "Building gain map (pixels above ${THRESHOLD}% luminance will glow)..."
  if ! "$IM" "$IN_FILE"'[0]' -auto-orient -colorspace Gray \
      -level "${THRESHOLD}%,100%" \
      -blur 0x2 \
      -colorspace sRGB \
      -profile "$ICC_PROFILE" \
      -sampling-factor 4:4:4 -interlace none -quality "$EFFECTIVE_QUALITY" \
      "$GAINMAP_JPG" \
      < /dev/null >>"$LOGFILE" 2>&1; then
    fail_log_tail "$IN_FILE"
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
    return 1
  fi

  local MAX_BOOST
  (( MAX_BOOST = 2.0 ** STOPS ))

  cat > "$METADATA_CFG" <<CFG
--maxContentBoost $MAX_BOOST
--minContentBoost 1.0
--gamma 1.0
--offsetSdr 0.015625
--offsetHdr 0.015625
--hdrCapacityMin 1.0
--hdrCapacityMax $MAX_BOOST
CFG

  local STRIPPED_SDR="$WORKDIR/sdr_stripped.jpg"
  local STRIPPED_GAINMAP="$WORKDIR/gainmap_stripped.jpg"

  exiftool -all= --icc_profile:all "$SDR_JPG" -o "$STRIPPED_SDR" < /dev/null >>"$LOGFILE" 2>&1
  exiftool -all= --icc_profile:all "$GAINMAP_JPG" -o "$STRIPPED_GAINMAP" < /dev/null >>"$LOGFILE" 2>&1

  exiftool -tagsfromfile "$IN_FILE" -all:all --icc_profile:all \
    -overwrite_original "$STRIPPED_SDR" < /dev/null >>"$LOGFILE" 2>&1

  local IMG_W IMG_H
  read -r IMG_W IMG_H <<< $("$IM" identify -format "%w %h" "$STRIPPED_SDR")

  echo "-- stage: ultrahdr_app assembly --" >> "$LOGFILE"
  vlog "Embedding gain map (${STOPS} stops boost on highlights)..."
  if ! ultrahdr_app -m 0 \
      -i "$STRIPPED_SDR" \
      -g "$STRIPPED_GAINMAP" \
      -f "$METADATA_CFG" \
      -w "$IMG_W" -h "$IMG_H" \
      -z "$ISO_GAINMAP_JPG" < /dev/null >>"$LOGFILE" 2>&1; then
    echo "⚠ Assembly failed for $IN_FILE (invalid intermediate JPEG)." >> "$LOGFILE"
    fail_log_tail "$IN_FILE"
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
    return 1
  fi

  if ! "$IM" identify "$ISO_GAINMAP_JPG" >/dev/null 2>&1; then
    echo "⚠ Assembly failed for $IN_FILE (invalid intermediate JPEG)." >> "$LOGFILE"
    fail_log_tail "$IN_FILE"
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
    return 1
  fi

  if [[ $JPEG_OUTPUT -eq 1 ]]; then
    mkdir -p "$(dirname "$OUT_FILE")"
    cp "$ISO_GAINMAP_JPG" "$OUT_FILE"
    vlog "✓ Wrote $OUT_FILE (gain-map JPEG)"
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
    return 0
  fi

  echo "-- stage: toGainMapHDR conversion --" >> "$LOGFILE"
  vlog "Converting ISO gain-map JPEG to gain-map HEIC via toGainMapHDR..."
  local HEIC_OUTDIR="$WORKDIR/heic_out"
  mkdir -p "$HEIC_OUTDIR"

  if ! "$TOGAINMAPHDR" "$ISO_GAINMAP_JPG" "$HEIC_OUTDIR" \
      -q "$QUALITY" -c "$HEIC_COLORSPACE" -d "$HEIC_DEPTH" -g \
      < /dev/null >>"$LOGFILE" 2>&1; then
    fail_log_tail "$IN_FILE"
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
    return 1
  fi

  local PRODUCED_HEIC
  PRODUCED_HEIC=$(print -l "$HEIC_OUTDIR"/*.heic(N) | head -n 1)
  if [[ -z "$PRODUCED_HEIC" || ! -f "$PRODUCED_HEIC" ]]; then
    echo "⚠ toGainMapHDR did not produce a .heic file for $IN_FILE" >> "$LOGFILE"
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
    return 1
  fi

  mkdir -p "$(dirname "$OUT_FILE")"
  mv "$PRODUCED_HEIC" "$OUT_FILE"
  vlog "✓ Wrote $OUT_FILE"

  (( KEEP == 0 )) && rm -rf "$WORKDIR"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch: single file vs. directory
# ---------------------------------------------------------------------------
if [[ -f "$INPUT" ]]; then
  EXT="heic"
  [[ $JPEG_OUTPUT -eq 1 ]] && EXT="jpg"
  OUTPUT="${OUTPUT_ARG:-${INPUT:r}_EDR.${EXT}}"
  echo "→ Processing single file: $INPUT"
  if process_one "$INPUT" "$OUTPUT"; then
    echo "✓ Done. Output: $OUTPUT"
    echo "  On SDR displays it looks like a normal photo."
    echo "  On HDR-capable displays/browsers (Chrome, recent Safari/macOS, Android 14+, Apple Photos) the bright areas will boost."
  else
    fail_log_tail "$INPUT"
    exit 1
  fi

elif [[ -d "$INPUT" ]]; then
  OUTPUT_DIR="${OUTPUT_ARG:-$SCRIPT_DIR}"
  mkdir -p "$OUTPUT_DIR"

  typeset -a FILES
  if [[ $RECURSIVE -eq 1 ]]; then
    FILES=( "$INPUT"/**/*.(#i)(jpg|jpeg|tif|tiff)(N.) )
  else
    FILES=( "$INPUT"/*.(#i)(jpg|jpeg|tif|tiff)(N.) )
  fi

  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No .jpg/.jpeg/.tif/.tiff files found in $INPUT$( [[ $RECURSIVE -eq 1 ]] && echo ' (recursively)' )." >&2
    exit 1
  fi

  TOTAL=${#FILES[@]}
  echo "→ Found $TOTAL image(s) in $INPUT. Writing output to: $OUTPUT_DIR"
  echo "  Log file: $LOGFILE"

  FAIL_COUNT=0
  OK_COUNT=0
  START=$SECONDS
  INDEX=0

  for F in "${FILES[@]}"; do
    (( INDEX += 1 ))
    REL_PATH="${F#$INPUT/}"
    REL_DIR="${REL_PATH:h}"
    BASE_NAME="${REL_PATH:t:r}"
    DEST_DIR="$OUTPUT_DIR"
    EXT="heic"
    [[ $JPEG_OUTPUT -eq 1 ]] && EXT="jpg"
    [[ "$REL_DIR" != "." ]] && DEST_DIR="$OUTPUT_DIR/$REL_DIR"
    DEST_FILE="$DEST_DIR/${BASE_NAME}_EDR.${EXT}"

    vlog "[$F] → [$DEST_FILE]"

    if process_one "$F" "$DEST_FILE"; then
      OK_COUNT=$((OK_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo
      fail_log_tail "$F"
    fi

    draw_progress "$INDEX" "$TOTAL" "$START"
  done

  echo
  echo "✓ Finished: $OK_COUNT succeeded, $FAIL_COUNT failed. Total time: $(human_time $(( SECONDS - START )))"
  (( FAIL_COUNT > 0 )) && echo "  See $LOGFILE for details on failures."
else
  echo "Input is neither a regular file nor a directory: $INPUT" >&2
  exit 1
fi
