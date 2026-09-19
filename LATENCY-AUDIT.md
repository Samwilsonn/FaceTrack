# Targeted latency audit

## Release-candidate follow-up (2.2.1, build 5)

Current baseline is `502e3a0` on `codex/mijick-obs-streaming`. Audio is already
removed. The user reports that removal did not resolve the approximately one-second
delay. No synchronized iPhone/OBS trace is available, so the steady-delay root cause
is still unproven. Windows denied access to saved OBS settings/logs even after a
read-access request; no current OBS configuration was inferred from those files.

Correction to the earlier conversational diagnosis: OBS's 30-frame async queue is
a **capacity**, not evidence of a fixed one-second buffer. A queue-size constant
cannot establish occupancy or display delay on this PC. OBS's Media Source still
does stream probing, decoding and timestamp-based playback when Network Buffering
is zero. Its async queue alone is not a confirmed cause.

Concrete changes in this pass:

- Request VideoToolbox MaxFrameDelayCount 0, falling back to the previous 1 if
  unsupported. Apple defines this as the compression window, so the potential
  saving is frame-scale; it is not evidence of a one-second fix.
- Cache real encoder SPS/PPS from a few initial camera frames and include them,
  the actual H.264 profile/level and configured frame rate in RTSP SDP. This avoids
  leaving all format discovery to incoming packets. An immediate DESCRIBE before
  headers exist retains the compatible in-band-header fallback. No black/dummy
  frames or continuous idle encoding were added.
- Reject nonnumeric capture timestamps; recover unusable encoder output at a
  keyframe. Check encoder preparation and propagate startup failure instead of
  advertising a ready stream. Clear stale delivery/header state on restart.
- Disable temporal capture stabilization explicitly. Its prior active mode was
  not measured; this prevents a potential capture-side buffering stage.
- Use monotonic time for RTSP write/idle watchdogs, keeping existing deadlines.
- Preserve both dimensions and quality when applying a preset during streaming.
- Match supported camera capture FPS to quality/thermal processing limits, avoiding
  excess captures at 24 FPS or while heat limits processing to 15/5 FPS. Reapply the
  limit after changing lenses or the capture preset. Physical heat/FPS results are
  not measured in this environment.
- Fix remote preview reconnect/invitation state and stale control-peer/revision
  handling. Keep existing decoder and bounded flight-window semantics.
- Add a Windows RTSP arrival probe and protocol/packetization regression coverage.

Primary references: [Apple MaxFrameDelayCount](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxframedelaycount),
[Apple low-latency rate control](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol),
[OBS 32.2.2 playback](https://github.com/obsproject/obs-studio/blob/32.2.2/shared/media-playback/media-playback/media.c),
[OBS 32.2.2 async source](https://github.com/obsproject/obs-studio/blob/32.2.2/libobs/obs-source.c),
[FFmpeg 8 SDP framerate parsing](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavformat/rtsp.c).

The remaining discriminating checks are the new probe's arrival-drift report,
same-run capture-to-RTP Instruments timings, and a filmed timer/OBS comparison.
Low arrival drift does not exclude constant delay. No changes to RTP clock origin,
TCP transport, selected resolution/bitrate, or OBS installation were made.
See RELEASE-NOTES.md for validation status and the complete file list.

## Historical audit below (earlier passes)

The remaining sections describe earlier work and its verification status at that
time. They are not a statement that audio is still active or that those earlier
measurements have since been performed.

Update: the user subsequently requested a video-only app. The microphone, silent
AAC track and audio transport have now been removed from active sources; preserved
implementations are in `ArchivedAudio/`, outside the build. Audio observations
below describe the earlier baseline, not the current app. No measured latency
improvement is claimed; reconnect OBS and compare against that baseline.

Baseline: `ee0995d`, working OBS and Remote Preview. The reported approximately
one-second glass-to-glass delay is a device observation, not a measured breakdown.
No physical iPhone/OBS trace was available during this source audit.

User's live A/B report during this pass: the approximately one-second delay is
present with Preview OFF as well as ON. OBS hardware decoding is enabled;
disabling it and reconnecting makes the delay worse. Keep it enabled on this PC.
This separates the baseline delay from the simultaneous-preview failure, but
does not by itself locate that baseline delay in the app, network or receiver.

## What the source establishes

| Stage | Existing behavior | What still needs measurement |
| --- | --- | --- |
| Capture / effects | Serial capture queue, `alwaysDiscardsLateVideoFrames`, final processed image offered without a per-frame main-thread hop | Capture delivery age, effects and final GPU render time |
| H.264 | At most two admitted images; rejects admission age over 150 ms; real-time, no frame reordering; low-latency rate control attempted with fallback | Device support for optional properties, GPU/encoder duration |
| App video delivery | One outstanding delivery closure; rejects frames over 200 ms old before RTP | Queue residence and packetization duration |
| RTSP / TCP | One outstanding video write per client, independent bounded audio delivery, TCP no-delay | Kernel/network residence after local send completion; TCP retransmission |
| Audio | Separate bounded capture/conversion queue, AAC 48 kHz mono, shared host-clock RTP/RTCP mapping; cached silence when muted | Capture/conversion delay, actual clap synchronization |
| OBS | Demux, decoder and presentation are outside the app's latency markers | Receive-to-display delay and hardware/software decoder comparison |

These queue limits are **not** end-to-end latency guarantees. Network.framework's
send completion is local processing, not peer receipt or screen presentation.
The two-second blocked-write watchdog is a failure deadline, not a two-second
playback buffer. Neither that watchdog nor the one-second IDR interval establishes
the source of a steady one-second delay. They are intentionally not shortened.

## OBS-side evidence, not a diagnosis of this installation

Upstream OBS [media.c](https://github.com/obsproject/obs-studio/blob/master/shared/media-playback/media-playback/media.c)
sets `AVFMT_FLAG_NOBUFFER` when Network Buffering is zero, still calls
`avformat_find_stream_info`, and prepares both negotiated audio/video tracks.
Consequently, empty FFmpeg Options with zero buffering does not prove the cause.
Startup stream discovery must be distinguished from persistent playback delay.

Upstream OBS [decode.c](https://github.com/obsproject/obs-studio/blob/master/shared/media-playback/media-playback/decode.c)
opens its decoder separately from the demuxer options. Do not claim that entering
`flags=low_delay` or `threads=1` in Media Source FFmpeg Options configures that
decoder. Hardware decoding on/off is a controlled comparison, not a guaranteed fix.
Installed OBS behavior may differ from upstream master.

## Measurement required before further primary-pipeline changes

1. Keep the primary quality, FPS and effects unchanged. Record OBS version and
   decoder setting. Use Network Buffering 0 MB and explicit RTSP-over-TCP.
2. With Preview OFF, film a timer and the OBS display together; record at least
   ten samples after startup and again after several minutes. Repeat mic OFF/ON.
3. Repeat with Preview ON over the same Wi-Fi, then with the existing USB path.
   Compare OBS and Remote separately; a preview freeze is not an OBS latency value.
4. Run with `--latency-trace` in Xcode/Instruments and collect the stage events.
   Capture-to-RTP measures only the app portion. It must not be subtracted from a
   different run's glass-to-glass value as though the clocks/runs were identical.
5. Compare OBS hardware decoding on/off with otherwise identical settings and
   a fresh connection each time. Check any user-configured video-delay filter and
   audio synchronization offset without silently changing either.

If the app portion is consistently small but glass-to-glass remains near a second,
the next investigation is network/receiver presentation—not another speculative
rewrite of working RTSP startup, timestamps, encoder ownership or microphone code.
No numerical latency reduction or definitive OBS-side attribution is claimed yet.

## Preview-specific defects corrected

The original preview path sent the same primary H.264 stream over a separate
encrypted session. Its four-frame window disconnected after a 250 ms ACK delay,
cleared the displayed image on reconnect, and requested shared-encoder keyframes
up to four times per second during recovery. Large scene changes could therefore
amplify contention and recovery traffic. A fixed earliest-arrival reference also
rejected every frame after a persistent delay step above 120 ms. These are source
findings consistent with the reported symptoms, not measured Wi-Fi capacity.

The shared encoder is retained. Recovery now drains old outstanding frames/ACKs
before a fresh IDR, with frame and byte bounds; ordinary jitter no longer causes
immediate reconnects. A deliberate sequence gap marks that fresh recovery IDR
without changing the packet format. The receiver can re-anchor a modest arrival
shift only on that marker (under 350 ms additional drift), never an ordinary
queued IDR. Greater drift is still rejected; this relative clock is not an
absolute cross-device capture-age measurement. Actual network stalls can still
freeze preview, and shared Wi-Fi bandwidth remains a physical limitation.

Preview recovery uses normal periodic IDRs, no repeated requests into the primary
encoder. Reconnect keeps the displayed image; renderer backpressure no longer
causes unnecessary flushes. No second encoder or primary quality reduction was
introduced. Simultaneous Wi-Fi testing is required to establish the improvement.

## Changed files and verification

- Settings: `FaceTrackCam/CameraScreen.swift`, `FaceTrackCam/RemoteScreen.swift`.
- Preview: `FaceTrackCam/RemotePreviewChannel.swift`,
  `FaceTrackCam/RemotePreviewView.swift`, `Core/LiveDeliveryPolicy.swift`.
- Regression tests: `Tests/LiveDeliveryPolicyTests.swift` (drain-before-IDR,
  byte bounds, soft/hard deadline separation, late recovery, timestamp wrapping).
- Opt-in diagnostics only: `FaceTrackCam/CameraModel.swift`,
  `FaceTrackCam/H264Encoder.swift`, `FaceTrackCam/H264RTSPServer.swift`,
  `FaceTrackCam/MicrophoneAAC.swift`, `FaceTrackCam/StreamDiagnostics.swift`.
- Documentation: this file and `LATENCY-TESTS.md`.

Static diff/whitespace checks passed. Swift/Xcode are unavailable locally, so
XCTest and compilation have not run for this patch. No IPA was generated and no
physical success-matrix test is claimed. Git staging failed with permission denied
creating `.git/index.lock`; commit/push must be completed from the user's normal
checkout to launch the existing macOS test/build/IPA workflow.
