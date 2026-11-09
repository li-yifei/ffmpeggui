# FFmpegGUI OS

FFmpegGUI OS is a community-maintained Android edition of
[FFmpegGUI](https://play.google.com/store/apps/details?id=com.silentlexx.ffmpeggui).
It provides a direct FFmpeg command workflow for Android and runs independently
of Google Play services.

## Added in this fork

The original project provides the GUI, Console, batch-processing, and direct
FFmpeg workflow. This fork adds the following features and modernization work:

- **FFmpeg 9.0.2 GPL AIO runtime for arm64 Android.** One bundled executable
  works across supported Snapdragon, Tensor, Exynos, and MediaTek devices.
  Android's runtime codec inventory lets the same arm64 binary serve every
  supported SoC family, while bundled x264, x265, libvpx, and libaom encoders
  provide device-independent software paths.
- **Capability-gated MediaCodec encoding and decoding.** H.264, HEVC, VP9, and
  AV1 hardware paths are detected at runtime. The app checks Android's
  hardware/software flags, MIME support, color formats, resolution, and frame
  rate before locking FFmpeg to a concrete codec component.
- **Hardware and Android system-software fallback modes.** Each of the four
  main video codecs has a hardware template and a system-provided software
  fallback template. The selected policy survives preview, Console editing,
  batch jobs, and the final execution check.
- **Modern FFmpeg 8 templates.** The built-in list focuses on H.264, HEVC, AV1,
  and VP9, with MP4/WebM stream-copy options plus AAC, Opus, and FLAC audio
  output. A versioned preset migration updates historical built-ins while
  preserving user-created presets and manual commands.
- **Portable bundled software encoding.** Four dedicated presets expose H.264
  through libx264, HEVC through libx265, VP9 through libvpx-vp9, and AV1 through
  libaom-av1. They run independently of Android codec availability and remain
  available as a portable fallback when a vendor or system MediaCodec path is
  unsuitable.
- **Text, subtitle, broadcast-caption, and GPL filters.** The AIO runtime adds
  FreeType, FriBidi, HarfBuzz, and libass for `drawtext`, `ass`, and `subtitles`,
  plus the libaribcaption decoder with its Android/FreeType bitmap renderer.
  `mpdecimate` and FFmpeg's commonly used GPL built-in filters are enabled.
- **Tensor G5 MediaCodec quality protection.** MediaCodec encoder commands are
  normalized to planar `yuv420p`, preventing flexible-YUV stride corruption on
  unaligned video widths. The regression suite measures decoded output with
  SSIM and PSNR alongside process-exit validation.
- **Gemini 3.x command planning.** The AI workflow supports configurable
  OpenAI-compatible endpoints, endpoint-discovered model IDs, a custom model
  ID, and BYOK one-shot FFmpeg command generation. API keys are protected
  by Android Keystore AES-GCM storage. An incomplete BYOK configuration safely
  opens the settings flow.
- **Private offline AI workflow.** Users can copy a complete prompt to their own
  AI chat, paste a result, or read it directly from the clipboard. Bounded media
  metadata is included while absolute paths and filenames are replaced with
  one-time, session-bound placeholders that restore the original files locally.
  Bindings expire after 24 hours and reject replay or cross-session results.
- **AI and command execution safeguards.** Generated commands are restricted to
  one local input and output, checked for protocols, pipes, shell operators,
  side-file writes, codec-policy overrides, and placeholder misuse. Filter names
  must exist in the selected FFmpeg binary and belong to a conservative
  in-memory-only AI policy; `mpdecimate` is included while file/model/socket
  filters remain available only to deliberate manual Console commands. The
  validated result then opens in the editable Console for explicit approval.
- **Reliable native process execution.** A shared argument parser handles quoted
  spaces, literal `#` characters, and empty arguments. `ProcessBuilder` launches
  the final argv, MediaCodec policy is revalidated immediately before execution,
  and foreground-service startup occurs within Android's required window.
- **Modern Android UI and storage behavior.** The project now targets current
  Android releases, handles edge-to-edge system/action-bar insets on the main and
  settings screens, and resumes pending Open/Open second input/Save operations
  exactly once after all-files access is granted.
- **Reproducible native builds and device regressions.** The pinned FFmpeg/NDK
  build includes local fixes for short-stream decoder drain, synchronous encoder
  global-header handling, and encoder input validation. Verification covers
  16KB ELF alignment, Snapdragon 8 Elite, Tensor G5, short streams, encoder
  matrices, system-software fallbacks, and pixel-quality thresholds.

## Android and FFmpeg runtime

The application supports Android 8.0/API 26 and later, targets API 35, and is
packaged for `arm64-v8a`. The standard Release package ships a reproducible,
standalone FFmpeg 9.0.2 GPL AIO CLI with Android MediaCodec support. The binary
statically links the pinned text/subtitle libraries and x264, x265, libvpx, and
libaom, including the NDK static C++ runtime, so third-party codec `.so` files
are unnecessary. Its AArch64 PIE load segments are aligned to 16KB for devices
using either 4KB or 16KB memory pages. The Release configure policy enables
GPLv2-or-later components and keeps FFmpeg's `version3` and `nonfree` modes
disabled.

The bundled software presets are:

- **H.264 libx264 bundled software:** 8-bit H.264 in MP4, CRF 23.
- **HEVC libx265 bundled software:** 8-bit HEVC in MP4, CRF 28 with `hvc1` tag.
- **VP9 libvpx bundled software:** VP9 in WebM, CRF 30 with row threading.
- **AV1 libaom bundled software:** AV1 in WebM, CRF 32 with a speed-oriented
  mobile preset.

These presets favor broad availability. Software HEVC, VP9, and especially AV1
can consume substantial CPU time and battery on a phone. Hardware and Android
system-software presets remain the preferred choices when their runtime
capabilities satisfy the requested job.

H.264, HEVC, VP9, and AV1 MediaCodec encoder commands are resolved at runtime.
Hardware presets query Android's codec inventory, select a component marked as
hardware, check the requested video shape when dimensions are available,
replace any model- or preset-supplied `-codec_name`, and lock FFmpeg to that
component. Every MediaCodec encoder command is normalized to planar
`-pix_fmt yuv420p` before execution. This avoids vendor-specific flexible/NV12
ByteBuffer stride and slice-height mismatches observed on Tensor G5. Component
selection requires advertised planar or flexible YUV420 support and fails
closed for a semiplanar-only encoder. Separate
system-software fallback presets select components marked
software-only, such as `c2.android.*`, and keep that policy through preview,
Console, batch processing, and final execution. The app validates the chosen
component again immediately before starting FFmpeg and removes its internal
policy marker before `ProcessBuilder` receives the command.
MediaCodec decoding uses `-hwaccel mediacodec` before `-i`; Android selects the
decoder component. The diagnostic inventory also reports H.264, HEVC, VP9,
and AV1 encoder/decoder availability. Selection accepts any vendor component
that satisfies Android's runtime flags and capabilities, including Exynos and
MediaTek component families; known reference software names remain assigned
to the software fallback policy.

The complete native build, reproducibility, verification, and device-test
instructions are in [`native/ffmpeg/README.md`](native/ffmpeg/README.md).
The three MediaCodec patches retained by the GPL AIO build completed
hardware-codec validation on both target SoC families: `c2.qti.*` H.264/HEVC
on Snapdragon 8 Elite and `c2.google.*` H.264/HEVC/AV1 on Tensor G5. Those
device logs are historical evidence from the pre-AIO MediaCodec artifact; the
native README distinguishes their tested digest from the final GPL AIO digest.

## Direct filesystem access

The manifest declares `MANAGE_EXTERNAL_STORAGE` to preserve the application's
absolute-path, all-files workflow. On Android 11/API 30 and later, the app
opens its system **All files access** settings page and the user grants access
explicitly. The manifest also gates `WRITE_EXTERNAL_STORAGE` through API 29,
`READ_EXTERNAL_STORAGE` through API 32, and declares the Android 13+
`READ_MEDIA_*` permissions. App-specific startup initialization remains usable
while permission is pending. After the user returns from Android's all-files
settings, a pending Open/Open second input/Save action resumes exactly once.
All-files access is sensitive and its distribution must follow the rules of
the target app store.

## Gemini command planning

The AI button offers two command-planning workflows:

- **BYOK one-shot generation** sends the redacted prompt to a configurable
  OpenAI-compatible `/chat/completions` endpoint. AI settings fetch the
  endpoint's `/models` response in the background and replace the model menu
  with the returned IDs; the saved model remains available as a custom value
  when a provider omits it or the request is offline. The API key is encrypted
  with an AES-GCM key held by Android
  Keystore, and the resulting ciphertext is stored under the app's no-backup
  directory. HTTPS is the default transport. Saving a local HTTP proxy requires
  an explicit warning acknowledgement tied to that exact endpoint because an
  unencrypted connection exposes the key and prompt to network observers.
- **Offline copy/paste** copies the same prompt for use in an external Gemini
  client, then accepts the returned `FFMPEGGUI_COMMAND_V1` block through the
  editable paste dialog or the direct **Read result from clipboard** action.
  Legacy strict JSON, a single command fence, and a plain FFmpeg command remain
  accepted for compatibility.

BYOK uses `{{INPUT_1}}` and `{{OUTPUT_1}}`. Every copied offline prompt receives
a random 128-bit session suffix, producing numbered placeholders such as
`{{INPUT_1_SID_...}}` and `{{OUTPUT_1_SID_...}}`. Their corresponding absolute
paths are stored only in the app's no-backup directory for up to 24 hours. The
binding survives UI file changes, is consumed after one successful result, and
rejects a replay or a result copied from another session. Input and output
absolute paths and basenames remain outside copied prompts and API messages.
Input probing contributes only bounded, control-character-cleaned technical
metadata such as container, extension, size, duration, stream codecs,
dimensions, and frame rate. Runtime FFmpeg capabilities and Android codec
diagnostics are included without the selected media identity.

The prompt contains the intersection of filter names reported by the active
FFmpeg binary and the app's conservative in-memory-only AI policy. BYOK,
pasted, and clipboard results are checked against that same set before preview.
The GPL AIO build exposes `mpdecimate` for near-duplicate frame removal and
keeps the cycle-based `decimate` filter as a separate operation; an unavailable
or invented spelling such as `mpdeci` is rejected. Filters with file, model,
font, command, or socket I/O remain available for manual Console commands and
are excluded from AI output. If the runtime inventory cannot be loaded,
generated commands that use filters fail closed. AI-generated commands are
normalized to exactly one global `-y` before the input, making overwrite the
default, while a conflicting `-n` result is rejected.

The system message starts with a stable planner and FFmpeg-help prefix. Local
runtime capabilities and per-file data follow that prefix in bounded blocks.
This ordering preserves identical leading tokens across requests and lets
Gemini-compatible providers apply their implicit prefix caching when available,
while codec/filter inventories and redacted media metadata remain current.

The preferred model response is a versioned three-line command envelope. Its
middle line carries literal FFmpeg double quotes, avoiding nested JSON string
escaping. BYOK and offline inputs share the same parser. Model prose outside one
valid envelope is ignored; duplicate/malformed envelopes and damaged legacy
JSON remain rejected rather than guessed or repaired. The extracted command is
validated before the two known placeholders are restored. Unknown or repeated
placeholders, additional inputs/outputs, network and pipe protocols, shell
operators, and side-file options are rejected. A validated result opens in the
Console for review; execution begins only after the user presses **Run**.

```text
FFMPEGGUI_COMMAND_V1_BEGIN
ffmpeg -y -i "{{INPUT_1}}" ... "{{OUTPUT_1}}"
FFMPEGGUI_COMMAND_V1_END
```

## Build the Android app

Requirements:

- JDK 17
- Android SDK platform 36 and the matching command-line/build tools
- Android NDK r29 (`29.0.14206865`), used by the pre-build bundled-ELF gate
- The included Gradle wrapper (Gradle 9.5.0 and Android Gradle Plugin 9.2.1)

From the repository root on macOS with the locally installed SDK path used by
this project:

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/29.0.14206865"

./gradlew :app:assembleDebug --no-daemon
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`.

Rebuilding the standard GPL AIO CLI additionally requires CMake, Ninja, GNU
Make, pkgconf build prerequisites, and ripgrep. The source lock pins every
dependency archive and SHA-256 digest. The build writes a staging artifact and leaves the app's
checked-in executable unchanged until it has passed the AIO verifier:

```sh
ANDROID_NDK_ROOT=/opt/homebrew/share/android-commandlinetools/ndk/29.0.14206865 \
  ./native/ffmpeg/build-android-arm64-aio.sh

./native/ffmpeg/verify-android-arm64-aio.sh
```

The staging executable is
`native/ffmpeg/.build/aio/staging/libffmpeg.so`. Promote that exact file to
`app/src/main/libs/arm64-v8a/libffmpeg.so` only after verification and record
its final digest in the native README and release evidence.

The source lock, five local patches, build scripts, and verifier record the
exact standard AIO recipe. Anyone redistributing the GPL executable must also
provide GPLv2-compliant corresponding source for that exact build.

## Test and verify

Run unit tests, rebuild the APK, and run Android lint together:

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/29.0.14206865"

./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug --no-daemon
./native/ffmpeg/verify-android-arm64-aio.sh
```

MediaCodec behavior is device-specific. The checked-in Snapdragon 8 Elite and
Tensor G5 logs record the selected hardware components, smoke tests,
short-stream drain coverage, and the historical encoder regression matrix. Set
`ANDROID_SERIAL` whenever several adb devices are attached:

```sh
ANDROID_SERIAL=<device-serial> ./native/ffmpeg/verify-android-arm64.sh
ANDROID_SERIAL=<device-serial> ./native/ffmpeg/smoke-test-mediacodec.sh
ANDROID_SERIAL=<device-serial> ./native/ffmpeg/test-short-mediacodec-drain.sh
ANDROID_SERIAL=<device-serial> ./native/ffmpeg/test-mediacodec-encoder-matrix.sh
REQUIRE_AV1=1 ANDROID_SERIAL=<device-serial> ./native/ffmpeg/test-mediacodec-quality.sh
```

The quality regression uses an unaligned 1228x720 fixture and verifies decoded
pixels with host-side SSIM/PSNR. On the tested Pixel 10 Pro XL, planar HEVC
measured SSIM 0.999304 / PSNR 52.728940 dB and planar AV1 measured SSIM
0.999240 / PSNR 52.272864 dB. On the Samsung SM-A576B (Exynos s5e8865), planar
HEVC measured SSIM 0.999329 / PSNR 55.501051 dB. The metrics compare raw
samples with identical colour tags on both inputs, because some encoders tag
their output BT.709 while the fixture is untagged. Without `REQUIRE_AV1=1`, the
script skips AV1 when Android only offers its reference software encoder.

The device records are
[`SM8750P-2026-08-12.log`](native/ffmpeg/verification/SM8750P-2026-08-12.log)
and
[`Tensor-G5-Pixel-10-Pro-XL-2026-08-12.log`](native/ffmpeg/verification/Tensor-G5-Pixel-10-Pro-XL-2026-08-12.log).
The Tensor planar quality regression is recorded in
[`Tensor-G5-planar-quality-2026-08-12.log`](native/ffmpeg/verification/Tensor-G5-planar-quality-2026-08-12.log).
The four-codec Android system-software check is recorded in
[`SM8750P-system-software-2026-08-12.log`](native/ffmpeg/verification/SM8750P-system-software-2026-08-12.log).
The FFmpeg 9.0.2 artifact's Exynos record is
[`Exynos-s5e8865-SM-A576B-2026-11-09.log`](native/ffmpeg/verification/Exynos-s5e8865-SM-A576B-2026-11-09.log).
The historical path-sanitized modern3 build and signing gate is recorded in
[`modern3-release-2026-08-12.log`](native/ffmpeg/verification/modern3-release-2026-08-12.log).
The current GPL AIO build, signature, embedded legal materials, and matching
source bundle are recorded in
[`modern3-gpl-aio-release-2026-08-12.log`](native/ffmpeg/verification/modern3-gpl-aio-release-2026-08-12.log).

## Optional local FDK AAC build

The standard Release uses FFmpeg's native AAC encoder and keeps FDK AAC out of
the release graph. The optional
[`build-android-arm64-fdk-local.sh`](native/ffmpeg/build-android-arm64-fdk-local.sh)
recipe is default-off and requires two explicit acknowledgements before it can
enable both `--enable-libfdk-aac` and `--enable-nonfree`. Its output remains in
an isolated local `DO-NOT-DISTRIBUTE` directory and stays outside APK staging,
release artifacts, and public CI caches.

FFmpeg classifies an FDK-enabled GPL combination as nonfree and
unredistributable. The FDK copyright license also grants no patent rights;
anyone running the local recipe is responsible for obtaining the patent
authorization appropriate to their use. The full upstream FDK notice is
included for review in
[`third_party/licenses/FDK-AAC-NOTICE.txt`](third_party/licenses/FDK-AAC-NOTICE.txt).

## Licensing

The standard packaged FFmpeg executable is built from FFmpeg `n9.0.2` with
`--enable-gpl --disable-version3 --disable-nonfree`, so the resulting native
binary is distributed under GNU GPL version 2 or later. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), the full GPLv2 text in
[`third_party/licenses/GPL-2.0.txt`](third_party/licenses/GPL-2.0.txt), and the
dependency-specific license and patent texts under
[`third_party/licenses/`](third_party/licenses/).

The Android build copies the notice index to
`assets/legal/THIRD_PARTY_NOTICES.md` inside every APK and copies the complete
license directory beneath that index at `assets/legal/third_party/licenses/`.
The packaged FDK AAC notice is informational; the standard executable excludes
FDK AAC and `nonfree` code.

These files cover the bundled native executable and its third-party
components. The application source retains the upstream repository's
unspecified licensing status; this fork adds no separate application-code
license grant. The older
[`LICENSE-FFMPEG-LGPL-2.1.txt`](LICENSE-FFMPEG-LGPL-2.1.txt) remains as the
license record for the historical minimal LGPL native recipe and artifacts.
