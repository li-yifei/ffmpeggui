# Third-party notices

This notice describes the third-party native code used by the standard Android
Release. Exact archive URLs, commits, and SHA-256 digests are recorded in
[`native/ffmpeg/sources-aio.lock`](native/ffmpeg/sources-aio.lock). The complete
license and patent texts copied from the pinned upstream sources are under
[`third_party/licenses/`](third_party/licenses/).

The Android build packages this file as
`assets/legal/THIRD_PARTY_NOTICES.md` and packages the complete license
directory as `assets/legal/third_party/licenses/`, preserving every relative
license link in this index. Repository and build-recipe links remain available
in this source repository. `FDK-AAC-NOTICE.txt` is included for information
about the separate local recipe; the standard executable excludes FDK AAC and
all `nonfree` code.

## Standard FFmpeg GPL AIO executable

The Android package contains one statically composed FFmpeg command-line
executable built from FFmpeg tag `n9.0.2`, commit
`946fcce07b6dcd0331c8cc609192aeff5e1924f8`. The build passes
`--enable-gpl --disable-version3 --disable-nonfree`. `mpdecimate`, x264, and
x265 activate FFmpeg's GPL terms, so the complete resulting native executable
is distributed under GNU GPL version 2 or later.

- Upstream source: <https://github.com/FFmpeg/FFmpeg/tree/946fcce07b6dcd0331c8cc609192aeff5e1924f8>
- Full GPLv2 text: [`third_party/licenses/GPL-2.0.txt`](third_party/licenses/GPL-2.0.txt)
- Exact upstream license overview: [`third_party/licenses/FFmpeg-LICENSE.md`](third_party/licenses/FFmpeg-LICENSE.md)
- Upstream license overview: <https://github.com/FFmpeg/FFmpeg/blob/946fcce07b6dcd0331c8cc609192aeff5e1924f8/LICENSE.md>
- Local build and corresponding-source instructions:
  [`native/ffmpeg/README.md`](native/ffmpeg/README.md)

The local build applies three MediaCodec fixes to
`libavcodec/mediacodecdec_common.c` and `libavcodec/mediacodecenc.c`. It also
applies one build-system compatibility patch to the pinned x265 source and one
reproducible build-configuration patch to the pinned libaom source. All five
patches, their expected SHA-256 digests, and the full build recipe are stored
under [`native/ffmpeg/`](native/ffmpeg/).

Anyone redistributing the executable must provide the complete corresponding
source in a form that satisfies GPLv2 section 3. Release archives should retain
the exact locked upstream source archives together with this repository's
scripts and patches, or provide an equivalent GPLv2-compliant source offer.

The executable reports its license and embedded configure options through
`ffmpeg -L`, `ffmpeg -version`, and `ffmpeg -buildconf`.

FFmpeg contains adapted code in `libavcodec/jfdctfst.c`,
`libavcodec/jfdctint_template.c`, and `libavcodec/jrevdct.c`. This software is
based in part on the work of the Independent JPEG Group. FFmpeg's versions
contain additions, deletions, and integration changes relative to the IJG
sources; this project applies no further patch to those three files. The exact
upstream overview and the complete corresponding source preserve their
copyright, warranty, permission, and change-notice terms.

## Statically linked runtime components

### FreeType 2.14.1

FreeType is dual-licensed. This GPLv2-or-later executable selects FreeType's
GNU GPL version 2 or later option. FreeType provides glyph rasterization for
HarfBuzz, libass, `drawtext`, and the libaribcaption renderer.

- Source: <https://download.savannah.gnu.org/releases/freetype/freetype-2.14.1.tar.xz>
- License choice: [`third_party/licenses/FreeType-LICENSE.txt`](third_party/licenses/FreeType-LICENSE.txt)
- Selected full GPL text: [`third_party/licenses/FreeType-GPL-2.0.txt`](third_party/licenses/FreeType-GPL-2.0.txt)
- Compiled BDF driver notice: [`third_party/licenses/FreeType-BDF-README.txt`](third_party/licenses/FreeType-BDF-README.txt)
- Compiled PCF driver notice: [`third_party/licenses/FreeType-PCF-README.txt`](third_party/licenses/FreeType-PCF-README.txt)

### FriBidi 1.0.16

FriBidi is licensed under GNU LGPL version 2.1 or later and supplies Unicode
bidirectional processing to libass and `drawtext`.

- Source: <https://github.com/fribidi/fribidi/tree/v1.0.16>
- Full license: [`third_party/licenses/FriBidi-COPYING.txt`](third_party/licenses/FriBidi-COPYING.txt)

### HarfBuzz 11.4.5

HarfBuzz uses its Old MIT license and supplies text shaping plus its FreeType
integration. The generated Universal Shaping Engine data also carries the
Microsoft MIT notice copied below.

- Source: <https://github.com/harfbuzz/harfbuzz/tree/11.4.5>
- HarfBuzz license: [`third_party/licenses/HarfBuzz-COPYING.txt`](third_party/licenses/HarfBuzz-COPYING.txt)
- Microsoft USE data notice: [`third_party/licenses/HarfBuzz-ms-use-COPYING.txt`](third_party/licenses/HarfBuzz-ms-use-COPYING.txt)

### libass 0.17.4

libass is licensed under the ISC license and implements ASS/SSA subtitle
rendering used by FFmpeg's `ass` and `subtitles` filters.

- Source: <https://github.com/libass/libass/tree/0.17.4>
- Full license: [`third_party/licenses/libass-COPYING.txt`](third_party/licenses/libass-COPYING.txt)

### libaribcaption 1.1.2

libaribcaption is licensed under the MIT license. The build includes its
decoder, FreeType renderer, and Android system-font provider. Its compiled
Android provider includes TinyXML2 under the zlib license; its compiled decoder
includes Solar Designer's public-domain/permissive MD5 implementation.

- Source: <https://github.com/xqq/libaribcaption/tree/v1.1.2>
- Main license: [`third_party/licenses/libaribcaption-LICENSE.txt`](third_party/licenses/libaribcaption-LICENSE.txt)
- TinyXML2 notice: [`third_party/licenses/TinyXML2-zlib-license.txt`](third_party/licenses/TinyXML2-zlib-license.txt)
- MD5 notice: [`third_party/licenses/Solar-Designer-MD5-notice.txt`](third_party/licenses/Solar-Designer-MD5-notice.txt)

### x264 build 165

The pinned x264 stable commit
`b35605ace3ddf7c1a5d67a2eb553f034aef41d55` is used under GNU GPL version 2
or later. This build supplies the 8-bit `libx264` encoder.

- Source: <https://code.videolan.org/videolan/x264/-/tree/b35605ace3ddf7c1a5d67a2eb553f034aef41d55>
- Upstream copying file: [`third_party/licenses/x264-COPYING.txt`](third_party/licenses/x264-COPYING.txt)

### x265 4.1+1, API build 215

The pinned x265 commit
`1d117bed4747758b51bd2c124d738527e30392cb` is used under GNU GPL version 2
or later. This build supplies the 8-bit `libx265` encoder. x265 also offers a
separate commercial licensing path; this Release uses the GPL path.

- Source archive: <https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.1.tar.gz>
- Upstream copying file: [`third_party/licenses/x265-COPYING.txt`](third_party/licenses/x265-COPYING.txt)

### libvpx 1.16.0

libvpx is licensed under the three-clause BSD license and includes Google's
Additional IP Rights Grant. The grant contains defensive-termination terms.
This build supplies VP8 and VP9 support, including `libvpx-vp9` encoding.

- Source: <https://github.com/webmproject/libvpx/tree/v1.16.0>
- Full copyright license: [`third_party/licenses/libvpx-LICENSE.txt`](third_party/licenses/libvpx-LICENSE.txt)
- Full patent grant: [`third_party/licenses/libvpx-PATENTS.txt`](third_party/licenses/libvpx-PATENTS.txt)

### libaom 3.13.1

libaom is licensed under the two-clause BSD license and the Alliance for Open
Media Patent License 1.0. The patent license requires reproduction with binary
implementations and contains reciprocity and defensive-termination terms. The
compiled encoder also contains FastFeat under the three-clause BSD license and
the `vector` utility under the MIT license.

- Source: <https://aomedia.googlesource.com/aom/+/refs/tags/v3.13.1>
- Full copyright license: [`third_party/licenses/libaom-LICENSE.txt`](third_party/licenses/libaom-LICENSE.txt)
- Full patent license: [`third_party/licenses/libaom-PATENTS.txt`](third_party/licenses/libaom-PATENTS.txt)
- FastFeat license: [`third_party/licenses/libaom-fastfeat-LICENSE.txt`](third_party/licenses/libaom-fastfeat-LICENSE.txt)
- Vector license: [`third_party/licenses/libaom-vector-LICENSE.txt`](third_party/licenses/libaom-vector-LICENSE.txt)

### Android NDK r29 static C++ runtime

The single executable statically links the Android NDK libc++/libc++abi and
unwind runtime selected by the pinned NDK `29.0.14206865`. LLVM components use
Apache License 2.0 with LLVM Exceptions; the complete prebuilt-toolchain notice
also carries the applicable bundled third-party terms.

- Full NDK LLVM notice: [`third_party/licenses/Android-NDK-r29-LLVM-NOTICE.txt`](third_party/licenses/Android-NDK-r29-LLVM-NOTICE.txt)
- Full NDK package notice: [`third_party/licenses/Android-NDK-r29-NOTICE.txt`](third_party/licenses/Android-NDK-r29-NOTICE.txt)

Android platform libraries such as `libc`, `libm`, `libdl`, `libz`,
`libandroid`, and `libmediandk` remain dynamic system dependencies supplied by
the device.

## Build-only component

pkgconf 2.5.1 runs on the build host to isolate cross-compilation metadata. Its
code is absent from the Android executable.

- Source: <https://github.com/pkgconf/pkgconf/tree/pkgconf-2.5.1>
- ISC license: [`third_party/licenses/pkgconf-COPYING.txt`](third_party/licenses/pkgconf-COPYING.txt)

## Optional local FDK AAC recipe

Fraunhofer FDK AAC is excluded from the standard Release. The default-off
`native/ffmpeg/build-android-arm64-fdk-local.sh` recipe, when explicitly
activated through both acknowledgements, creates a local FFmpeg combination
with `--enable-libfdk-aac --enable-nonfree`. FFmpeg identifies that GPL/FDK
combination as unredistributable. Its output is marked `DO-NOT-DISTRIBUTE` and
is kept outside APK and Release staging.

The optional recipe pins tag `v2.0.3`, peeled commit
`716f4394641d53f0d79c9ddac3fa93b03a49f278`, and official tag-archive SHA-256
`e25671cd96b10bad896aa42ab91a695a9e573395262baed4e4a2ff178d6a3a78`.

The FDK copyright license grants no express or implied patent license. Local
builders remain responsible for appropriate patent authorization. The notice
also requires complete license reproduction and free corresponding source when
FDK binaries are redistributed; the standard project policy retains these
artifacts locally.

- Official source: <https://github.com/mstorsjo/fdk-aac/tree/v2.0.3>
- Full informational notice: [`third_party/licenses/FDK-AAC-NOTICE.txt`](third_party/licenses/FDK-AAC-NOTICE.txt)

## Application source status

These notices cover the bundled native executable and listed dependencies.
The application source retains the upstream repository's unspecified licensing
status. This fork adds no separate application-code license grant.
