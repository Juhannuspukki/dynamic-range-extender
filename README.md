# Dynamic Range Extender

**Dynamic Range Extender** is a Zsh script that converts standard JPEG and TIFF images into **HDR gain-map HEIC** images that display with enhanced highlights on HDR-capable devices.

Unlike true HDR photography, this script **does not recover additional dynamic range** from the source image. Instead, it generates a **synthetic HDR gain map**, similar to the technique used by Apple and Android's Adaptive/Ultra HDR photos, allowing compatible displays to render bright regions (such as sunlight, reflections, and lamps) with greater intensity.

## Features

- Converts a single image or an entire directory
- Supports:
  - JPEG (`.jpg`, `.jpeg`)
  - TIFF (`.tif`, `.tiff`)
- Generates Apple-compatible HDR gain-map HEIC images
- Recursive directory processing
- Preserves image metadata and ICC color profiles
- Adjustable:
  - Highlight threshold
  - HDR boost strength (in stops)
  - HEIC quality
  - Color space
  - Bit depth
- Optional preservation of intermediate files for debugging

---

## How it works

Dynamic Range Extender performs the following steps:

1. Creates an SDR version of the original image.
2. Generates a grayscale gain map representing highlight intensity.
3. Embeds the gain map into an ISO UltraHDR JPEG using **libultrahdr**.
4. Converts the result into an Apple-compatible HDR gain-map HEIC using **toGainMapHDR**.

The resulting HEIC:

- appears like a normal photo on SDR displays
- displays brighter highlights on HDR-capable displays

---

## Requirements

### macOS

Install the required tools:

```bash
brew install imagemagick libultrahdr exiftool
```

Download the latest **toGainMapHDR** binary:

https://github.com/chemharuka/toGainMapHDR/releases

Either:

- place it somewhere on your `PATH`, or
- specify its location:

```bash
export TOGAINMAPHDR=/path/to/toGainMapHDR
```

---

## Usage

```text
./extender.zsh [options] input [output]
```

### Input

The input may be either:

- a single image
- a directory containing images

### Output

For a single image:

```
<input>_hdr.heic
```

For a directory:

The output is written to the specified destination directory. If none is provided, files are written to the current working directory.

---

## Options

| Option | Description | Default |
|---------|-------------|---------|
| `-t` | Highlight threshold (0–100%). Pixels brighter than this begin receiving HDR enhancement. | `85` |
| `-s` | Maximum HDR boost in exposure stops. | `2` |
| `-q` | HEIC output quality (0.0–1.0). | `0.85` |
| `-c` | Output color space (`srgb`, `p3`, `rec2020`). | `srgb` |
| `-d` | Output bit depth (`8` or `10`). | `8` |
| `-r` | Process directories recursively. | disabled |
| `-k` | Keep intermediate files for debugging. | disabled |

---

## Examples

### Convert a single image

```bash
./extender.zsh image.jpg
```

Produces:

```
image_hdr.heic
```

### Specify an output filename

```bash
./extender.zsh image.tif result.heic
```

### Process an entire directory

```bash
./extender.zsh Photos/
```

### Process recursively

```bash
./extender.zsh -r Photos/ HDR_Output/
```

The directory structure is preserved inside the output directory.

### Increase the HDR effect

```bash
./extender.zsh -t 75 -s 4 image.jpg
```

This causes:

- more pixels to receive HDR enhancement
- highlights to appear brighter on HDR displays

---

## Viewing the results

HDR gain-map HEIC images are best viewed in software that supports gain maps, including:

- Apple Photos
- Recent versions of Safari
- Google Chrome with HDR enabled
- Android 14+ gallery applications supporting Ultra HDR

Applications without gain-map support simply display the SDR image.

---

## Limitations

Dynamic Range Extender **does not create true HDR photographs**.

It cannot recover clipped highlights or scene information that was never captured by the camera sensor.

Instead, it creates a perceptually enhanced image by allowing compatible HDR displays to render selected highlights at greater brightness while preserving a normal appearance on SDR devices.

---

## Credits

Dynamic Range Extender is built on top of the following open-source projects:

- **libultrahdr** — Google's UltraHDR implementation
- **toGainMapHDR** — https://github.com/chemharuka/toGainMapHDR
- **ImageMagick**
- **ExifTool**