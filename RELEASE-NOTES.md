# FacePull 2.2.1 (build 5) — release candidate

Prepared from `502e3a0` on `codex/mijick-obs-streaming`. This is a code and test
candidate, not a verified final IPA. The reported one-second OBS delay has not yet
been measured after these changes, and its full root cause remains unconfirmed.

## Changes

1. **Encoder:** zero-frame compression delay requested, with the previous one-frame
   setting as an unsupported-device fallback. Preparation failures now stop stream
   startup. Nonnumeric timestamps are rejected and unusable encoded output requests
   a recovery keyframe. Existing hardware/low-latency selection and no-B-frame policy
   remain in place. (`FaceTrackCam/H264Encoder.swift`)
2. **RTSP startup:** prime and cache this encoder session's real SPS/PPS, advertise
   profile/level and configured FPS in SDP, and preserve query items when constructing
   the video track URL. Early connections still work with in-band headers.
   (`Core/VideoStreamDescription.swift`, `FaceTrackCam/H264RTSPServer.swift`)
3. **Stream lifecycle:** readiness waits for both listener and encoder; failed
   listener construction cleans up the encoder. Restart invalidates pending frame
   delivery/header state. Write/idle watchdogs now use monotonic time.
   (`FaceTrackCam/H264RTSPServer.swift`)
4. **Capture/presets:** explicitly disable temporal video stabilization; preserve
   stream format as well as quality when loading presets live, preventing dimensions
   from changing underneath a running encoder. Match supported capture FPS to the
   selected quality/thermal limit instead of always capturing 30 FPS and discarding
   the excess. (`FaceTrackCam/CameraModel.swift`)
5. **Remote preview:** clear stale peers and pending invitations, retry timed-out
   invitations while the target remains discovered, and immediately stop admission
   after a send failure. (`FaceTrackCam/RemotePreviewChannel.swift`)
6. **Remote control:** reject messages from disconnected/previous hosts and stale
   state revisions. Failed state sends remain eligible for retry.
   (`FaceTrackCam/PeerControl.swift`)
7. **Browser control:** parse headers separately from the body so a UTF-8 character
   split across TCP receives does not reject a valid command.
   (`Core/StreamProtocol.swift`, `Tests/StreamProtocolTests.swift`)
8. **RTP verification:** moved the unchanged packetizer into the testable Core
   target. Added tests for NAL fragmentation/reassembly, marker placement, payload
   size limits and sequence wraparound. Added SDP metadata/fallback/URL tests.
   (`Core/RTPH264.swift`, `Tests/RTPH264Tests.swift`,
   `Tests/VideoStreamDescriptionTests.swift`)
9. **Windows diagnostics:** added a dependency-free PowerShell RTSP arrival probe
   reporting FPS, startup, keyframes and growing arrival delay. It prints neither
   the access key nor camera images. Added synthetic-source tests for timing drift,
   timestamp/sequence wrap, fragmented responses and old audio-track rejection.
   (`USB/Measure-Stream.ps1`, `USB/test_stream_probe.py`)
10. **USB startup:** validate startup/listener state and give accurate service/readiness
    feedback while retaining hidden bridge processes. (`USB/Start-USB.ps1`,
    `USB/Setup-USB.ps1`)
11. **CI:** run the existing simulator UI smoke test and archive its results; add a
    Windows job for the existing USB bridge tests and new stream-probe tests.
    (`.github/workflows/build.yml`)
12. **Release/docs:** bump to 2.2.1/build 5; correct OBS option and remote-preview
    instructions; document the measurement process and remaining uncertainty. Ignore
    generated Python caches and Xcode result bundles. (`project.yml`, `.gitignore`,
    `README.md`, `USB/SETUP.md`, `DEVICE-TESTS.md`, `LATENCY-AUDIT.md`,
    `LATENCY-TESTS.md`, this file)

## Validation

- Passed locally: USB handshake, HTTP/RTSP forwarding, unplug simulation and
  reconnect tests (`USB/test_bridge.py`).
- Passed locally: three synthetic RTSP probe tests (`USB/test_stream_probe.py`).
- Passed locally: syntax parsing of every USB PowerShell script and validation of
  28 asset JSON files. Final code review checked startup/restart ownership, packet
  boundaries and capture-queue confinement. Workflow changes were reviewed statically.
- Swift/Xcode compilation, XCTest and simulator UI execution remain pending on
  macOS CI. Those tools are unavailable on this Windows machine.
- Physical Wi-Fi/USB, simultaneous Remote Preview, heat/battery, and measured OBS
  display delay remain pending. Follow `DEVICE-TESTS.md` and `LATENCY-TESTS.md`.
- No app installation, OBS setting change, commit, push or release publication was
  performed in this pass. The existing workflow produces an unsigned IPA.

## Release gates

1. Run the updated build workflow on this patch; require the macOS and Windows jobs
   to pass, including the new Swift tests and simulator UI smoke test.
2. Install that exact IPA on both phones. Confirm dimensions, start/stop, lens and
   preset changes, OBS reconnect, preview toggles and reconnect after Wi-Fi loss.
3. Compare at least ten filmed timer/OBS samples before/after under identical
   conditions. Run the arrival probe alone and alongside OBS, then compare USB.
4. Complete the 30-minute heat/memory/FPS test. Only then call this a final release.

No claim is made that OBS necessarily queues 30 frames or that the new settings
eliminate the entire delay. Network.framework completion measures a local write,
not OBS reception/display. The probe also cannot measure a constant latency offset.
Existing RTSP and browser HTTP control remain local-network plaintext services;
the two-iPhone control and preview sessions remain encrypted.
