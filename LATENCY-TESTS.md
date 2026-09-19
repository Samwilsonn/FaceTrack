# Final-pass device verification (not yet performed)

Keep quality, FPS, effects and network identical for before/after measurements.
Film a millisecond timer beside OBS and Remote; measure at least ten samples.
No latency improvement is claimed until these measurements are recorded.

OBS: Network Buffering 0 MB, Input Format `rtsp`, FFmpeg Options
`rtsp_transport=tcp fflags=nobuffer`, Reconnect Delay 1 second.
Zero buffering already enables OBS's no-buffer flag; empty FFmpeg options alone
do not establish the cause of delay. The user's hardware-decoding OFF comparison
made latency worse; keep it ON on that PC. OBS opens its decoder separately from
these demuxer options, so `flags=low_delay` here is not a verified decoder fix.
See LATENCY-AUDIT.md for the evidence and remaining measurement limits.

- Reconnect OBS after upgrading; confirm video-only negotiation and compare delay
  against the previous build at the same quality. No mic or silent AAC track exists.
- Interrupt Wi-Fi briefly, restore it, and confirm recovery to current time rather
  than an increasing delay. Repeat ten times. Record any reconnect loops.
- Confirm wired USB streaming and reconnect still work with the existing URL.
- Compare OBS latency/FPS with Remote Preview off/on; repeat preview toggles twenty times.
- Background/foreground Remote, leave its screen, disconnect/reconnect, stop/start Host.
- Compare Host/Remote framing, orientation, mirroring, sliders, backgrounds and menus.
- On both phones, open Settings and expand Connect. Scroll to the final row and
  release your finger: it must remain reachable and tappable without holding a
  rubber-band drag. Repeat on a small screen and in supported orientations.
  Remote Connect must follow the existing settings and presets at the bottom.
- With OBS over Wi-Fi and Remote Preview ON, alternate detailed/static scenes
  and adjust exposure. Record preview freezes, black flashes, and OBS latency
  separately. Recovery must not cause repeated OBS keyframe bursts or reconnects.
- Stream thirty minutes; record heat, dropped frames and memory growth.

Optional Xcode launch argument `--latency-trace` emits Instruments Points of Interest
for Camera callback age, Frame processing, Capture to encoder admission,
Final CI render, Encoder output, Video packetization, Capture to RTP,
TCP write processed, Preview round trip, Preview arrival drift
and Preview decode submission, plus VideoToolbox creation/property status codes.
Normally disabled. TCP completion is NOT an ACK
or a display timestamp. These markers cannot measure OBS rendering directly.

Policy deadlines (not measured latency): encoder admission 150 ms, RTP frame age
200 ms, genuinely blocked TCP send 2 seconds. Preview acknowledgment age 250 ms
now starts bounded drain/recovery, not a disconnect. Only a 2-second outstanding
preview acknowledgment resets its transport. At most four preview frames and
512 KiB are in flight, with one larger valid IDR allowed to travel alone.
Free socket capacity no longer terminates a session; it cannot establish backlog age.
TCP sessions are aborted on blocked sends; OBS reconnect timing remains
receiver-controlled. Preview keeps the last displayed image during recovery and
uses normal periodic keyframes instead of repeatedly forcing OBS keyframes.
Recovery may briefly freeze that image; it is not proof of uninterrupted playback.
Install the same build on Host and Remote to exercise the updated recovery policy.

Regression acceptance: video-only with no Remote; paired Remote/preview
OFF; preview ON; preview OFF again; Remote disconnect; OBS disconnect/reconnect.
Each must give continuous OBS video after connection, current SPS/PPS/IDR on
reconnect, no advertised audio track, no repeated reconnect haptics and no replayed
backlog. Compare Host and Remote Connect Wi-Fi/USB/password rows and copied values.
