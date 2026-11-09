#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${ENABLE_FDK_AAC:-}" != "1" || "${ALLOW_NONREDISTRIBUTABLE:-}" != "1" ]]; then
    echo "This local-only recipe requires both acknowledgements:" >&2
    echo "  ENABLE_FDK_AAC=1 ALLOW_NONREDISTRIBUTABLE=1 $0" >&2
    echo "FDK AAC grants no patent license; FFmpeg marks this GPL/FDK build nonfree." >&2
    exit 1
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR
readonly STANDARD_ROOT="$SCRIPT_DIR/.build/aio"
readonly STANDARD_PREFIX="$STANDARD_ROOT/prefix/arm64-v8a"
readonly STANDARD_SOURCE="$STANDARD_ROOT/source/ffmpeg"
readonly STANDARD_BINARY="$STANDARD_ROOT/staging/libffmpeg.so"
readonly LOCAL_ROOT="$SCRIPT_DIR/.build/nonredistributable"
readonly DOWNLOAD_DIR="$LOCAL_ROOT/downloads"
readonly SOURCE_ROOT="$LOCAL_ROOT/source"
readonly BUILD_ROOT="$LOCAL_ROOT/build"
readonly PREFIX="$LOCAL_ROOT/prefix/arm64-v8a"
readonly OUTPUT_DIR="$LOCAL_ROOT/DO-NOT-DISTRIBUTE"
readonly OUTPUT_FILE="$OUTPUT_DIR/libffmpeg-fdk.so"

readonly FDK_VERSION="2.0.3"
readonly FDK_COMMIT="716f4394641d53f0d79c9ddac3fa93b03a49f278"
readonly FDK_ARCHIVE="fdk-aac-2.0.3.tar.gz"
readonly FDK_SHA256="e25671cd96b10bad896aa42ab91a695a9e573395262baed4e4a2ff178d6a3a78"
readonly FDK_URL="https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v2.0.3.tar.gz"

readonly ANDROID_API=26
readonly NDK_ROOT="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-commandlinetools/ndk/29.0.14206865}"
readonly EXPECTED_NDK_REVISION="29.0.14206865"
case "$(uname -s)" in
    Darwin) readonly NDK_HOST="darwin-x86_64" ;;
    Linux) readonly NDK_HOST="linux-x86_64" ;;
    *) echo "Unsupported build host: $(uname -s)" >&2; exit 1 ;;
esac

readonly TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$NDK_HOST"
readonly TARGET="aarch64-linux-android"
readonly TARGET_CC="$TOOLCHAIN/bin/${TARGET}${ANDROID_API}-clang"
readonly TARGET_CXX="$TOOLCHAIN/bin/${TARGET}${ANDROID_API}-clang++"
readonly TARGET_AR="$TOOLCHAIN/bin/llvm-ar"
readonly TARGET_RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
readonly TARGET_STRIP="$TOOLCHAIN/bin/llvm-strip"
readonly CMAKE="${CMAKE:-$(command -v cmake || true)}"
readonly NINJA="${NINJA:-$(command -v ninja || true)}"
readonly PATCH_COMMAND="${PATCH_COMMAND:-$(command -v patch || true)}"

if [[ ! -x "$TARGET_CC" || ! -x "$TARGET_CXX" || -z "$CMAKE" ||
        -z "$NINJA" || -z "$PATCH_COMMAND" ]]; then
    echo "Pinned Android NDK compilers, cmake, ninja, and patch are required." >&2
    exit 1
fi
if ! grep -Eq "^Pkg.Revision[[:space:]]*=[[:space:]]*${EXPECTED_NDK_REVISION}[[:space:]]*$" \
        "$NDK_ROOT/source.properties"; then
    echo "Android NDK revision mismatch; expected $EXPECTED_NDK_REVISION." >&2
    exit 1
fi
if [[ ! -f "$STANDARD_BINARY" || ! -f "$STANDARD_ROOT/build/ffmpeg/ffbuild/config.mak" ||
        ! -d "$STANDARD_PREFIX" || ! -d "$STANDARD_SOURCE" ]]; then
    echo "Build and verify the standard AIO staging binary before this local recipe." >&2
    exit 1
fi
"$SCRIPT_DIR/verify-android-arm64-aio.sh" "$STANDARD_BINARY"

if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.logicalcpu)"
else
    jobs=4
fi
if command -v gmake >/dev/null 2>&1; then
    make_command=gmake
else
    make_command="make"
fi

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=1754870400
export ZERO_AR_DATE=1
export ARFLAGS=crD
export CFLAGS="-O3 -fPIC -fvisibility=hidden -ffile-prefix-map=$LOCAL_ROOT=/ffmpeggui-fdk-local -fmacro-prefix-map=$LOCAL_ROOT=/ffmpeggui-fdk-local -fdebug-prefix-map=$LOCAL_ROOT=/ffmpeggui-fdk-local -ffile-prefix-map=$STANDARD_ROOT=/ffmpeggui-aio -fmacro-prefix-map=$STANDARD_ROOT=/ffmpeggui-aio -fdebug-prefix-map=$STANDARD_ROOT=/ffmpeggui-aio"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

mkdir -p "$DOWNLOAD_DIR"
if [[ ! -f "$DOWNLOAD_DIR/$FDK_ARCHIVE" ]]; then
    curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \
        --output "$DOWNLOAD_DIR/$FDK_ARCHIVE" "$FDK_URL"
fi
actual_fdk_sha256="$(shasum -a 256 "$DOWNLOAD_DIR/$FDK_ARCHIVE" | awk '{ print $1 }')"
if [[ "$actual_fdk_sha256" != "$FDK_SHA256" ]]; then
    echo "FDK AAC source checksum mismatch." >&2
    echo "Expected $FDK_SHA256, got $actual_fdk_sha256" >&2
    exit 1
fi

for directory in "$SOURCE_ROOT" "$BUILD_ROOT" "$PREFIX"; do
    if [[ -d "$directory" ]]; then
        find "$directory" -mindepth 1 -delete
    fi
done
mkdir -p "$SOURCE_ROOT/fdk-aac" "$BUILD_ROOT/fdk-aac" \
    "$BUILD_ROOT/ffmpeg" "$PREFIX" "$OUTPUT_DIR"
rm -f -- "$OUTPUT_FILE"
tar -xf "$DOWNLOAD_DIR/$FDK_ARCHIVE" -C "$SOURCE_ROOT/fdk-aac" --strip-components=1

# The upstream Android platform build has access to the private log/log.h API.
# Standalone NDK applications do not, and these two calls only emit SafetyNet
# diagnostics. Keep them available to platform builds behind an explicit macro.
(cd "$SOURCE_ROOT/fdk-aac" && "$PATCH_COMMAND" -p1 --forward --batch <<'PATCH'
--- a/libSBRdec/src/lpp_tran.cpp
+++ b/libSBRdec/src/lpp_tran.cpp
@@ -118,7 +118,7 @@
   \sa lppTransposer(), main_audio.cpp, sbr_scale.h, \ref documentationOverview
 */
 
-#ifdef __ANDROID__
+#if defined(__ANDROID__) && defined(FDK_ANDROID_PLATFORM_PRIVATE_LOG)
 #include "log/log.h"
 #endif
 
@@ -334,7 +334,7 @@ void lppTransposer(HANDLE_SBR_LPP_TRANS hLppTrans, FIXP_DBL **qmfBufferReal,
       }
     }
   }
-#ifdef __ANDROID__
+#if defined(__ANDROID__) && defined(FDK_ANDROID_PLATFORM_PRIVATE_LOG)
   else {
     // Safetynet logging
     android_errorWriteLog(0x534e4554, "112160868");
@@ -930,7 +930,7 @@ void lppTransposerHBE(HANDLE_SBR_LPP_TRANS hLppTrans,
       FDKmemclear(&qmfBufferImag[i][targetStopBand], memSize);
     }
   }
-#ifdef __ANDROID__
+#if defined(__ANDROID__) && defined(FDK_ANDROID_PLATFORM_PRIVATE_LOG)
   else {
     // Safetynet logging
     android_errorWriteLog(0x534e4554, "112160868");
PATCH
)
private_log_guard_count="$(grep -Fc \
    '#if defined(__ANDROID__) && defined(FDK_ANDROID_PLATFORM_PRIVATE_LOG)' \
    "$SOURCE_ROOT/fdk-aac/libSBRdec/src/lpp_tran.cpp")"
if [[ "$private_log_guard_count" != "3" ]] || \
        grep -Fx '#ifdef __ANDROID__' \
            "$SOURCE_ROOT/fdk-aac/libSBRdec/src/lpp_tran.cpp" >/dev/null; then
    echo "The FDK standalone Android private-log patch did not apply completely." >&2
    exit 1
fi

# Reuse the already verified standard dependency closure. All copied .pc files
# are relocatable; FDK and the nonfree FFmpeg build stay inside LOCAL_ROOT.
(cd "$STANDARD_PREFIX" && tar -cf - .) | (cd "$PREFIX" && tar -xf -)

"$CMAKE" -S "$SOURCE_ROOT/fdk-aac" -B "$BUILD_ROOT/fdk-aac" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Android \
    -DCMAKE_ANDROID_NDK="$NDK_ROOT" \
    -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
    -DCMAKE_ANDROID_API="$ANDROID_API" \
    -DCMAKE_ANDROID_STL_TYPE=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_COMPILER="$TARGET_CC" \
    -DCMAKE_CXX_COMPILER="$TARGET_CXX" \
    -DCMAKE_AR="$TARGET_AR" -DCMAKE_RANLIB="$TARGET_RANLIB" \
    -DCMAKE_C_FLAGS_RELEASE="$CFLAGS -DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="$CXXFLAGS -DNDEBUG" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_PROGRAMS=OFF \
    -DFDK_AAC_INSTALL_CMAKE_CONFIG_MODULE=OFF \
    -DFDK_AAC_INSTALL_PKGCONFIG_MODULE=ON
"$NINJA" -C "$BUILD_ROOT/fdk-aac" -j"$jobs"
"$NINJA" -C "$BUILD_ROOT/fdk-aac" install

fdk_pc="$PREFIX/lib/pkgconfig/fdk-aac.pc"
awk -v build_prefix="$PREFIX" '
    {
        replacement = "${pcfiledir}/../.."
        while ((position = index($0, build_prefix)) != 0) {
            $0 = substr($0, 1, position - 1) replacement \
                 substr($0, position + length(build_prefix))
        }
        print
    }
' "$fdk_pc" >"${fdk_pc}.relocatable"
mv "${fdk_pc}.relocatable" "$fdk_pc"

readonly HOST_PKGCONF="$STANDARD_ROOT/host-prefix/bin/pkgconf"
readonly PKG_CONFIG_WRAPPER="$STANDARD_ROOT/host-bin/pkg-config"
if [[ ! -x "$HOST_PKGCONF" || ! -x "$PKG_CONFIG_WRAPPER" ]]; then
    echo "The standard AIO pinned pkgconf tools are missing." >&2
    exit 1
fi
export AIO_HOST_PKGCONF="$HOST_PKGCONF"
export AIO_PKG_CONFIG_SYSROOT=/
export AIO_PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH
export PATH="$STANDARD_ROOT/host-bin:$TOOLCHAIN/bin:$PATH"

(cd "$BUILD_ROOT/ffmpeg" && \
    "$STANDARD_SOURCE/configure" \
        --prefix=/ffmpeggui/ffmpeg-9.0.2-gpl-aio-fdk-local \
        --target-os=android --arch=aarch64 --cpu=armv8-a \
        --enable-cross-compile \
        --cc="${TARGET}${ANDROID_API}-clang" \
        --cxx="${TARGET}${ANDROID_API}-clang++" \
        --ld="${TARGET}${ANDROID_API}-clang++" \
        --ar=llvm-ar --as="${TARGET}${ANDROID_API}-clang" \
        --nm=llvm-nm --ranlib=llvm-ranlib --strip=llvm-strip \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --disable-autodetect --disable-doc --disable-debug \
        --disable-ffplay --disable-ffprobe --disable-shared \
        --enable-static --enable-pic --enable-gpl \
        --disable-version3 --enable-nonfree --enable-libfdk-aac \
        --enable-jni --enable-mediacodec --enable-zlib \
        --enable-pthreads --enable-network --enable-neon \
        --enable-libass --enable-libaribcaption \
        --enable-libfreetype --enable-libfribidi --enable-libharfbuzz \
        --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom \
        --disable-symver \
        --extra-cflags="-O3 -fPIC -fvisibility=hidden" \
        --extra-cxxflags="-O3 -fPIC -fvisibility=hidden" \
        --extra-ldflags="$LDFLAGS -static-libstdc++")

readonly FDK_CONFIG_MAK="$BUILD_ROOT/ffmpeg/ffbuild/config.mak"
for required_config in CONFIG_GPL CONFIG_NONFREE CONFIG_LIBFDK_AAC \
        CONFIG_LIBFDK_AAC_ENCODER CONFIG_LIBFDK_AAC_DECODER; do
    if ! grep -Fx -- "${required_config}=yes" "$FDK_CONFIG_MAK" >/dev/null; then
        echo "Required local FDK configuration is missing: $required_config" >&2
        exit 1
    fi
done

"$make_command" -C "$BUILD_ROOT/ffmpeg" -j"$jobs" ffmpeg
"$TARGET_STRIP" --strip-unneeded "$BUILD_ROOT/ffmpeg/ffmpeg"
install -m 0755 "$BUILD_ROOT/ffmpeg/ffmpeg" "$OUTPUT_FILE"

if ! env FDK_CONFIG_MAK="$FDK_CONFIG_MAK" \
        "$SCRIPT_DIR/verify-android-arm64-fdk-local.sh" "$OUTPUT_FILE"; then
    rm -f -- "$OUTPUT_FILE"
    echo "The local FDK ELF failed its mandatory technical gate." >&2
    exit 1
fi
cat >"$OUTPUT_DIR/README-DO-NOT-DISTRIBUTE.txt" <<EOF
This FFmpeg binary contains FDK AAC and is marked nonfree by FFmpeg.
It is for explicitly acknowledged local testing only. Do not redistribute it.
FDK tag: v$FDK_VERSION
FDK commit: $FDK_COMMIT
FDK archive SHA-256: $FDK_SHA256
EOF

echo "Built local nonredistributable FDK AAC binary: $OUTPUT_FILE"
shasum -a 256 "$OUTPUT_FILE"
wc -c "$OUTPUT_FILE"
echo "DO NOT DISTRIBUTE. This recipe never writes the app native-library path."
