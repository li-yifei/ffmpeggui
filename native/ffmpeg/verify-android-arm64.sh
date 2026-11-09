#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly PROJECT_ROOT
readonly BINARY="${1:-$PROJECT_ROOT/app/src/main/libs/arm64-v8a/libffmpeg.so}"
readonly NDK_ROOT="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-commandlinetools/ndk/29.0.14206865}"
readonly EXPECTED_SHA256="3435fbd16c5d2ba37a790c155bd2274fc0d3c2ccc755af49b828511837fa4504"

case "$(uname -s)" in
    Darwin) readonly NDK_HOST="darwin-x86_64" ;;
    Linux) readonly NDK_HOST="linux-x86_64" ;;
    *)
        echo "Unsupported verification host: $(uname -s)" >&2
        exit 1
        ;;
esac

readonly READELF="$NDK_ROOT/toolchains/llvm/prebuilt/$NDK_HOST/bin/llvm-readelf"

if [[ ! -f "$BINARY" ]]; then
    echo "FFmpeg binary was not found: $BINARY" >&2
    exit 1
fi

EXPECTED_AIO_SHA256="$EXPECTED_SHA256" \
    "$SCRIPT_DIR/verify-android-arm64-aio.sh" "$BINARY"

file "$BINARY"
actual_sha256="$(shasum -a 256 "$BINARY" | awk '{ print $1 }')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
    echo "FFmpeg binary checksum mismatch." >&2
    echo "Expected $EXPECTED_SHA256, got $actual_sha256" >&2
    exit 1
fi
echo "$actual_sha256  $BINARY"

if strings "$BINARY" | grep -E '/Users/|Documents/Codex|native/ffmpeg/\.build' >/dev/null; then
    echo "FFmpeg binary contains a host checkout path." >&2
    exit 1
fi
echo "FFmpeg binary contains no host checkout paths."

if ! "$READELF" -h "$BINARY" | grep -E 'Machine:[[:space:]]+AArch64' >/dev/null; then
    echo "Expected an AArch64 ELF binary." >&2
    exit 1
fi

if "$READELF" -lW "$BINARY" | awk '$1 == "LOAD" && $NF != "0x4000" { exit 1 }'; then
    echo "All ELF LOAD segments use 16KB alignment."
else
    echo "An ELF LOAD segment is not aligned for 16KB pages." >&2
    "$READELF" -lW "$BINARY" >&2
    exit 1
fi

unexpected_libraries="$("$READELF" -d "$BINARY" | awk '
    /\(NEEDED\)/ {
        library = $NF
        gsub(/^\[/, "", library)
        gsub(/\]$/, "", library)
        if (library != "libm.so" &&
            library != "libandroid.so" &&
            library != "libcamera2ndk.so" &&
            library != "libmediandk.so" &&
            library != "libz.so" &&
            library != "libdl.so" &&
            library != "libc.so") {
            print library
        }
    }
')"
if [[ -n "$unexpected_libraries" ]]; then
    echo "Unexpected dynamic libraries:" >&2
    printf '%s\n' "$unexpected_libraries" >&2
    exit 1
fi
echo "Dynamic dependencies are limited to Android/NDK system libraries."

for codec in h264_mediacodec hevc_mediacodec vp9_mediacodec av1_mediacodec; do
    if ! strings "$BINARY" | grep -F "$codec" >/dev/null; then
        echo "Missing MediaCodec component string: $codec" >&2
        exit 1
    fi
done
echo "MediaCodec H.264, HEVC, VP9, and AV1 component names are present."

device_serial=""
if command -v adb >/dev/null 2>&1; then
    if [[ -n "${ANDROID_SERIAL:-}" ]]; then
        if [[ "$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)" == "device" ]]; then
            device_serial="$ANDROID_SERIAL"
        else
            echo "ANDROID_SERIAL is not an authorized adb device: $ANDROID_SERIAL" >&2
            exit 1
        fi
    else
        connected_devices="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
        device_count="$(printf '%s\n' "$connected_devices" | awk 'NF { count++ } END { print count + 0 }')"
        if [[ "$device_count" == "1" ]]; then
            device_serial="$(printf '%s\n' "$connected_devices" | awk 'NF { print; exit }')"
        fi
    fi
fi

if [[ -n "$device_serial" ]]; then
    readonly DEVICE_BINARY="/data/local/tmp/ffmpeggui-ffmpeg-9.0.2"
    adb_device=(adb -s "$device_serial")
    cleanup_device_binary() {
        "${adb_device[@]}" shell rm -f "$DEVICE_BINARY" >/dev/null 2>&1 || true
    }
    trap cleanup_device_binary EXIT

    "${adb_device[@]}" push "$BINARY" "$DEVICE_BINARY" >/dev/null
    "${adb_device[@]}" shell chmod 0755 "$DEVICE_BINARY"
    "${adb_device[@]}" shell "$DEVICE_BINARY" -hide_banner -version

    encoders="$("${adb_device[@]}" shell "$DEVICE_BINARY" -hide_banner -encoders 2>&1)"
    decoders="$("${adb_device[@]}" shell "$DEVICE_BINARY" -hide_banner -decoders 2>&1)"
    formats="$("${adb_device[@]}" shell "$DEVICE_BINARY" -hide_banner -formats 2>&1)"
    filters="$("${adb_device[@]}" shell "$DEVICE_BINARY" -hide_banner -filters 2>&1)"
    protocols="$("${adb_device[@]}" shell "$DEVICE_BINARY" -hide_banner -protocols 2>&1)"
    hwaccels="$("${adb_device[@]}" shell "$DEVICE_BINARY" -hide_banner -hwaccels 2>&1)"

    require_runtime_name() {
        local listing="$1"
        local name="$2"
        if ! grep -E "(^|[[:space:],])${name}([[:space:],]|$)" <<<"$listing" >/dev/null; then
            echo "Missing runtime component: $name" >&2
            exit 1
        fi
    }

    for name in h264_mediacodec hevc_mediacodec vp9_mediacodec av1_mediacodec aac opus flac; do
        require_runtime_name "$encoders" "$name"
        require_runtime_name "$decoders" "$name"
    done
    for name in libx264 libx265 libvpx-vp9 libaom-av1; do
        require_runtime_name "$encoders" "$name"
    done
    for name in libvpx-vp9 libaom-av1 libaribcaption; do
        require_runtime_name "$decoders" "$name"
    done
    for name in mp4 matroska webm mpegts ogg wav flac; do
        require_runtime_name "$formats" "$name"
    done
    for name in scale crop overlay concat loudnorm aresample mpdecimate drawtext ass subtitles; do
        require_runtime_name "$filters" "$name"
    done
    for name in file pipe http tcp; do
        require_runtime_name "$protocols" "$name"
    done
    require_runtime_name "$hwaccels" mediacodec

    printf '%s\n' "$encoders" | grep -E 'h264_mediacodec|hevc_mediacodec|vp9_mediacodec|av1_mediacodec'
    printf '%s\n' "$decoders" | grep -E 'h264_mediacodec|hevc_mediacodec|vp9_mediacodec|av1_mediacodec'
    echo "Common codecs, formats, filters, protocols, and MediaCodec hwaccel passed runtime checks."
else
    echo "Device verification skipped: connect exactly one authorized adb device or set ANDROID_SERIAL."
fi
