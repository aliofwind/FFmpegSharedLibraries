# FFmpegSharedLibraries

GitHub Actions workflows for building FFmpeg shared-library runtimes with `libuavs3d` enabled.

## Outputs

- `macos-14`: arm64 `.dylib`
- `windows-latest`: win64 `.dll`
- `ubuntu-latest`: linux x64 `.so`

Each workflow builds FFmpeg shared libraries only. `libuavs3d` is built from source as a static dependency and linked into FFmpeg, so the runtime artifacts do not include separate `libuavs3d` dynamic libraries.

## Workflow Inputs

All build workflows expose the same manual inputs:

- `ffmpeg_version`: FFmpeg release version, default `7.1.3`
- `license_flavor`: `gpl` or `lgpl`

## Workflows

- [`.github/workflows/build-ffmpeg-runtime-macos.yml`](/Users/macmini/code/GitHub/FFmpegSharedLibraries/.github/workflows/build-ffmpeg-runtime-macos.yml)
- [`.github/workflows/build-ffmpeg-runtime-windows.yml`](/Users/macmini/code/GitHub/FFmpegSharedLibraries/.github/workflows/build-ffmpeg-runtime-windows.yml)
- [`.github/workflows/build-ffmpeg-runtime-linux.yml`](/Users/macmini/code/GitHub/FFmpegSharedLibraries/.github/workflows/build-ffmpeg-runtime-linux.yml)
