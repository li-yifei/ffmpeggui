#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
readonly SCRIPT_DIR

readonly LOCK_FILE="$SCRIPT_DIR/sources-aio.lock"
readonly ANDROID_API="${ANDROID_API:-26}"
readonly NDK_ROOT="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-commandlinetools/ndk/29.0.14206865}"
readonly EXPECTED_NDK_REVISION="29.0.14206865"
readonly WORK_ROOT="${AIO_WORK_ROOT:-$SCRIPT_DIR/.build/aio}"
readonly DOWNLOAD_DIR="$WORK_ROOT/downloads"
readonly SOURCE_ROOT="$WORK_ROOT/source"
readonly BUILD_ROOT="$WORK_ROOT/build"
readonly PREFIX="$WORK_ROOT/prefix/arm64-v8a"
readonly STAGING_DIR="$WORK_ROOT/staging"
readonly OUTPUT_FILE="${AIO_OUTPUT_FILE:-$STAGING_DIR/libffmpeg.so}"
readonly REPRODUCIBLE_PREFIX="/ffmpeggui-aio"

readonly MEDIACODEC_DRAIN_PATCH="$SCRIPT_DIR/patches/0001-mediacodec-bound-decoder-drain.patch"
readonly MEDIACODEC_DRAIN_PATCH_SHA256="3904661ebc989d4b04b8358c498c66cade7f88050fa122cc88563afc0afae49c"
readonly MEDIACODEC_ENCODER_PATCH="$SCRIPT_DIR/patches/0002-mediacodec-avoid-ndk-encoder-flush.patch"
readonly MEDIACODEC_ENCODER_PATCH_SHA256="24b764eca149529d006d2802e10370e03d17f2def293b5a5cc52d61947e71099"
readonly MEDIACODEC_INPUT_PATCH="$SCRIPT_DIR/patches/0003-mediacodec-validate-encoder-input.patch"
readonly MEDIACODEC_INPUT_PATCH_SHA256="06affdce42468b7767acf98928ab4372e7332bcc925f39ec4ff61fc243f47488"
readonly X265_CMAKE_PATCH="$SCRIPT_DIR/patches/0004-x265-cmake-4-policy.patch"
readonly X265_CMAKE_PATCH_SHA256="36dc69c64a725c5208a412dc19226c7ca69b1d68f0b6098a430f7302221b5e25"
readonly LIBAOM_CONFIG_PATCH="$SCRIPT_DIR/patches/0005-libaom-stable-build-config.patch"
readonly LIBAOM_CONFIG_PATCH_SHA256="23853683262a3ab9a71f4c150edaaa7c207c2da128535cf596009a6a5b66c4ea"

case "$(uname -s)" in
    Darwin) readonly NDK_HOST="darwin-x86_64" ;;
    Linux) readonly NDK_HOST="linux-x86_64" ;;
    *) echo "Unsupported build host: $(uname -s)" >&2; exit 1 ;;
esac

readonly TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$NDK_HOST"
readonly SYSROOT="$TOOLCHAIN/sysroot"
readonly TARGET="aarch64-linux-android"
readonly TARGET_CC="$TOOLCHAIN/bin/${TARGET}${ANDROID_API}-clang"
readonly TARGET_CXX="$TOOLCHAIN/bin/${TARGET}${ANDROID_API}-clang++"
readonly TARGET_AR="$TOOLCHAIN/bin/llvm-ar"
readonly TARGET_NM="$TOOLCHAIN/bin/llvm-nm"
readonly TARGET_RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
readonly TARGET_READELF="$TOOLCHAIN/bin/llvm-readelf"
readonly TARGET_STRIP="$TOOLCHAIN/bin/llvm-strip"
readonly CMAKE="${CMAKE:-$(command -v cmake || true)}"
readonly NINJA="${NINJA:-$(command -v ninja || true)}"
RG="$(command -v rg || true)"
readonly RG

if [[ ! -x "$TARGET_CC" || ! -x "$TARGET_CXX" ]]; then
    echo "Android NDK compiler wrappers were not found under $TOOLCHAIN/bin." >&2
    exit 1
fi
if [[ -z "$CMAKE" || -z "$NINJA" || -z "$RG" || ! -x "$RG" ]]; then
    echo "cmake, ninja, and ripgrep are required to build and verify the AIO dependencies." >&2
    exit 1
fi
if ! grep -Eq "^Pkg.Revision[[:space:]]*=[[:space:]]*${EXPECTED_NDK_REVISION}[[:space:]]*$" \
        "$NDK_ROOT/source.properties"; then
    echo "Android NDK revision mismatch; expected $EXPECTED_NDK_REVISION." >&2
    exit 1
fi
if [[ ! -f "$LOCK_FILE" ]]; then
    echo "Source lock was not found: $LOCK_FILE" >&2
    exit 1
fi

if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.logicalcpu)"
else
    jobs="4"
fi
readonly jobs

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=1754870400
export ZERO_AR_DATE=1
export PATH="$TOOLCHAIN/bin:$PATH"
export ARFLAGS=crD
export CFLAGS="-O3 -fPIC -fvisibility=hidden -ffile-prefix-map=$WORK_ROOT=$REPRODUCIBLE_PREFIX -fmacro-prefix-map=$WORK_ROOT=$REPRODUCIBLE_PREFIX -fdebug-prefix-map=$WORK_ROOT=$REPRODUCIBLE_PREFIX"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

lock_field() {
    local component="$1"
    local field="$2"
    awk -F '|' -v component="$component" -v field="$field" \
        '$1 == component { print $field; found = 1; exit } END { if (!found) exit 1 }' \
        "$LOCK_FILE"
}

fetch_source() {
    local component="$1"
    local archive sha256 url
    archive="$(lock_field "$component" 4)"
    sha256="$(lock_field "$component" 5)"
    url="$(lock_field "$component" 6)"
    mkdir -p "$DOWNLOAD_DIR"
    if [[ ! -f "$DOWNLOAD_DIR/$archive" ]]; then
        curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \
            --output "$DOWNLOAD_DIR/$archive" "$url"
    fi
    actual_sha256="$(shasum -a 256 "$DOWNLOAD_DIR/$archive" | awk '{ print $1 }')"
    if [[ "$actual_sha256" != "$sha256" ]]; then
        echo "$component source checksum mismatch." >&2
        echo "Expected $sha256, got $actual_sha256" >&2
        exit 1
    fi
}

extract_source() {
    local component="$1"
    local archive strip source_dir
    archive="$(lock_field "$component" 4)"
    strip="$(lock_field "$component" 7)"
    source_dir="$SOURCE_ROOT/$component"
    mkdir -p "$source_dir"
    if [[ "$strip" == "0" ]]; then
        tar -xf "$DOWNLOAD_DIR/$archive" -C "$source_dir"
    else
        tar -xf "$DOWNLOAD_DIR/$archive" -C "$source_dir" --strip-components="$strip"
    fi
}

configure_make_install() {
    local source_dir="$1"
    shift
    local build_dir
    build_dir="$BUILD_ROOT/$(basename -- "$source_dir")"
    mkdir -p "$build_dir"
    (cd "$build_dir" && "$source_dir/configure" "$@")
    "$make_command" -C "$build_dir" -j"$jobs"
    "$make_command" -C "$build_dir" install
}

cmake_ninja_install() {
    local source_dir="$1"
    local build_name="$2"
    shift 2
    local build_dir="$BUILD_ROOT/$build_name"
    "$CMAKE" -S "$source_dir" -B "$build_dir" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK="$NDK_ROOT" \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API="$ANDROID_API" \
        -DCMAKE_ANDROID_STL_TYPE=c++_static \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS_RELEASE="$CFLAGS -DNDEBUG" \
        -DCMAKE_CXX_FLAGS_RELEASE="$CXXFLAGS -DNDEBUG" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
        "$@"
    "$NINJA" -C "$build_dir" -j"$jobs"
    "$NINJA" -C "$build_dir" install
}

write_pkgconfig_wrapper() {
    mkdir -p "$WORK_ROOT/host-bin"
    cat >"$WORK_ROOT/host-bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export PKG_CONFIG_DIR=
unset PKG_CONFIG_PATH
export PKG_CONFIG_SYSROOT_DIR="${AIO_PKG_CONFIG_SYSROOT:?}"
export PKG_CONFIG_LIBDIR="${AIO_PKG_CONFIG_LIBDIR:?}"
exec "${AIO_HOST_PKGCONF:?}" "$@"
EOF
    chmod 0755 "$WORK_ROOT/host-bin/pkg-config"
}

clean_pc_runtime_tokens() {
    local pc_file="$1"
    local temporary_file="${pc_file}.runtime-clean"
    awk '
        {
            output = ""
            for (field_index = 1; field_index <= NF; field_index++) {
                if ($field_index == "-lc++" || $field_index == "-lc++abi" ||
                    $field_index == "-lunwind" || $field_index == "-l:libunwind.a" ||
                    $field_index == "-l-l:libunwind.a" || $field_index == "abi") {
                    continue
                }
                output = output (output == "" ? "" : OFS) $field_index
            }
            print output
        }
    ' "$pc_file" >"$temporary_file"
    mv "$temporary_file" "$pc_file"
}

normalize_pkgconfig_prefixes() {
    local pc_file temporary_file
    while IFS= read -r -d '' pc_file; do
        temporary_file="${pc_file}.relocatable"
        awk -v build_prefix="$PREFIX" '
            {
                replacement = "${pcfiledir}/../.."
                while ((position = index($0, build_prefix)) != 0) {
                    $0 = substr($0, 1, position - 1) replacement \
                         substr($0, position + length(build_prefix))
                }
                print
            }
        ' "$pc_file" >"$temporary_file"
        mv "$temporary_file" "$pc_file"
    done < <(find "$PREFIX" -type f -name '*.pc' -print0)
}

assert_pkgconfig_isolated() {
    local -a pkgconfig_directories=()
    local directory
    for directory in "$PREFIX/lib/pkgconfig" "$PREFIX/share/pkgconfig"; do
        if [[ -d "$directory" ]]; then
            pkgconfig_directories+=("$directory")
        fi
    done
    if ((${#pkgconfig_directories[@]} == 0)); then
        return
    fi
    if "$RG" -n '/(opt/(homebrew|zerobrew)|Users/)' "${pkgconfig_directories[@]}"; then
        echo "Target pkg-config metadata references a host package prefix." >&2
        exit 1
    fi
    if "$RG" -n '(^|[[:space:]])(-lc\+\+abi|-lc\+\+|-lunwind|-l:libunwind\.a|-l-l:libunwind\.a|abi)([[:space:]]|$)' \
            "${pkgconfig_directories[@]}"; then
        echo "Target pkg-config metadata requests an explicit C++ runtime token." >&2
        exit 1
    fi
}

if command -v gmake >/dev/null 2>&1; then
    make_command="gmake"
else
    make_command="make"
fi
readonly make_command

for component in pkgconf freetype fribidi harfbuzz libass libaribcaption x264 x265 libvpx libaom ffmpeg; do
    fetch_source "$component"
done

# Build each run from freshly extracted sources and empty prefixes. Downloads are
# content-addressed by sources-aio.lock and remain cached.
if [[ -d "$SOURCE_ROOT" ]]; then
    find "$SOURCE_ROOT" -mindepth 1 -delete
fi
if [[ -d "$BUILD_ROOT" ]]; then
    find "$BUILD_ROOT" -mindepth 1 -delete
fi
if [[ -d "$PREFIX" ]]; then
    find "$PREFIX" -mindepth 1 -delete
fi
# A failed rebuild must never leave a previous staging candidate looking fresh.
if [[ -e "$OUTPUT_FILE" ]]; then
    rm -f -- "$OUTPUT_FILE"
fi
mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$PREFIX" "$STAGING_DIR"
for component in pkgconf freetype fribidi harfbuzz libass libaribcaption x264 x265 libvpx libaom ffmpeg; do
    extract_source "$component"
done

# pkgconf runs on the build host and is pinned so configure never reads host
# package metadata. All target .pc files live exclusively under PREFIX.
pkgconf_host_prefix="$WORK_ROOT/host-prefix"
if [[ -d "$pkgconf_host_prefix" ]]; then
    find "$pkgconf_host_prefix" -mindepth 1 -delete
fi
mkdir -p "$BUILD_ROOT/pkgconf-host" "$pkgconf_host_prefix"
(cd "$BUILD_ROOT/pkgconf-host" && \
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u ARFLAGS \
    "$SOURCE_ROOT/pkgconf/configure" \
        --prefix="$pkgconf_host_prefix" --disable-shared --enable-static)
env -u ARFLAGS "$make_command" -C "$BUILD_ROOT/pkgconf-host" -j"$jobs"
env -u ARFLAGS "$make_command" -C "$BUILD_ROOT/pkgconf-host" install
readonly HOST_PKGCONF="$pkgconf_host_prefix/bin/pkgconf"
export AIO_HOST_PKGCONF="$HOST_PKGCONF"
# The target .pc files use an isolated absolute prefix. A sysroot rewrite here
# would incorrectly prepend the NDK sysroot to that prefix.
export AIO_PKG_CONFIG_SYSROOT="/"
export AIO_PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH=
write_pkgconfig_wrapper
readonly PKG_CONFIG="$WORK_ROOT/host-bin/pkg-config"
export PKG_CONFIG

# FreeType: font rasterization base for libass and libaribcaption. Keep zlib
# support from the Android system and omit optional bzip2/png/brotli cycles.
configure_make_install "$SOURCE_ROOT/freetype" \
    --host="$TARGET" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --with-zlib=yes --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no \
    CC="$TARGET_CC" CXX="$TARGET_CXX" AR="$TARGET_AR" NM="$TARGET_NM" RANLIB="$TARGET_RANLIB"

configure_make_install "$SOURCE_ROOT/fribidi" \
    --host="$TARGET" --prefix="$PREFIX" \
    --disable-shared --enable-static --disable-deprecated \
    CC="$TARGET_CC" CXX="$TARGET_CXX" AR="$TARGET_AR" NM="$TARGET_NM" RANLIB="$TARGET_RANLIB"

cmake_ninja_install "$SOURCE_ROOT/harfbuzz" harfbuzz \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DFREETYPE_INCLUDE_DIRS="$PREFIX/include/freetype2" \
    -DFREETYPE_LIBRARY="$PREFIX/lib/libfreetype.a" \
    -DBUILD_SHARED_LIBS=OFF \
    -DHB_BUILD_UTILS=OFF -DHB_BUILD_SUBSET=OFF \
    -DHB_HAVE_CAIRO=OFF -DHB_HAVE_FREETYPE=ON -DHB_HAVE_GLIB=OFF \
    -DHB_HAVE_GOBJECT=OFF -DHB_HAVE_GRAPHITE2=OFF -DHB_HAVE_ICU=OFF

configure_make_install "$SOURCE_ROOT/libass" \
    --host="$TARGET" --prefix="$PREFIX" \
    --disable-shared --enable-static --disable-fontconfig --disable-libunibreak \
    --disable-require-system-font-provider --disable-test --disable-profile \
    CC="$TARGET_CC" CXX="$TARGET_CXX" AR="$TARGET_AR" NM="$TARGET_NM" RANLIB="$TARGET_RANLIB" \
    PKG_CONFIG="$PKG_CONFIG" \
    FREETYPE_CFLAGS="-I$PREFIX/include/freetype2" FREETYPE_LIBS="-L$PREFIX/lib -lfreetype -lz" \
    FRIBIDI_CFLAGS="-I$PREFIX/include/fribidi" FRIBIDI_LIBS="-L$PREFIX/lib -lfribidi" \
    HARFBUZZ_CFLAGS="-I$PREFIX/include/harfbuzz" HARFBUZZ_LIBS="-L$PREFIX/lib -lharfbuzz"

if "$RG" -n '/opt/(homebrew|zerobrew)' "$PREFIX/lib/pkgconfig" >/dev/null; then
    echo "Target pkg-config metadata unexpectedly references a host package prefix." >&2
    exit 1
fi
if "$RG" -n '/opt/zerobrew/Cellar/libunibreak|CONFIG_UNIBREAK 1' \
        "$BUILD_ROOT/libass/config.log" "$BUILD_ROOT/libass/config.h" >/dev/null; then
    echo "libass configure unexpectedly selected host libunibreak." >&2
    exit 1
fi
if "$TARGET_NM" -u "$PREFIX/lib/libass.a" 2>/dev/null | grep -i unibreak >/dev/null; then
    echo "libass unexpectedly references host libunibreak symbols." >&2
    exit 1
fi
normalize_pkgconfig_prefixes
assert_pkgconfig_isolated

# Keep bitmap caption rendering enabled. Android font lookup and the renderer
# reuse the same pinned static FreeType prefix; FetchContent stays disabled.
cmake_ninja_install "$SOURCE_ROOT/libaribcaption" libaribcaption \
    -DBUILD_SHARED_LIBS=OFF -DARIBCC_SHARED_LIBRARY=OFF \
    -DARIBCC_BUILD_TESTS=OFF -DARIBCC_NO_RENDERER=OFF \
    -DARIBCC_USE_EMBEDDED_FREETYPE=OFF \
    -DFREETYPE_INCLUDE_DIRS="$PREFIX/include/freetype2" \
    -DFREETYPE_LIBRARY="$PREFIX/lib/libfreetype.a" \
    -DCMAKE_PREFIX_PATH="$PREFIX"

# FFmpeg links the final CLI through clang++. Its -static-libstdc++ switch
# selects the NDK's static libc++ runtime. Keep the generated package metadata
# from requesting libc++_shared (and duplicate unwind) ahead of that switch.
clean_pc_runtime_tokens "$PREFIX/lib/pkgconfig/libaribcaption.pc"
normalize_pkgconfig_prefixes
assert_pkgconfig_isolated

mkdir -p "$BUILD_ROOT/x264"
(cd "$BUILD_ROOT/x264" && \
    CC="$TARGET_CC" CXX="$TARGET_CXX" AR="$TARGET_AR" RANLIB="$TARGET_RANLIB" STRIP="$TARGET_STRIP" \
    "$SOURCE_ROOT/x264/configure" \
        --host="$TARGET" --sysroot="$SYSROOT" \
        --prefix="$PREFIX" --enable-static --enable-pic --disable-cli \
        --disable-opencl --bit-depth=8 \
        --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS")
"$make_command" -C "$BUILD_ROOT/x264" -j"$jobs"
"$make_command" -C "$BUILD_ROOT/x264" install

actual_x265_patch_sha256="$(shasum -a 256 "$X265_CMAKE_PATCH" | awk '{ print $1 }')"
if [[ "$actual_x265_patch_sha256" != "$X265_CMAKE_PATCH_SHA256" ]]; then
    echo "x265 CMake patch checksum mismatch." >&2
    exit 1
fi
(cd "$SOURCE_ROOT/x265" && patch -p1 --forward --batch <"$X265_CMAKE_PATCH")

cmake_ninja_install "$SOURCE_ROOT/x265/source" x265 \
    -DCMAKE_C_COMPILER="$TARGET_CC" \
    -DCMAKE_CXX_COMPILER="$TARGET_CXX" \
    -DCMAKE_ASM_COMPILER="$TARGET_CC" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_TESTS=OFF \
    -DHIGH_BIT_DEPTH=OFF -DENABLE_HDR10_PLUS=OFF \
    -DENABLE_LIBVMAF=OFF -DENABLE_ASSEMBLY=ON \
    -DWARNINGS_AS_ERRORS=OFF -DAARCH64_WARNINGS_AS_ERRORS=OFF

x265_assembly_count=0
while IFS= read -r -d '' assembly_object; do
    x265_assembly_count=$((x265_assembly_count + 1))
    assembly_header="$("$TARGET_READELF" -h "$assembly_object")"
    if ! grep -Eq 'Machine:[[:space:]]*AArch64' <<<"$assembly_header"; then
        echo "x265 assembly is not an Android AArch64 ELF object: $assembly_object" >&2
        exit 1
    fi
done < <(find "$BUILD_ROOT/x265" -maxdepth 1 -type f -name '*.S.o' -print0)
if ((x265_assembly_count == 0)); then
    echo "x265 did not produce the expected AArch64 assembly objects." >&2
    exit 1
fi

clean_pc_runtime_tokens "$PREFIX/lib/pkgconfig/x265.pc"
# x265's generated private link list duplicates host-runtime discovery output.
# Keep only its actual Android system dependencies in deterministic order.
x265_pc="$PREFIX/lib/pkgconfig/x265.pc"
awk '/^Libs\.private:/ { print "Libs.private: -latomic -lm -ldl"; next } { print }' \
    "$x265_pc" >"${x265_pc}.normalized"
mv "${x265_pc}.normalized" "$x265_pc"
normalize_pkgconfig_prefixes
assert_pkgconfig_isolated

mkdir -p "$BUILD_ROOT/libvpx"
(cd "$BUILD_ROOT/libvpx" && \
    CC="$TARGET_CC" CXX="$TARGET_CXX" AR="$TARGET_AR" LD="$TARGET_CC" AS="$TARGET_CC" STRIP="$TARGET_STRIP" \
    CROSS="" "$SOURCE_ROOT/libvpx/configure" \
        --target=arm64-android-gcc --prefix="$PREFIX" \
        --disable-shared --enable-static --enable-pic \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --enable-vp8 --enable-vp9 --enable-runtime-cpu-detect)
libvpx_config_c="$BUILD_ROOT/libvpx/vpx_config.c"
awk '
    /^static const char\* const cfg = / {
        print "static const char* const cfg = \"arm64-android static VP8/VP9 encoder+decoder\";"
        next
    }
    { print }
' "$libvpx_config_c" >"${libvpx_config_c}.stable"
mv "${libvpx_config_c}.stable" "$libvpx_config_c"
if "$RG" -n '/Users/|Documents/Codex|native/ffmpeg/\.build|/opt/(homebrew|zerobrew)' \
        "$libvpx_config_c"; then
    echo "libvpx generated build configuration contains a host path." >&2
    exit 1
fi
"$make_command" -C "$BUILD_ROOT/libvpx" -j"$jobs"
"$make_command" -C "$BUILD_ROOT/libvpx" install
normalize_pkgconfig_prefixes
assert_pkgconfig_isolated

actual_libaom_patch_sha256="$(shasum -a 256 "$LIBAOM_CONFIG_PATCH" | awk '{ print $1 }')"
if [[ "$actual_libaom_patch_sha256" != "$LIBAOM_CONFIG_PATCH_SHA256" ]]; then
    echo "libaom stable build-config patch checksum mismatch." >&2
    exit 1
fi
(cd "$SOURCE_ROOT/libaom" && patch -p1 --forward --batch <"$LIBAOM_CONFIG_PATCH")

"$CMAKE" -S "$SOURCE_ROOT/libaom" -B "$BUILD_ROOT/libaom" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTDATA=OFF \
    -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF \
    -DCONFIG_AV1_DECODER=1 -DCONFIG_AV1_ENCODER=1 \
    -DCONFIG_WEBM_IO=0 -DCONFIG_LIBYUV=0 \
    -DCMAKE_C_FLAGS_RELEASE="$CFLAGS -DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="$CXXFLAGS -DNDEBUG"
if "$RG" -n '/Users/|Documents/Codex|native/ffmpeg/\.build|/opt/(homebrew|zerobrew)' \
        "$BUILD_ROOT/libaom/config/aom_config.c"; then
    echo "libaom generated build configuration contains a host path." >&2
    exit 1
fi
"$NINJA" -C "$BUILD_ROOT/libaom" -j"$jobs"
"$NINJA" -C "$BUILD_ROOT/libaom" install
normalize_pkgconfig_prefixes
assert_pkgconfig_isolated

for patch_spec in \
    "$MEDIACODEC_DRAIN_PATCH|$MEDIACODEC_DRAIN_PATCH_SHA256" \
    "$MEDIACODEC_ENCODER_PATCH|$MEDIACODEC_ENCODER_PATCH_SHA256" \
    "$MEDIACODEC_INPUT_PATCH|$MEDIACODEC_INPUT_PATCH_SHA256"; do
    patch_file="${patch_spec%%|*}"
    patch_sha256="${patch_spec##*|}"
    actual_patch_sha256="$(shasum -a 256 "$patch_file" | awk '{ print $1 }')"
    if [[ "$actual_patch_sha256" != "$patch_sha256" ]]; then
        echo "Patch checksum mismatch: $patch_file" >&2
        exit 1
    fi
    (cd "$SOURCE_ROOT/ffmpeg" && patch -p1 --forward --batch <"$patch_file")
done

# FFmpeg's version.sh prefers `git describe` over the tarball's RELEASE file.
# The source is extracted inside this repository's worktree, so without a
# VERSION file the CLI would report this repository's commit (for example
# "ffmpeg version 3594b02") and the binary digest would change with every
# unrelated commit. Pin the reported version to the locked FFmpeg tag.
ffmpeg_locked_tag="$(lock_field ffmpeg 2)"
printf '%s\n' "${ffmpeg_locked_tag#n}" >"$SOURCE_ROOT/ffmpeg/VERSION"

mkdir -p "$BUILD_ROOT/ffmpeg"
(
    cd "$BUILD_ROOT/ffmpeg"
    # Keep the configure string logical and host-independent. The wrapper is
    # found by its stable name; target headers/libraries come from isolated
    # pkg-config metadata. Compiler prefix maps remain in environment flags.
    export PATH="$WORK_ROOT/host-bin:$PATH"
    export CFLAGS="$CFLAGS"
    export CXXFLAGS="$CXXFLAGS"
    "$SOURCE_ROOT/ffmpeg/configure" \
        --prefix=/ffmpeggui/ffmpeg-9.0.2-gpl-aio \
        --target-os=android --arch=aarch64 --cpu=armv8-a \
        --enable-cross-compile \
        --cc="${TARGET}${ANDROID_API}-clang" \
        --cxx="${TARGET}${ANDROID_API}-clang++" \
        --ld="${TARGET}${ANDROID_API}-clang++" \
        --ar=llvm-ar --as="${TARGET}${ANDROID_API}-clang" \
        --nm=llvm-nm --ranlib=llvm-ranlib --strip=llvm-strip \
        --pkg-config=pkg-config \
        --pkg-config-flags=--static \
        --disable-autodetect --disable-doc --disable-debug \
        --disable-ffplay --disable-ffprobe --disable-shared \
        --enable-static --enable-pic --enable-gpl \
        --disable-version3 --disable-nonfree \
        --enable-jni --enable-mediacodec --enable-zlib \
        --enable-pthreads --enable-network --enable-neon \
        --enable-libass --enable-libaribcaption \
        --enable-libfreetype --enable-libfribidi --enable-libharfbuzz \
        --enable-libx264 --enable-libx265 \
        --enable-libvpx --enable-libaom \
        --disable-symver \
        --extra-cflags="-O3 -fPIC -fvisibility=hidden" \
        --extra-cxxflags="-O3 -fPIC -fvisibility=hidden" \
        --extra-ldflags="$LDFLAGS -static-libstdc++"
)

for expected_config in \
    CONFIG_GPL CONFIG_MPDECIMATE_FILTER CONFIG_PIXELUTILS \
    CONFIG_LIBASS CONFIG_ASS_FILTER CONFIG_SUBTITLES_FILTER \
    CONFIG_LIBFREETYPE CONFIG_LIBFRIBIDI CONFIG_LIBHARFBUZZ CONFIG_DRAWTEXT_FILTER \
    CONFIG_LIBARIBCAPTION CONFIG_LIBARIBCAPTION_DECODER \
    CONFIG_LIBX264 CONFIG_LIBX264_ENCODER \
    CONFIG_LIBX265 CONFIG_LIBX265_ENCODER \
    CONFIG_LIBVPX CONFIG_LIBVPX_VP9_ENCODER \
    CONFIG_LIBAOM CONFIG_LIBAOM_AV1_ENCODER; do
    if ! grep -Eq "^${expected_config}=yes$" "$BUILD_ROOT/ffmpeg/ffbuild/config.mak"; then
        echo "Required FFmpeg configure result is missing: $expected_config" >&2
        exit 1
    fi
done
for forbidden_config in CONFIG_VERSION3 CONFIG_NONFREE; do
    if grep -Eq "^${forbidden_config}=yes$" "$BUILD_ROOT/ffmpeg/ffbuild/config.mak"; then
        echo "Forbidden FFmpeg configure result is enabled: $forbidden_config" >&2
        exit 1
    fi
done

"$make_command" -C "$BUILD_ROOT/ffmpeg" -j"$jobs" ffmpeg
"$TARGET_STRIP" --strip-unneeded "$BUILD_ROOT/ffmpeg/ffmpeg"
install -m 0755 "$BUILD_ROOT/ffmpeg/ffmpeg" "$OUTPUT_FILE"
if ! AIO_CONFIG_MAK="$BUILD_ROOT/ffmpeg/ffbuild/config.mak" \
        "$SCRIPT_DIR/verify-android-arm64-aio.sh" "$OUTPUT_FILE"; then
    rm -f -- "$OUTPUT_FILE"
    echo "The staging AIO ELF failed its mandatory static release gate." >&2
    exit 1
fi

echo "Built staging AIO ELF: $OUTPUT_FILE"
shasum -a 256 "$OUTPUT_FILE"
wc -c "$OUTPUT_FILE"
echo "The app's checked-in libffmpeg.so was left unchanged. Promote only after verification."
