#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly BINARY="${FFMPEG_BINARY:-$PROJECT_ROOT/app/src/main/libs/arm64-v8a/libffmpeg.so}"
readonly REMOTE_BINARY="/data/local/tmp/ffmpeggui-ffmpeg-9.0.2-encoder-matrix"

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
probed_component=""

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

probe_component() {
    local codec="$1"
    local output="/data/local/tmp/ffmpeggui-${codec}-encoder-matrix-probe.mp4"
    local log
    local component

    remote_outputs+=("$output")
    if ! log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel debug \
            -f lavfi -i 'testsrc2=size=640x360:rate=30' \
            -frames:v 1 -an -c:v "${codec}_mediacodec" \
            -ndk_codec 1 -ndk_async 0 -b:v 2M -y "$output" 2>&1)"; then
        printf '%s\n' "$log" >&2
        return 1
    fi

    component="$(printf '%s\n' "$log" \
        | sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' \
        | head -n 1)"
    if [[ -z "$component" || "$component" == c2.android.* ]]; then
        echo "$codec probe did not select a hardware encoder: ${component:-missing}" >&2
        return 1
    fi
    probed_component="$component"
}

run_case() {
    local codec="$1"
    local component="$2"
    local async_mode="$3"
    local pixel_format="$4"
    local size="$5"
    local container="$6"
    local tag="${codec}-a${async_mode}-${pixel_format}-${size}-${container}"
    local output="/data/local/tmp/ffmpeggui-${tag}.${container}"
    local encode_log
    local decode_log
    local selected_component
    local decoder_component
    local decoded_frames

    remote_outputs+=("$output")
    if ! encode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel debug \
            -f lavfi -i "testsrc2=size=${size}:rate=30" \
            -frames:v 30 -an -c:v "${codec}_mediacodec" \
            -codec_name "$component" -ndk_codec 1 -ndk_async "$async_mode" \
            -pix_fmt "$pixel_format" -b:v 2M -y "$output" 2>&1)"; then
        echo "$tag encode failed." >&2
        printf '%s\n' "$encode_log" >&2
        return 1
    fi

    selected_component="$(printf '%s\n' "$encode_log" \
        | sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' \
        | head -n 1)"
    if [[ "$selected_component" != "$component" ]]; then
        echo "$tag encoder lock mismatch: requested $component, got ${selected_component:-missing}." >&2
        return 1
    fi
    if grep -E 'MediaCodec input buffer is too small|Failed to queue MediaCodec input buffer' \
            <<<"$encode_log" >/dev/null; then
        echo "$tag hit a MediaCodec input-buffer error." >&2
        printf '%s\n' "$encode_log" >&2
        return 1
    fi

    if ! decode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel verbose \
            -c:v "${codec}_mediacodec" -i "$output" \
            -f null - 2>&1)"; then
        echo "$tag decode failed." >&2
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
        echo "$tag did not use a hardware decoder: ${decoder_component:-missing}." >&2
        return 1
    fi
    if [[ "$decoded_frames" != "30" ]]; then
        echo "$tag decoded ${decoded_frames:-missing} frames; expected 30." >&2
        return 1
    fi
    if ! grep -F "$size" <<<"$decode_log" >/dev/null; then
        echo "$tag did not report the expected display size $size." >&2
        printf '%s\n' "$decode_log" >&2
        return 1
    fi

    printf '%-35s encode=%s decode=%s frames=%s\n' \
        "$tag" "$component" "$decoder_component" "$decoded_frames"
}

run_surface_case() {
    local async_mode="$1"
    local input="/data/local/tmp/ffmpeggui-h264-a0-yuv420p-640x360-mp4.mp4"
    local output="/data/local/tmp/ffmpeggui-surface-h264-hevc-a${async_mode}.mp4"
    local transcode_log
    local verify_log
    local encoder_component
    local decoder_component
    local decoded_frames

    remote_outputs+=("$output")
    if ! transcode_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel debug \
            -hwaccel mediacodec -hwaccel_output_format mediacodec -i "$input" \
            -frames:v 30 -an -c:v hevc_mediacodec \
            -codec_name "$hevc_component" -ndk_codec 1 -ndk_async "$async_mode" \
            -b:v 2M -y "$output" 2>&1)"; then
        echo "surface-h264-hevc-a${async_mode} transcode failed." >&2
        printf '%s\n' "$transcode_log" >&2
        return 1
    fi

    encoder_component="$(printf '%s\n' "$transcode_log" \
        | sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' \
        | head -n 1)"
    decoder_component="$(printf '%s\n' "$transcode_log" \
        | sed -n 's/.*MediaCodec started successfully: codec = \([^,]*\),.*/\1/p' \
        | head -n 1)"
    if [[ "$encoder_component" != "$hevc_component" ]]; then
        echo "surface-h264-hevc-a${async_mode} encoder lock mismatch." >&2
        return 1
    fi
    if [[ -z "$decoder_component" || "$decoder_component" == c2.android.* ]]; then
        echo "surface-h264-hevc-a${async_mode} did not use a hardware decoder." >&2
        return 1
    fi

    if ! verify_log="$("${adb_device[@]}" shell "$REMOTE_BINARY" \
            -hide_banner -loglevel verbose \
            -c:v hevc_mediacodec -i "$output" -f null - 2>&1)"; then
        echo "surface-h264-hevc-a${async_mode} output verification failed." >&2
        printf '%s\n' "$verify_log" >&2
        return 1
    fi
    decoded_frames="$(printf '%s\n' "$verify_log" \
        | sed -n 's/.*Input stream.*; \([0-9][0-9]*\) frames decoded.*/\1/p' \
        | tail -n 1)"
    if [[ "$decoded_frames" != "30" ]]; then
        echo "surface-h264-hevc-a${async_mode} decoded ${decoded_frames:-missing} frames; expected 30." >&2
        return 1
    fi

    printf '%-35s encode=%s decode=%s frames=%s\n' \
        "surface-h264-hevc-a${async_mode}" "$encoder_component" \
        "$decoder_component" "$decoded_frames"
}

probe_component h264
h264_component="$probed_component"
probe_component hevc
hevc_component="$probed_component"

for codec in h264 hevc; do
    if [[ "$codec" == "h264" ]]; then
        component="$h264_component"
    else
        component="$hevc_component"
    fi
    for async_mode in 0 1; do
        run_case "$codec" "$component" "$async_mode" yuv420p 640x360 mp4
        run_case "$codec" "$component" "$async_mode" nv12 640x360 mp4
        run_case "$codec" "$component" "$async_mode" yuv420p 638x358 mp4
    done
done

run_case h264 "$h264_component" 0 yuv420p 640x360 h264
run_surface_case 0
run_surface_case 1
