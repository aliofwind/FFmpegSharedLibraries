#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained macOS arm64 FFmpeg runtime:
# - FFmpeg shared dylibs are packaged
# - libuavs3d is built as a static dependency and linked into FFmpeg
# - unexpected external dylib dependencies are treated as build failures
# - decoders stay broad by default, while most encoders are disabled

FFMPEG_VERSION="${1:?usage: build_ffmpeg_runtime_macos.sh <ffmpeg-version> <gpl|lgpl> [work-root] }"
LICENSE_FLAVOR="${2:?usage: build_ffmpeg_runtime_macos.sh <ffmpeg-version> <gpl|lgpl> [work-root] }"
WORK_ROOT="${3:-$PWD/.ffmpeg-runtime-build}"

case "$LICENSE_FLAVOR" in
  gpl|lgpl)
    ;;
  *)
    echo "Unsupported license flavor: $LICENSE_FLAVOR" >&2
    exit 1
    ;;
esac

ARCHIVE_NAME="ffmpeg-$FFMPEG_VERSION.tar.xz"
SOURCE_URL="https://ffmpeg.org/releases/$ARCHIVE_NAME"
UAVS3D_GIT_URL="https://github.com/uavs3/uavs3d.git"
UAVS3D_GIT_REF="0e20d2c291853f196c68922a264bcd8471d75b68"
SOURCE_ROOT="$WORK_ROOT/src"
SOURCE_ARCHIVE="$SOURCE_ROOT/$ARCHIVE_NAME"
SOURCE_DIR="$SOURCE_ROOT/ffmpeg-$FFMPEG_VERSION"
UAVS3D_SOURCE_DIR="$SOURCE_ROOT/uavs3d"
UAVS3D_BUILD_DIR="$UAVS3D_SOURCE_DIR/build/cmake"
UAVS3D_INSTALL_ROOT="$WORK_ROOT/uavs3d-install"
INSTALL_ROOT="$WORK_ROOT/install"
PACKAGE_ROOT="$WORK_ROOT/package"
RUNTIME_ROOT="$PACKAGE_ROOT"
ARTIFACT_ROOT="$WORK_ROOT/artifacts"

LIBRARY_NAMES=(
  libavutil.59.dylib
  libswresample.5.dylib
  libswscale.8.dylib
  libavcodec.61.dylib
  libavformat.61.dylib
  libavfilter.10.dylib
  libavdevice.61.dylib
  libpostproc.58.dylib
)

PACKAGE_NAME="ffmpeg-runtime-osx-arm64-$LICENSE_FLAVOR-shared-$FFMPEG_VERSION"
ARTIFACT_PATH="$ARTIFACT_ROOT/$PACKAGE_NAME.zip"

mkdir -p "$SOURCE_ROOT" "$INSTALL_ROOT" "$RUNTIME_ROOT" "$ARTIFACT_ROOT"

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  curl -L "$SOURCE_URL" -o "$SOURCE_ARCHIVE"
fi

rm -rf "$SOURCE_DIR"
tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT"

rm -rf "$INSTALL_ROOT" "$PACKAGE_ROOT" "$UAVS3D_INSTALL_ROOT" "$UAVS3D_SOURCE_DIR"
mkdir -p "$INSTALL_ROOT" "$RUNTIME_ROOT" "$UAVS3D_INSTALL_ROOT"

git init "$UAVS3D_SOURCE_DIR" >/dev/null
git -C "$UAVS3D_SOURCE_DIR" remote add origin "$UAVS3D_GIT_URL"
git -C "$UAVS3D_SOURCE_DIR" fetch --depth 1 origin "$UAVS3D_GIT_REF"
git -C "$UAVS3D_SOURCE_DIR" checkout --detach FETCH_HEAD

cmake -S "$UAVS3D_SOURCE_DIR" \
  -B "$UAVS3D_BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$UAVS3D_INSTALL_ROOT" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCOMPILE_10BIT=1
cmake --build "$UAVS3D_BUILD_DIR" -j"$(sysctl -n hw.ncpu)"
cmake --install "$UAVS3D_BUILD_DIR"

if [[ ! -f "$UAVS3D_INSTALL_ROOT/lib/libuavs3d.a" ]]; then
  echo "Static libuavs3d archive was not produced" >&2
  exit 1
fi

if find "$UAVS3D_INSTALL_ROOT/lib" -maxdepth 1 -name 'libuavs3d*.dylib' | grep -q .; then
  echo "Dynamic libuavs3d artifacts were produced unexpectedly" >&2
  exit 1
fi

if [[ ! -f "$UAVS3D_INSTALL_ROOT/lib/pkgconfig/uavs3d.pc" ]]; then
  mkdir -p "$UAVS3D_INSTALL_ROOT/lib/pkgconfig"
  cat >"$UAVS3D_INSTALL_ROOT/lib/pkgconfig/uavs3d.pc" <<EOF
prefix=$UAVS3D_INSTALL_ROOT
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: uavs3d
Description: AVS3 decoder library
Version: 1.1.41
Libs: -L\${libdir} -luavs3d
Cflags: -I\${includedir}
EOF
fi

export PKG_CONFIG_PATH="$UAVS3D_INSTALL_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LDFLAGS="-L$UAVS3D_INSTALL_ROOT/lib${LDFLAGS:+ $LDFLAGS}"
export CPPFLAGS="-I$UAVS3D_INSTALL_ROOT/include${CPPFLAGS:+ $CPPFLAGS}"

pushd "$SOURCE_DIR" >/dev/null

CONFIGURE_FLAGS=(
  --prefix="$INSTALL_ROOT"
  --arch=arm64
  --target-os=darwin
  --cc=clang
  --enable-shared
  --enable-pthreads
  --disable-static
  --disable-programs
  --disable-doc
  --disable-debug
  --enable-pic
  --disable-autodetect
  --disable-ffplay
  --disable-network
  --disable-indevs
  --disable-outdevs
  --disable-devices
  --disable-encoders
  --enable-encoder=png,mjpeg,bmp
  --enable-videotoolbox
  --enable-audiotoolbox
  --enable-neon
)

if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  CONFIGURE_FLAGS+=(--enable-gpl --enable-version3)
fi

CONFIGURE_FLAGS+=(--enable-libuavs3d)

./configure "${CONFIGURE_FLAGS[@]}"
make -j"$(sysctl -n hw.ncpu)"
make install

popd >/dev/null

for library_name in "${LIBRARY_NAMES[@]}"; do
  source_path="$INSTALL_ROOT/lib/$library_name"
  if [[ ! -f "$source_path" ]]; then
    echo "Missing expected FFmpeg runtime library: $library_name" >&2
    exit 1
  fi

  cp -L "$source_path" "$RUNTIME_ROOT/$library_name"
  chmod u+w "$RUNTIME_ROOT/$library_name"
done

for dylib in "$RUNTIME_ROOT"/*.dylib; do
  dylib_name="$(basename "$dylib")"
  install_name_tool -id "@loader_path/$dylib_name" "$dylib"
done

for dylib in "$RUNTIME_ROOT"/*.dylib; do
  while IFS= read -r dependency; do
    dependency_name="$(basename "$dependency")"
    dependency_local="$RUNTIME_ROOT/$dependency_name"
    if [[ -f "$dependency_local" ]]; then
      install_name_tool -change "$dependency" "@loader_path/$dependency_name" "$dylib"
    fi
  done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}')
done

{
  echo "FFmpeg version: $FFMPEG_VERSION"
  echo "License flavor: $LICENSE_FLAVOR"
  echo "Enable libuavs3d: true"
  echo "libuavs3d linkage: static"
  echo "libuavs3d revision: $UAVS3D_GIT_REF"
  echo "Built on: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo
  echo "Configure flags:"
  printf '  %s\n' "${CONFIGURE_FLAGS[@]}"
  echo
  echo "Bundled dylibs:"
  find "$RUNTIME_ROOT" -maxdepth 1 -type f -name '*.dylib' -print | sort
  echo
  echo "Dependency report:"
  for dylib in "$RUNTIME_ROOT"/*.dylib; do
    echo "## $(basename "$dylib")"
    otool -L "$dylib"
    echo
  done
} >"$ARTIFACT_ROOT/$PACKAGE_NAME.manifest.txt"

for dylib in "$RUNTIME_ROOT"/*.dylib; do
  while IFS= read -r dependency; do
    dependency_name="$(basename "$dependency")"
    case "$dependency" in
      @loader_path/*|/usr/lib/*|/System/Library/*)
        ;;
      *)
        echo "Unexpected external dependency in $(basename "$dylib"): $dependency" >&2
        exit 1
        ;;
    esac

    if [[ "$dependency" == @loader_path/* && ! -f "$RUNTIME_ROOT/$dependency_name" ]]; then
      echo "Missing bundled dependency for $(basename "$dylib"): $dependency_name" >&2
      exit 1
    fi
  done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}')
done

(
  cd "$PACKAGE_ROOT"
  zip -qj "$ARTIFACT_PATH" ./*.dylib
)
echo "Created artifact: $ARTIFACT_PATH"
