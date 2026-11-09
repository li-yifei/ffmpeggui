#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly PROJECT_ROOT
readonly BINARY="${FFMPEG_BINARY:-$PROJECT_ROOT/app/src/main/libs/arm64-v8a/libffmpeg.so}"
readonly HOST_FFMPEG="${HOST_FFMPEG:-ffmpeg}"
readonly WIDTH=1228
readonly HEIGHT=720
readonly FRAMES=90
readonly MIN_SSIM="${MIN_SSIM:-0.95}"
readonly MIN_PSNR="${MIN_PSNR:-30.0}"
readonly REQUIRE_AV1="${REQUIRE_AV1:-0}"
readonly RUN_ID="$$"
readonly REMOTE_PREFIX="/data/local/tmp/ffmpeggui-quality-$RUN_ID"
readonly REMOTE_BINARY="$REMOTE_PREFIX-ffmpeg"
readonly REMOTE_SOURCE="$REMOTE_PREFIX-source.mp4"

case "$REQUIRE_AV1" in
    0 | 1) ;;
    *)
        echo "REQUIRE_AV1 must be 0 or 1." >&2
        exit 1
        ;;
esac

if [[ ! -f "$BINARY" ]]; then
    echo "FFmpeg binary was not found: $BINARY" >&2
    exit 1
fi
if ! command -v "$HOST_FFMPEG" >/dev/null 2>&1; then
    echo "Host FFmpeg was not found: $HOST_FFMPEG" >&2
    exit 1
fi
if ! "$HOST_FFMPEG" -hide_banner -encoders 2>/dev/null | grep -F libx264 >/dev/null; then
    echo "Host FFmpeg must provide libx264 for the deterministic H.264 fixture." >&2
    exit 1
fi

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    DEVICE_SERIAL="$ANDROID_SERIAL"
else
    connected_devices="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
    device_count="$(printf '%s\n' "$connected_devices" | awk 'NF { count++ } END { print count + 0 }')"
    if [[ "$device_count" != "1" ]]; then
        echo "Connect exactly one authorized adb device or set ANDROID_SERIAL." >&2
        exit 1
    fi
    DEVICE_SERIAL="$(printf '%s\n' "$connected_devices" | awk 'NF { print; exit }')"
fi
readonly DEVICE_SERIAL

LOCAL_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeggui-quality.XXXXXX")"
readonly LOCAL_WORK
readonly LOCAL_SOURCE="$LOCAL_WORK/source.mp4"
adb_device=(adb -s "$DEVICE_SERIAL")
remote_files=("$REMOTE_BINARY" "$REMOTE_SOURCE")
local_files=("$LOCAL_SOURCE")

cleanup() {
    "${adb_device[@]}" shell rm -f "${remote_files[@]}" >/dev/null 2>&1 || true
    rm -f "${local_files[@]}" >/dev/null 2>&1 || true
    rmdir "$LOCAL_WORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$HOST_FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=30000/1001" \
    -frames:v "$FRAMES" -an -c:v libx264 -preset veryfast -crf 10 \
    -pix_fmt yuv420p "$LOCAL_SOURCE"

"${adb_device[@]}" push "$BINARY" "$REMOTE_BINARY" >/dev/null
"${adb_device[@]}" push "$LOCAL_SOURCE" "$REMOTE_SOURCE" >/dev/null
"${adb_device[@]}" shell chmod 0755 "$REMOTE_BINARY"

model="$("${adb_device[@]}" shell getprop ro.product.model | tr -d '\r')"
soc="$("${adb_device[@]}" shell getprop ro.soc.model | tr -d '\r')"
api="$("${adb_device[@]}" shell getprop ro.build.version.sdk | tr -d '\r')"
echo "Device: $model; SoC: $soc; API: $api"
echo "Fixture: ${WIDTH}x${HEIGHT}, $FRAMES frames; thresholds: SSIM >= $MIN_SSIM, PSNR >= $MIN_PSNR dB"

metric_at_least() {
    local actual="$1"
    local minimum="$2"
    awk -v actual="$actual" -v minimum="$minimum" 'BEGIN { exit !(actual + 0 >= minimum + 0) }'
}

run_quality_case() {
    local codec="$1"
    local requirement="$2"
    local remote_output="$REMOTE_PREFIX-$codec.mp4"
    local local_output="$LOCAL_WORK/$codec.mp4"
    local encode_log="$LOCAL_WORK/$codec-encode.log"
    local metric_log="$LOCAL_WORK/$codec-metrics.log"
    local component
    local ssim
    local psnr

    remote_files+=("$remote_output")
    local_files+=("$local_output" "$encode_log" "$metric_log")

    if ! "${adb_device[@]}" shell timeout 120 "$REMOTE_BINARY" \
            -hide_banner -loglevel debug \
            -hwaccel mediacodec -i "$REMOTE_SOURCE" \
            -frames:v "$FRAMES" -an -c:v "${codec}_mediacodec" \
            -ndk_codec 1 -ndk_async 0 -pix_fmt yuv420p -b:v 8M \
            -y "$remote_output" >"$encode_log" 2>&1; then
        if [[ "$requirement" == "optional" && "$codec" == "av1" ]] &&
                grep -F 'Failed to create encoder for type video/av01' "$encode_log" >/dev/null; then
            echo "$codec: skipped; Android reports no video/av01 MediaCodec encoder."
            return 0
        fi
        echo "$codec MediaCodec quality encode failed." >&2
        sed -n '1,240p' "$encode_log" >&2
        return 1
    fi

    component="$(sed -n 's/.*MediaCodec encoder \([^ ]*\) output format.*/\1/p' "$encode_log" | head -n 1)"
    if [[ -n "$component" && "$requirement" == "optional" ]] &&
            [[ "$component" == c2.android.* || "$component" == OMX.google.* ]]; then
        echo "$codec: skipped; Android selected the reference software component $component (no hardware encoder)."
        return 0
    fi
    if [[ -z "$component" || "$component" == c2.android.* || "$component" == OMX.google.* ]]; then
        echo "$codec selected a reference/software component: ${component:-unknown}." >&2
        return 1
    fi
    if ! grep -F 'yuv420p' "$encode_log" >/dev/null; then
        echo "$codec did not negotiate the required planar yuv420p input." >&2
        sed -n '1,240p' "$encode_log" >&2
        return 1
    fi

    "${adb_device[@]}" pull "$remote_output" "$local_output" >/dev/null
    # Some encoders (e.g. c2.exynos.*) tag their output as BT.709 limited range
    # while the fixture is untagged. Without identical tags, the host filter
    # graph inserts a colorspace conversion before ssim/psnr and the metrics
    # measure that conversion instead of the encoder. Compare raw samples.
    local metric_tags='setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709'
    if ! "$HOST_FFMPEG" -hide_banner -loglevel info \
            -i "$LOCAL_SOURCE" -i "$local_output" \
            -lavfi "[0:v]settb=AVTB,setpts=PTS-STARTPTS,$metric_tags,split=2[rs][rp];[1:v]settb=AVTB,setpts=PTS-STARTPTS,$metric_tags,split=2[ds][dp];[rs][ds]ssim;[rp][dp]psnr" \
            -frames:v "$FRAMES" -f null - >"$metric_log" 2>&1; then
        echo "$codec host quality analysis failed." >&2
        sed -n '1,240p' "$metric_log" >&2
        return 1
    fi

    ssim="$(sed -n 's/.*All:\([0-9.][0-9.]*\).*/\1/p' "$metric_log" | tail -n 1)"
    psnr="$(sed -n 's/.*average:\([0-9.][0-9.]*\).*/\1/p' "$metric_log" | tail -n 1)"
    if [[ -z "$ssim" || -z "$psnr" ]]; then
        echo "$codec quality metrics were missing." >&2
        sed -n '1,240p' "$metric_log" >&2
        return 1
    fi
    if ! metric_at_least "$ssim" "$MIN_SSIM" || ! metric_at_least "$psnr" "$MIN_PSNR"; then
        echo "$codec quality regression: component=$component SSIM=$ssim PSNR=$psnr." >&2
        return 1
    fi

    echo "$codec: component=$component SSIM=$ssim PSNR=${psnr}dB"
}

run_quality_case hevc required
if [[ "$REQUIRE_AV1" == "1" ]]; then
    run_quality_case av1 required
else
    run_quality_case av1 optional
fi
