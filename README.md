# Dynamic Range Extender

**Dynamic Range Extender** is a Zsh script that converts standard JPEG and TIFF images into HDR gain-map images, producing either **Apple-compatible HEIC** files or **Ultra HDR JPEGs** that display brighter highlights on HDR-capable devices.

Unlike true HDR photography, this script does **not** recover additional dynamic range from the source image. Instead, it generates a synthetic HDR gain map that compatible software can use to render bright regions with greater intensity while preserving normal SDR appearance.

## Features

- Converts JPEG and TIFF images
- Processes single files or entire directories
- Outputs Apple HDR gain-map HEIC (default) or Ultra HDR JPEG (`-j`)
- Recursive directory processing
- Preserves metadata and ICC color profiles
- Falls back to the system sRGB ICC profile if none is embedded
- Adjustable HDR threshold and boost strength
- Adjustable output quality, color space and bit depth
- Progress bar with ETA for batch processing
- Timestamped log files
- Verbose mode and optional preservation of intermediate files

## Requirements

```bash
brew install imagemagick libultrahdr exiftool
```

Download **toGainMapHDR** from:

https://github.com/chemharuka/toGainMapHDR/releases

Place it on your `PATH` or:

```bash
export TOGAINMAPHDR=/path/to/toGainMapHDR
```

## Usage

```text
./extender.zsh [options] input [output]
```

## Options

| Option | Description | Default |
|---------|-------------|---------|
| `-t` | Highlight threshold (0–100%). | `85` |
| `-s` | Maximum HDR boost (stops). | `2` |
| `-q` | Output quality (0.0–1.0). | `0.85` |
| `-c` | HEIC color space (`srgb`, `p3`, `rec2020`). | `srgb` |
| `-d` | HEIC bit depth (`8` or `10`). | `8` |
| `-r` | Process directories recursively. | off |
| `-j` | Produce Ultra HDR JPEG instead of HEIC. | off |
| `-k` | Keep intermediate files. | off |
| `-v` | Verbose terminal output. | off |
| `-h` | Show help. | |

## Examples

Convert a single image:

```bash
./extender.zsh image.jpg
```

Produces:

```
image_EDR.heic
```

Create an Ultra HDR JPEG:

```bash
./extender.zsh -j image.jpg
```

Produces:

```
image_EDR.jpg
```

Process recursively:

```bash
./extender.zsh -r Photos HDR_Output
```

## Logging

Each run creates a timestamped log file:

```text
logs/extender-YYYY-MM-DD_HH-MM-SS.txt
```

The log contains the output from ImageMagick, `ultrahdr_app`, ExifTool and `toGainMapHDR`, making it useful for diagnosing failed conversions.

## Viewing the results

### HEIC (default)

- Apple Photos
- Safari
- Recent macOS and iOS releases
- Other software supporting Apple HDR gain maps

### Ultra HDR JPEG (`-j`)

- Google Chrome
- Android 14+ gallery applications
- Other software supporting the Ultra HDR JPEG specification

Applications without gain-map support simply display the SDR image.

## Limitations

Dynamic Range Extender does not create true HDR photographs or recover clipped highlights. It creates a perceptually enhanced image that displays brighter highlights on HDR-capable devices while remaining fully compatible with SDR displays.

## Credits

- libultrahdr
- toGainMapHDR
- ImageMagick
- ExifTool
