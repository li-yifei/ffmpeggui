#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly BINARY="${FFMPEG_BINARY:-$PROJECT_ROOT/app/src/main/libs/arm64-v8a/libffmpeg.so}"
readonly REMOTE_BINARY="/data/local/tmp/ffmpeggui-ffmpeg-9.0.2-smoke"

if [[ ! -f "$BINARY" ]]; then
    echo "FFmpeg binary was not found: $BINARY" >&2
    exit 1
fi

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    readonly DEVICE_SERIAL="$ANDROID_SERIAL"
else
    connected_devices="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
    device_count="$(printf '%s\n' "$connected_devices" | awk 'NF { count++ } END { print count + 0 }')"
    if [[ "$device_count" != "1" ]]; then
        echo "Connect exactly one authorized adb device or set ANDROID_SERIAL." >&2
        exit 1
    fi
    readonly DEVICE_SERIAL="$(printf '%s\n' "$connected_devices" | awk 'NF { print; exit }')"
fi

adb_device=(adb -s "$DEVICE_SERIAL")
remote_outputs=()

cleanup() {
    "${adb_device[@]}" shell rm -f "$REMOTE_BINARY" "${remote_outputs[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${adb_device[@]}" push "$BINARY" "$REMOTE_BINARY" >/dev/null
"${adb_device[@]}" shell chmod 0755 "$REMOTE_BINARY"

model="$("${adb_device[@]}" shell getprop ro.product.model | tr -d '\r')"
soc="$("${adb_device[@]}" shell getprop ro.soc.model | tr -d '\r')"
api="$("${adb_device[@]}" shell getprop ro.build.version.sdk | tr -d '\r')"
page_size="$("${adb_device[@]}" shell getconf PAGE_SIZE | tr -d '\r')"
echo "Device: $model; SoC: $soc; API: $api; page size: $page_size"

test_codec() {
    local codec="$1"
    local required="$2"
    local extension="mp4"
    if [[ "$codec" == "vp9" ]]; then
        extension="webm"
    fi
    local remote_output="/data/local/tmp/ffmpeggui-${codec}-mediacodec-smoke.${extension}"
    local encode_log
    local locked_encode_log
    local decode_log
    local encoder_component
    local locked_encoder_component
    local decoder_component

    remote_outputs+=("$remote_output")

    if ! encode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel debug \
            -f lavfi -i 'testsrc2=size=640x360:rate=30' \
            -frames:v 30 -an -c:v "${codec}_mediacodec" \
            -ndk_codec 1 -ndk_async 0 -b:v 2M \
            -y "$remote_output" 2>&1)"; then
        echo "$codec MediaCodec encode failed." >&2
        printf '%s\n' "$encode_log" >&2
        [[ "$required" == "optional" ]] && return 0
        return 1
    fi

    encoder_component="$(printf '%s\n' "$encode_log" \
        | sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' \
        | head -n 1)"
    if [[ -z "$encoder_component" ]]; then
        echo "$codec MediaCodec encode completed without a component name." >&2
        [[ "$required" == "optional" ]] && return 0
        return 1
    fi

    if ! locked_encode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel debug \
            -f lavfi -i 'testsrc2=size=640x360:rate=30' \
            -frames:v 30 -an -c:v "${codec}_mediacodec" \
            -codec_name "$encoder_component" -ndk_codec 1 -ndk_async 0 -b:v 2M \
            -y "$remote_output" 2>&1)"; then
        echo "$codec MediaCodec encode failed when locked to $encoder_component." >&2
        printf '%s\n' "$locked_encode_log" >&2
        [[ "$required" == "optional" ]] && return 0
        return 1
    fi

    locked_encoder_component="$(printf '%s\n' "$locked_encode_log" \
        | sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' \
        | head -n 1)"
    if [[ "$locked_encoder_component" != "$encoder_component" ]]; then
        echo "$codec component lock mismatch: requested $encoder_component, got $locked_encoder_component." >&2
        [[ "$required" == "optional" ]] && return 0
        return 1
    fi

    if ! decode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel info \
            -hwaccel mediacodec -i "$remote_output" \
            -f null - 2>&1)"; then
        echo "$codec MediaCodec decode failed." >&2
        printf '%s\n' "$decode_log" >&2
        [[ "$required" == "optional" ]] && return 0
        return 1
    fi

    decoder_component="$(printf '%s\n' "$decode_log" \
        | sed -n 's/.*MediaCodec started successfully: codec = \([^,]*\),.*/\1/p' \
        | head -n 1)"
    if [[ -z "$decoder_component" ]]; then
        echo "$codec MediaCodec decode completed without a component name." >&2
        [[ "$required" == "optional" ]] && return 0
        return 1
    fi

    echo "$codec encode: $encoder_component (locked with -codec_name); decode: $decoder_component"
    if [[ "$encoder_component" == c2.android.* ]]; then
        echo "$codec encoder is Android's reference software component." >&2
        [[ "$required" == "optional" ]] && return 0
        return 1
    fi
}

test_codec h264 required
test_codec hevc required
test_codec vp9 optional
test_codec av1 optional
