#!/usr/bin/env zsh
#
# extender.zsh — embed a synthetic gain map in a photo so highlights
# glow brighter on HDR-capable displays, iPhone-style. This does NOT
# recover real extra dynamic range (no bracketing/stacking) — it just
# tells compatible displays how much brighter the highlight pixels are
# allowed to go, same trick Apple/Android "Adaptive"/"Ultra" HDR photos use.
#
# Pipeline:
#   1. ImageMagick builds an SDR base + a grayscale gain-map JPEG.
#   2. ultrahdr_app assembles them into an ISO gain-map JPEG.
#   3. toGainMapHDR (https://github.com/chemharuka/toGainMapHDR) converts
#      that ISO gain-map JPEG into a proper Apple/ISO gain-map HEIC.
#
# Accepts either a single image file or a directory. When given a
# directory, every .jpg/.jpeg/.tif/.tiff inside is processed; add -r
# to also descend into subdirectories.
#
# Requires: brew install imagemagick libultrahdr exiftool
#           toGainMapHDR binary on PATH, or set $TOGAINMAPHDR to its path
#           (download from https://github.com/chemharuka/toGainMapHDR/releases)

set -euo pipefail
setopt extendedglob

SCRIPT_DIR="${0:A:h}"

usage() {
  cat <<EOF
Usage: $0 [-t threshold%] [-s stops] [-q quality] [-Q heic_quality] [-c colorspace] [-d depth] [-r] [-k] input [output]

  input   A single .jpg/.jpeg/.tif/.tiff file, OR a directory containing
          such files.
  output  Optional. For a single-file input: output .heic path (default:
          <input>_hdr.heic next to the input). For a directory input:
          output directory (default: the directory this script lives in,
          "$SCRIPT_DIR").

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

  Output is always written as HEIC via toGainMapHDR.
EOF
  exit 1
}

THRESHOLD=85
STOPS=2
QUALITY=100
HEIC_QUALITY=0.85
HEIC_COLORSPACE=srgb
HEIC_DEPTH=8
RECURSIVE=0
KEEP=0

while getopts "t:s:q:Q:c:d:rkh" opt; do
  case $opt in
    t) THRESHOLD=$OPTARG ;;
    s) STOPS=$OPTARG ;;
    q) HEIC_QUALITY=$OPTARG ;;
    c) HEIC_COLORSPACE=$OPTARG ;;
    d) HEIC_DEPTH=$OPTARG ;;
    r) RECURSIVE=1 ;;
    k) KEEP=1 ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))

[[ $# -lt 1 ]] && usage

INPUT="$1"
OUTPUT_ARG="${2:-}"

[[ -e "$INPUT" ]] || { echo "Input not found: $INPUT" >&2; exit 1 }

IM=""
if command -v magick >/dev/null 2>&1; then
  IM=magick
elif command -v convert >/dev/null 2>&1; then
  IM=convert
else
  echo "ImageMagick not found. Install with: brew install imagemagick" >&2
  exit 1
fi

command -v ultrahdr_app >/dev/null 2>&1 || {
  echo "ultrahdr_app not found. Install with: brew install libultrahdr" >&2
  exit 1
}

command -v exiftool >/dev/null 2>&1 || {
  echo "exiftool not found. Install with: brew install exiftool" >&2
  exit 1
}

TOGAINMAPHDR="${TOGAINMAPHDR:-toGainMapHDR}"
command -v "$TOGAINMAPHDR" >/dev/null 2>&1 || {
  echo "toGainMapHDR not found. Download the binary from:" >&2
  echo "  https://github.com/chemharuka/toGainMapHDR/releases" >&2
  echo "and either put it on your PATH or export TOGAINMAPHDR=/path/to/toGainMapHDR" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# process_one INPUT_FILE OUTPUT_FILE
# Converts a single JPEG/TIFF into a gain-map HEIC.
# ---------------------------------------------------------------------------
process_one() {
  local IN_FILE="$1"
  local OUT_FILE="$2"

  case "${IN_FILE:l}" in
    *.jpg|*.jpeg|*.tif|*.tiff) ;;
    *)
      echo "  ⚠ Skipping unsupported type: $IN_FILE" >&2
      return 1
      ;;
  esac

  local WORKDIR
  WORKDIR=$(mktemp -d)
  if [[ $KEEP -eq 1 ]]; then
    echo "  → Keeping intermediate files in: $WORKDIR"
  fi

  local RESULT=0
  {
  local ICC_PROFILE="$WORKDIR/source.icc"
  if ! exiftool -icc_profile -b "$IN_FILE" > "$ICC_PROFILE" 2>/dev/null || [[ ! -s "$ICC_PROFILE" ]]; then
    ICC_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
    [[ -f "$ICC_PROFILE" ]] || {
      echo "  ⚠ sRGB ICC profile not found at: $ICC_PROFILE" >&2
      return 1
    }
  fi

  local SDR_JPG="$WORKDIR/sdr.jpg"
  local GAINMAP_JPG="$WORKDIR/gainmap.jpg"
  local METADATA_CFG="$WORKDIR/metadata.cfg"
  local ISO_GAINMAP_JPG="$WORKDIR/iso_gainmap.jpg"

  echo "  → Building SDR base image..."
  "$IM" "$IN_FILE"'[0]' -auto-orient -colorspace sRGB -profile "$ICC_PROFILE" \
    -sampling-factor 4:4:4 -interlace none -quality "$QUALITY" "$SDR_JPG" \
    2> >(grep -v 'Wrong data type 3 for "PixelXDimension"\|Wrong data type 3 for "PixelYDimension"\|TIFFReadCustomDirectory' >&2)

  echo "  → Building gain map (pixels above ${THRESHOLD}% luminance will glow)..."
  "$IM" "$IN_FILE"'[0]' -auto-orient -colorspace Gray \
    -level "${THRESHOLD}%,100%" \
    -blur 0x2 \
    -colorspace sRGB \
    -profile "$ICC_PROFILE" \
    -sampling-factor 4:4:4 -interlace none -quality "$QUALITY" \
    "$GAINMAP_JPG" \
    2> >(grep -v 'Wrong data type 3 for "PixelXDimension"\|Wrong data type 3 for "PixelYDimension"\|TIFFReadCustomDirectory' >&2)

  local MAX_BOOST
  (( MAX_BOOST = 2.0 ** STOPS ))

  cat > "$METADATA_CFG" <<EOF
--maxContentBoost $MAX_BOOST
--minContentBoost 1.0
--gamma 1.0
--offsetSdr 0.015625
--offsetHdr 0.015625
--hdrCapacityMin 1.0
--hdrCapacityMax $MAX_BOOST
EOF

  local STRIPPED_SDR="$WORKDIR/sdr_stripped.jpg"
  local STRIPPED_GAINMAP="$WORKDIR/gainmap_stripped.jpg"

  exiftool -all= --icc_profile:all "$SDR_JPG" -o "$STRIPPED_SDR"
  exiftool -all= --icc_profile:all "$GAINMAP_JPG" -o "$STRIPPED_GAINMAP"

  exiftool -tagsfromfile "$IN_FILE" -all:all --icc_profile:all \
    -overwrite_original "$STRIPPED_SDR"

  local IMG_W IMG_H
  read -r IMG_W IMG_H <<< $("$IM" identify -format "%w %h" "$STRIPPED_SDR")

  echo "  → Embedding gain map (${STOPS} stops boost on highlights)..."
  ultrahdr_app -m 0 \
    -i "$STRIPPED_SDR" \
    -g "$STRIPPED_GAINMAP" \
    -f "$METADATA_CFG" \
    -w "$IMG_W" -h "$IMG_H" \
    -q "$QUALITY" -Q "$QUALITY" \
    -z "$ISO_GAINMAP_JPG"

  if ! "$IM" identify "$ISO_GAINMAP_JPG" >/dev/null 2>&1; then
    echo "  ⚠ Assembly failed for $IN_FILE (invalid intermediate JPEG)." >&2
    return 1
  fi

  echo "  → Converting ISO gain-map JPEG to gain-map HEIC via toGainMapHDR..."
  local HEIC_OUTDIR="$WORKDIR/heic_out"
  mkdir -p "$HEIC_OUTDIR"

  "$TOGAINMAPHDR" "$ISO_GAINMAP_JPG" "$HEIC_OUTDIR" \
    -q "$HEIC_QUALITY" -c "$HEIC_COLORSPACE" -d "$HEIC_DEPTH"

  local PRODUCED_HEIC
  PRODUCED_HEIC=$(print -l "$HEIC_OUTDIR"/*.heic(N) | head -n 1)
  if [[ -z "$PRODUCED_HEIC" || ! -f "$PRODUCED_HEIC" ]]; then
    echo "  ⚠ toGainMapHDR did not produce a .heic file for $IN_FILE" >&2
    return 1
  fi

  mkdir -p "$(dirname "$OUT_FILE")"
  mv "$PRODUCED_HEIC" "$OUT_FILE"
  echo "  ✓ Wrote $OUT_FILE"
  } always {
    (( KEEP == 0 )) && rm -rf "$WORKDIR"
  }
  return $RESULT
}

# ---------------------------------------------------------------------------
# Dispatch: single file vs. directory
# ---------------------------------------------------------------------------
if [[ -f "$INPUT" ]]; then
  OUTPUT="${OUTPUT_ARG:-${INPUT:r}_hdr.heic}"
  echo "→ Processing single file: $INPUT"
  process_one "$INPUT" "$OUTPUT"
  echo "✓ Done."
  echo "  On SDR displays it looks like a normal photo."
  echo "  On HDR-capable displays/browsers (Chrome, recent Safari/macOS, Android 14+, Apple Photos) the bright areas will boost."

elif [[ -d "$INPUT" ]]; then
  OUTPUT_DIR="${OUTPUT_ARG:-$SCRIPT_DIR}"
  mkdir -p "$OUTPUT_DIR"

  local -a FILES
  if [[ $RECURSIVE -eq 1 ]]; then
    FILES=( "$INPUT"/**/*.(#i)(jpg|jpeg|tif|tiff)(N.) )
  else
    FILES=( "$INPUT"/*.(#i)(jpg|jpeg|tif|tiff)(N.) )
  fi

  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No .jpg/.jpeg/.tif/.tiff files found in $INPUT$( [[ $RECURSIVE -eq 1 ]] && echo ' (recursively)' )." >&2
    exit 1
  fi

  echo "→ Found ${#FILES[@]} image(s) in $INPUT. Writing HEIC output to: $OUTPUT_DIR"

  local FAIL_COUNT=0
  local OK_COUNT=0
  for F in "${FILES[@]}"; do
    local REL_PATH="${F#$INPUT/}"
    local REL_DIR="${REL_PATH:h}"
    local BASE_NAME="${REL_PATH:t:r}"
    local DEST_DIR="$OUTPUT_DIR"
    [[ "$REL_DIR" != "." ]] && DEST_DIR="$OUTPUT_DIR/$REL_DIR"
    local DEST_FILE="$DEST_DIR/${BASE_NAME}_hdr.heic"

    echo "→ [$F] → [$DEST_FILE]"
    if process_one "$F" "$DEST_FILE"; then
      OK_COUNT=$((OK_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done

  echo "✓ Finished: $OK_COUNT succeeded, $FAIL_COUNT failed."
else
  echo "Input is neither a regular file nor a directory: $INPUT" >&2
  exit 1
fi
