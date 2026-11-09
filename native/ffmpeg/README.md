# FFmpeg Android arm64 build

The app ships one standalone FFmpeg CLI executable at
`app/src/main/libs/arm64-v8a/libffmpeg.so`. The `.so` suffix makes Android's
native-library packaging extract the executable into `nativeLibraryDir`; the
file itself is an AArch64 PIE command-line program. The standard Release uses
the GPL AIO build described here.

## Pinned inputs

- FFmpeg tag: `n9.0.2`
- FFmpeg commit: `946fcce07b6dcd0331c8cc609192aeff5e1924f8`
- Android NDK: r29 (`29.0.14206865`)
- Minimum Android API used by the native build: 26
- ABI: `arm64-v8a`
- Local MediaCodec decoder drain patch:
  `patches/0001-mediacodec-bound-decoder-drain.patch`
  (SHA-256 `3904661ebc989d4b04b8358c498c66cade7f88050fa122cc88563afc0afae49c`)
- Local NDK encoder global-header patch:
  `patches/0002-mediacodec-avoid-ndk-encoder-flush.patch`
  (SHA-256 `24b764eca149529d006d2802e10370e03d17f2def293b5a5cc52d61947e71099`)
- Local MediaCodec encoder input-validation patch:
  `patches/0003-mediacodec-validate-encoder-input.patch`
  (SHA-256 `06affdce42468b7767acf98928ab4372e7332bcc925f39ec4ff61fc243f47488`)
- Local x265 CMake 4 compatibility patch:
  `patches/0004-x265-cmake-4-policy.patch`
  (SHA-256 `36dc69c64a725c5208a412dc19226c7ca69b1d68f0b6098a430f7302221b5e25`)
- Local libaom reproducible build-config patch:
  `patches/0005-libaom-stable-build-config.patch`
  (SHA-256 `23853683262a3ab9a71f4c150edaaa7c207c2da128535cf596009a6a5b66c4ea`)
- Full dependency archive/commit/digest lock:
  [`sources-aio.lock`](sources-aio.lock)

The source lock currently selects pkgconf 2.5.1, FreeType 2.14.1, FriBidi
1.0.16, HarfBuzz 11.4.5, libass 0.17.4, libaribcaption 1.1.2, x264 build 165,
x265 4.1+1/API build 215, libvpx 1.16.0, libaom 3.13.1, and FFmpeg 9.0.2.
Every fetched archive is verified before extraction.

## Standard GPL AIO capability and license profile

The standard build uses
`--enable-gpl --disable-version3 --disable-nonfree`. The resulting standalone
FFmpeg executable is GNU GPL version 2 or later. FDK AAC and every other
FFmpeg `nonfree` component stay outside this build.

The AIO feature set includes:

- FFmpeg's default internal codecs, muxers, demuxers, protocols, bitstream
  filters, and GPL-compatible filters, including `mpdecimate`, `cropdetect`,
  `delogo`, `eq`, `hqdn3d`, `perspective`, `pullup`, `smartblur`, `stereo3d`,
  and `tinterlace`;
- FreeType, FriBidi, HarfBuzz, and libass, enabling `drawtext`, `ass`, and
  `subtitles`;
- libaribcaption decoding in ASS and bitmap modes, with its FreeType renderer
  and Android system-font provider enabled;
- 8-bit H.264 through `libx264`, 8-bit HEVC through `libx265`, VP8/VP9 through
  libvpx, and AV1 through libaom;
- JNI and H.264/HEVC/VP9/AV1 MediaCodec paths for vendor hardware and Android
  system-software components.

Fontconfig and libunibreak are excluded from the Android build. Use an explicit
`fontfile` for `drawtext`; use subtitle font attachments or an explicit
`fontsdir` for libass workflows. The libaribcaption Android provider reads the
device system font configuration when bitmap rendering is selected.

All listed third-party libraries and the NDK C++ runtime are folded into one
PIE executable. The dynamic dependency allowlist contains Android platform
libraries only; `libc++_shared.so` and third-party codec `.so` files are absent.
The applicable notices are in
[`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md). Gradle copies
that index and the complete `third_party/licenses/` directory into each APK at
`assets/legal/third_party/licenses/`; the FDK AAC notice remains informational
because the standard executable excludes FDK AAC.

## Build

From the repository root:

```sh
./native/ffmpeg/build-android-arm64-aio.sh
```

The default NDK path is
`/opt/homebrew/share/android-commandlinetools/ndk/29.0.14206865`. Override it
when needed:

```sh
ANDROID_NDK_ROOT=/absolute/path/to/android-ndk-r29 \
  ./native/ffmpeg/build-android-arm64-aio.sh
```

The host also needs CMake, Ninja, GNU Make, pkg-config build prerequisites,
and ripgrep; the script treats a missing scanner as a failed isolation gate.

Sources and intermediate objects are kept under the ignored
`native/ffmpeg/.build/aio/` directory. Downloaded, digest-verified archives are
cached; sources, build trees, and the target prefix start clean on every run.
The script checks the exact NDK revision, patch digests, target architecture,
pkg-config isolation, and required or forbidden FFmpeg configuration values;
it also builds x264/x265 with position-independent AArch64 assembly. Stable tool
names, compiler prefix maps,
relocatable target `.pc` metadata, and a logical install prefix keep host
checkout paths out of the final executable.

The stripped staging artifact is written to:

```text
native/ffmpeg/.build/aio/staging/libffmpeg.so
```

The build intentionally leaves
`app/src/main/libs/arm64-v8a/libffmpeg.so` unchanged. Verify the staging file,
repeat the clean build to confirm its digest when preparing a Release, then
promote that exact verified file and update the recorded final digest.

FFmpeg 8.1.2 and 9.0.2 can return `EAGAIN` after a MediaCodec output-format event even
though decoder drain has started. The ffmpeg CLI correctly treats `EAGAIN`
during flush as a decoder contract violation and aborts. The local patch keeps
dequeueing transient MediaCodec events for at most four blocking attempts
(four seconds total). A codec that exhausts the limit returns a decoding error
and ends its drain, keeping the failure bounded. FFmpeg master commit
`03dc244a693ce639cebf82f7bae112fb75580919`, checked on 2026-08-12, still has
the same drain behavior and contains no equivalent fix. Between `n8.1.2` and
`n9.0.2`, `libavcodec/mediacodecenc.c` is byte-identical and
`libavcodec/mediacodecdec_common.c` only gains a MediaTek MPEG-2 slice-height
quirk, so all three MediaCodec patches still apply unchanged (patch 0001 with
a two-line offset) and remain necessary.

FFmpeg 8.1.2's and 9.0.2's synchronous NDK global-header probe queues a dummy frame and
EOS, then flushes the encoder before the first real frame. Android defines
flush recovery for decoders; encoder behavior is undefined. On the Pixel 10
Pro XL / Tensor G5, the next input reaches Codec2 status 95 and FFmpeg returns
`AVERROR_EXTERNAL`. Patch 0002 routes synchronous NDK encoding through the
existing `extract_extradata` bitstream-filter path, matching the asynchronous
NDK path and avoiding the encoder flush. See Android's
[`MediaCodec.flush()` contract](https://developer.android.com/reference/android/media/MediaCodec#flush()).

Patch 0003 checks the NDK encoder input-buffer pointer and capacity, propagates
queue failures with their raw status, and records EOS only after MediaCodec
accepts it. The patch preserves the encoder's existing payload-size behavior.

The linker flags set both maximum and common ELF page size to 16KB. This keeps
the packaged executable compatible with Android devices using either 4KB or
16KB memory pages.

## Verify

```sh
./native/ffmpeg/verify-android-arm64-aio.sh
```

The AIO verifier checks the AArch64 PIE header, every load segment's 16KB
alignment, Android-system-only `DT_NEEDED` entries, host-path sanitization,
required GPL flags, absence of nonfree/version3/FDK markers, and the required
filters, text stack, broadcast-caption decoder, software encoders, and
MediaCodec components. When the clean build's `ffbuild/config.mak` is present,
it independently checks each required and forbidden configuration value.

Pin a candidate digest at a promotion or release gate with:

```sh
EXPECTED_AIO_SHA256=<candidate-sha256> \
  ./native/ffmpeg/verify-android-arm64-aio.sh \
  app/src/main/libs/arm64-v8a/libffmpeg.so
```

For direct runtime inspection on an authorized device:

```sh
adb push native/ffmpeg/.build/aio/staging/libffmpeg.so \
  /data/local/tmp/ffmpeggui-ffmpeg-9.0.2-gpl-aio
adb shell chmod 0755 /data/local/tmp/ffmpeggui-ffmpeg-9.0.2-gpl-aio
adb shell /data/local/tmp/ffmpeggui-ffmpeg-9.0.2-gpl-aio -hide_banner -version
adb shell /data/local/tmp/ffmpeggui-ffmpeg-9.0.2-gpl-aio -hide_banner -encoders \
  | grep -E 'libx264|libx265|libvpx-vp9|libaom-av1'
adb shell /data/local/tmp/ffmpeggui-ffmpeg-9.0.2-gpl-aio -hide_banner -filters \
  | grep -E 'mpdecimate|drawtext|ass|subtitles'
adb shell /data/local/tmp/ffmpeggui-ffmpeg-9.0.2-gpl-aio \
  -hide_banner -h decoder=libaribcaption
```

Capability listings prove registration. Exercise all four bundled software
presets with a short representative input and decode/probe each output. Test
`drawtext` with an explicit real font file, test `subtitles`/`ass` with an
explicit `fontsdir` or attached fonts, and use a real ARIB transport-stream
sample for both the default ASS result and `-sub_type bitmap` renderer path.

The MediaCodec scripts below select an exact authorized device through
`ANDROID_SERIAL` when several adb devices are attached. Their temporary files
stay under `/data/local/tmp`, and they leave installed apps and app/user data
untouched.

Actual hardware codec availability is device-specific. Confirm the codecs
exposed by Android with `adb shell dumpsys media.codec` and test the selected
codec with representative input. Snapdragon 8 Elite and Tensor G5 devices can
advertise different codec names, profiles, levels, color formats, and limits.

For a repeatable on-device encode/decode smoke test:

```sh
./native/ffmpeg/smoke-test-mediacodec.sh
```

The smoke test requires H.264 and HEVC MediaCodec encode/decode to complete,
prints the actual Android codec components selected, and rejects Android's
`c2.android.*` reference software encoders for those required codecs. VP9 and
AV1 are tested and reported as optional because current SoCs can expose their
hardware decoders alongside Android reference software encoders. All
temporary files stay under `/data/local/tmp` and are removed when the test
exits. Set `ANDROID_SERIAL` when more than one adb device is attached; run the
same test once on the Snapdragon 8 Elite device and once on the Tensor G5
device.

Run the short-stream drain regression matrix separately:

```sh
./native/ffmpeg/test-short-mediacodec-drain.sh
```

It hardware-encodes and hardware-decodes H.264 and HEVC streams containing
1, 3, 9, 10, 11, and 30 frames. Every case must exit successfully, use vendor
hardware components in both directions, and report the exact expected decoded
frame count. The test catches the former `ffmpeg_dec.c` drain assertion at its
real CLI/MediaCodec seam.

Run the encoder input and surface-chain regression matrix with:

```sh
./native/ffmpeg/test-mediacodec-encoder-matrix.sh
```

For H.264 and HEVC, it covers synchronous and asynchronous NDK operation,
`yuv420p` and `nv12`, 640x360 and the unaligned 638x358 shape, and verifies
30/30 frames through hardware decode. It also covers a raw H.264 elementary
stream and synchronous/asynchronous MediaCodec surface transcoding
from H.264 to HEVC. Encoder locks, hardware decoder selection, input-buffer
errors, dimensions, and decoded frame counts are checked in every applicable
case.

Run the pixel-quality regression with:

```sh
./native/ffmpeg/test-mediacodec-quality.sh
```

This test generates a deterministic H.264 fixture at the deliberately
unaligned 1228x720 shape, transcodes it through MediaCodec hardware decode and
planar HEVC/AV1 MediaCodec encode, then pulls the results for host-side SSIM
and PSNR analysis. HEVC is required. AV1 skips only when FFmpeg explicitly
reports that Android has no `video/av01` MediaCodec encoder; every other AV1
failure fails the test. Set `REQUIRE_AV1=1` on a device known to expose a
hardware AV1 encoder, as used for Pixel validation:

```sh
REQUIRE_AV1=1 ANDROID_SERIAL=<device-serial> \
  ./native/ffmpeg/test-mediacodec-quality.sh
```

The default acceptance thresholds are SSIM 0.95 and PSNR 30 dB; they detect
horizontal row displacement and green bands even when dimensions, timestamps,
and frame count remain valid. The host FFmpeg must provide `libx264`, `ssim`,
and `psnr`.

## Lock a MediaCodec encoder component

Android can expose a hardware implementation and a reference software
implementation for the same MIME type. Query the device first with
`HardwareCodecSelector`, then pass the returned encoder component to FFmpeg's
private `-codec_name` option:

```text
-c:v h264_mediacodec -codec_name c2.qti.avc.encoder -ndk_codec 1
-c:v hevc_mediacodec -codec_name c2.qti.hevc.encoder -ndk_codec 1
```

The `c2.qti.*` names above are examples from the tested Snapdragon device.
The tested Tensor G5 exposes `c2.google.avc.encoder` and
`c2.google.hevc.encoder`; its matching decoders also use `c2.google.*`. Other
vendors expose different names. The read-only helper at
`app/src/main/java/com/silentlexx/ffmpeggui_os/model/HardwareCodecSelector.java`
uses Android's hardware flag on API 29+ and can also check whether a component
advertises the requested width, height, frame rate, and planar/flexible YUV420
input. A semiplanar-only component is rejected before command execution.

Built-in H.264, HEVC, VP9, and AV1 templates expose a separate Android system
software fallback. The app enumerates components marked software-only (or
known reference names on older APIs), locks the selected `c2.android.*` or
equivalent component, and removes its internal policy option immediately
before process execution. The same AIO binary therefore supports vendor
hardware and Android system software without SoC-specific builds.

FFmpeg 9.0.2 exposes `-codec_name` for MediaCodec encoders. Its MediaCodec
decoder wrapper lets Android select the component; use `-hwaccel mediacodec`
before `-i` to select that decoder path. The smoke test prints the component
that Android actually selected for both directions and then repeats each
encoder test locked to that exact component.

## Final GPL AIO artifact and historical MediaCodec evidence

On 2026-11-09 BRT, the promoted FFmpeg 9.0.2 GPL AIO staging artifact passed
`verify-android-arm64-aio.sh` and `verify-android-arm64.sh` (device run
included). Two clean builds produced the same bytes, one of them from a
different repository commit: the build now writes FFmpeg's `VERSION` file from
the locked tag, so the binary reports `ffmpeg version 9.0.2` and its digest no
longer depends on this repository's `git describe` output.

```text
SHA-256 3435fbd16c5d2ba37a790c155bd2274fc0d3c2ccc755af49b828511837fa4504
Size    36,332,064 bytes
```

This exact artifact passed all four device scripts on a Samsung SM-A576B
(Exynos s5e8865, Android 17/API 37), selecting `c2.exynos.*` hardware
components for H.264, HEVC, and VP9; see
[`verification/Exynos-s5e8865-SM-A576B-2026-11-09.log`](verification/Exynos-s5e8865-SM-A576B-2026-11-09.log).
That log also records the quality-harness colour-tag fix and an 8.1.2 versus
9.0.2 throughput comparison.

The previous FFmpeg 8.1.2 GPL AIO artifact (2026-08-12 JST) reported its
version as a repository commit hash (`3594b02`):

```text
SHA-256 3e0eaf750cda7b06be48a1eb2f34714b5fc4854a90b0f2c635c09c2080288133
Size    36,179,200 bytes
```

The device logs in this repository predate the GPL AIO link graph. They test
the same pinned FFmpeg commit and the same three MediaCodec source patches, so
they are historical evidence for the hardware-codec fixes and app policy. They
do not claim byte-for-byte device execution of the final GPL AIO artifact.

The previous minimal LGPL/MediaCodec build produced this path-sanitized
artifact in two consecutive clean builds:

```text
SHA-256 785431d8f3fa65371c4ebf208e059b42a01d9de90086d858035675a9a6e73663
Size    21,593,576 bytes
```

The actual Snapdragon and Tensor device testing used its
pre-path-sanitization counterpart:

```text
SHA-256 b06219d3f85e32be5fa2cb843eba028ef9001ae3df2203f183e0bbca92e0e2d5
Size    21,593,672 bytes
```

Compiler prefix maps replace local checkout paths in compiled strings, which
changed that historical binary's digest while leaving its feature source and
three patches unchanged. The device results below record the `b06219d3...`
artifact that actually ran on Snapdragon and Tensor. The modern3 build and
signing record for the historical path-sanitized artifact is in
[`verification/modern3-release-2026-08-12.log`](verification/modern3-release-2026-08-12.log).

`verify-android-arm64.sh` confirmed the historical artifact as an AArch64 PIE
executable with 16KB alignment, Android/NDK-only dynamic dependencies, FFmpeg
8.1.2 runtime execution, and the common codec/format/filter/protocol set. The
Snapdragon 8 Elite testing selected Qualcomm `c2.qti.*` hardware components
for H.264/HEVC encode and decode. AV1 decode selected `c2.qti.av1.decoder`,
while AV1 encode selected Android's `c2.android.av1.encoder` software
component. Tensor G5 testing selected `c2.google.*` hardware components for
H.264, HEVC, and AV1 encode and decode. Both devices passed the earlier
synchronous/asynchronous encoder matrix, including 638x358, raw H.264, and
hardware H.264-to-HEVC surface chains at 30/30 frames. A later full-length
1228x720 input exposed a Tensor G5 flexible-NV12 ByteBuffer stride mismatch:
Android negotiated 1248x736 while FFmpeg wrote a tightly packed layout. The
app now forces planar `yuv420p` for every MediaCodec encoder command. Pixel
quality validation with the same unaligned shape produced HEVC SSIM 0.999304 /
PSNR 52.728940 dB and AV1 SSIM 0.999240 / PSNR 52.272864 dB.

The Tensor G5 short-stream matrix also produced exact decoded counts for 1, 3,
9, 10, 11, and 30 frames in both H.264 and HEVC. Device records are in
[`verification/SM8750P-2026-08-12.log`](verification/SM8750P-2026-08-12.log)
and
[`verification/Tensor-G5-Pixel-10-Pro-XL-2026-08-12.log`](verification/Tensor-G5-Pixel-10-Pro-XL-2026-08-12.log).
The Tensor pixel-quality record is in
[`verification/Tensor-G5-planar-quality-2026-08-12.log`](verification/Tensor-G5-planar-quality-2026-08-12.log).
The Lenovo system-software matrix locked H.264, HEVC, VP9, and AV1 to their
respective `c2.android.*.encoder` components and produced 12/12 frames for all
four; see
[`verification/SM8750P-system-software-2026-08-12.log`](verification/SM8750P-system-software-2026-08-12.log).

## Optional local FDK AAC recipe

`build-android-arm64-fdk-local.sh` is a separate, default-off developer recipe.
It requires two explicit acknowledgements before it fetches FDK AAC or enables
FFmpeg's `--enable-libfdk-aac --enable-nonfree` pair. Its output is isolated
under a local directory marked `DO-NOT-DISTRIBUTE`; the script keeps that file
outside the standard staging path and the app's `jniLibs`/Release inputs.
The recipe pins FDK AAC tag `v2.0.3`, peeled commit
`716f4394641d53f0d79c9ddac3fa93b03a49f278`, and official tag-archive SHA-256
`e25671cd96b10bad896aa42ab91a695a9e573395262baed4e4a2ff178d6a3a78`.

FFmpeg 9.0.2 classifies FDK AAC in its external nonfree list and states that an
FDK-enabled GPL combination is unredistributable. The FDK notice grants no
express or implied patent license, so local builders remain responsible for
patent authorization appropriate to their use. Standard builds and AIO
verification fail when `CONFIG_NONFREE`, `CONFIG_LIBFDK_AAC`,
`--enable-nonfree`, or `--enable-libfdk-aac` appears.

See [`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) and the full
upstream FDK text at
[`../../third_party/licenses/FDK-AAC-NOTICE.txt`](../../third_party/licenses/FDK-AAC-NOTICE.txt).

## Distribution notices

The standard native executable is GNU GPL version 2 or later. A distributor
must accompany it with GPLv2-compliant complete corresponding source. Preserve
the locked upstream sources, all five local patches, the build and verifier
scripts, and the license/patent texts referenced by
[`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

These native notices grant rights for the FFmpeg executable and listed
dependencies. The Android application source retains the upstream repository's
unspecified licensing status; this fork adds no separate application-code
license grant.
