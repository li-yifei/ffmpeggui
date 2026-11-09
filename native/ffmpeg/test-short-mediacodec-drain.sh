#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly BINARY="${FFMPEG_BINARY:-$PROJECT_ROOT/app/src/main/libs/arm64-v8a/libffmpeg.so}"
readonly REMOTE_BINARY="/data/local/tmp/ffmpeggui-ffmpeg-9.0.2-short-drain"
readonly -a FRAME_COUNTS=(1 3 9 10 11 30)

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
echo "Device: $model; SoC: $soc; API: $api"

test_codec() {
    local codec="$1"
    local probe_output="/data/local/tmp/ffmpeggui-${codec}-drain-probe.mp4"
    local probe_log
    local encoder_component
    local frame_count

    remote_outputs+=("$probe_output")
    if ! probe_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel debug \
            -f lavfi -i 'testsrc2=size=640x360:rate=30' \
            -frames:v 30 -an -c:v "${codec}_mediacodec" \
            -ndk_codec 1 -ndk_async 0 -b:v 2M \
            -y "$probe_output" 2>&1)"; then
        echo "$codec MediaCodec encoder probe failed." >&2
        printf '%s\n' "$probe_log" >&2
        return 1
    fi

    encoder_component="$(printf '%s\n' "$probe_log" \
        | sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' \
        | head -n 1)"
    if [[ -z "$encoder_component" || "$encoder_component" == c2.android.* ]]; then
        echo "$codec probe did not select a hardware encoder: ${encoder_component:-missing}" >&2
        return 1
    fi

    for frame_count in "${FRAME_COUNTS[@]}"; do
        local output="/data/local/tmp/ffmpeggui-${codec}-drain-${frame_count}.mp4"
        local encode_log
        local decode_log
        local locked_component
        local decoder_component
        local decoded_frames

        remote_outputs+=("$output")
        if ! encode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
                -hide_banner -loglevel debug \
                -f lavfi -i 'testsrc2=size=640x360:rate=30' \
                -frames:v "$frame_count" -an -c:v "${codec}_mediacodec" \
                -codec_name "$encoder_component" -ndk_codec 1 -ndk_async 0 -b:v 2M \
                -y "$output" 2>&1)"; then
            echo "$codec $frame_count-frame encode failed." >&2
            printf '%s\n' "$encode_log" >&2
            return 1
        fi

        locked_component="$(printf '%s\n' "$encode_log" \
            | sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' \
            | head -n 1)"
        if [[ "$locked_component" != "$encoder_component" ]]; then
            echo "$codec encoder lock mismatch: requested $encoder_component, got ${locked_component:-missing}." >&2
            return 1
        fi

        if ! decode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
                -hide_banner -loglevel verbose \
                -c:v "${codec}_mediacodec" -i "$output" \
                -f null - 2>&1)"; then
            echo "$codec $frame_count-frame MediaCodec decode failed." >&2
            printf '%s\n' "$decode_log" >&2
            return 1
        fi

        decoder_component="$(printf '%s\n' "$decode_log" \
            | sed -n 's/.*MediaCodec started successfully: codec = \([^,]*\),.*/\1/p' \
            | head -n 1)"
        decoded_frames="$(printf '%s\n' "$decode_log" \
            | sed -n 's/.*Input stream.*; \([0-9][0-9]*\) frames decoded.*/\1/p' \
            | tail -n 1)"

        if [[ -z "$decoder_component" || "$decoder_component" == c2.android.* ]]; then
            echo "$codec $frame_count-frame decode did not select a hardware component: ${decoder_component:-missing}." >&2
            return 1
        fi
        if [[ "$decoded_frames" != "$frame_count" ]]; then
            echo "$codec $frame_count-frame decode count mismatch: got ${decoded_frames:-missing}." >&2
            printf '%s\n' "$decode_log" >&2
            return 1
        fi

        printf '%-4s %2d frames: encode=%s decode=%s decoded=%s\n' \
            "$codec" "$frame_count" "$encoder_component" "$decoder_component" "$decoded_frames"
    done
}

test_codec h264
test_codec hevc
