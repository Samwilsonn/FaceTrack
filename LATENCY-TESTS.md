# Final-pass device verification (not yet performed)

Keep quality, FPS, effects and network identical for before/after measurements.
Film a millisecond timer beside OBS and Remote; measure at least ten samples.
No latency improvement is claimed until these measurements are recorded.

OBS: Network Buffering 0 MB, Input Format `rtsp`, FFmpeg Options
`rtsp_transport=tcp fflags=nobuffer flags=low_delay`, Reconnect Delay 1 second.
Zero buffering already enables OBS's no-buffer flag; empty FFmpeg options alone
do not establish the cause of delay. Compare hardware decoding on/off separately.

- Compare video with mic off/on and clap synchronization; toggle off/on/off/on.
- Interrupt Wi-Fi briefly, restore it, and confirm recovery to current time rather
  than an increasing delay. Repeat ten times. Record any reconnect loops.
- Confirm wired USB streaming and reconnect still work with the existing URL.
- Compare OBS latency/FPS with Remote Preview off/on; repeat preview toggles twenty times.
- Background/foreground Remote, leave its screen, disconnect/reconnect, stop/start Host.
- Compare Host/Remote framing, orientation, mirroring, sliders, backgrounds and menus.
- Stream thirty minutes; record heat, dropped frames and memory growth.

Optional Xcode launch argument `--latency-trace` emits Instruments Points of Interest
for Frame processing, Capture to encoder admission, Encoder output, Capture to RTP,
TCP write processed, Preview round trip, Preview arrival drift
and Preview decode submission. Normally disabled. TCP completion is NOT an ACK
or a display timestamp. These markers cannot measure OBS rendering directly.

Policy deadlines (not measured latency): encoder admission 150 ms, RTP frame age
200 ms, genuinely blocked TCP send 2 seconds, preview acknowledgment 250 ms.
Free socket capacity no longer terminates a session; it cannot establish backlog age.
TCP sessions are aborted on blocked sends; OBS reconnect timing remains
receiver-controlled. A brief frozen/blank frame during recovery is preferable to
playing accumulated history but must be tested on the real network.

Regression acceptance: no Remote/mic OFF; no Remote/mic ON; paired Remote/preview
OFF; preview ON; preview OFF again; Remote disconnect; OBS disconnect/reconnect.
Each must give continuous OBS video after connection, current SPS/PPS/IDR on
reconnect, working audio when enabled, no repeated reconnect haptics and no replayed
backlog. Compare Host and Remote Connect Wi-Fi/USB/password rows and copied values.
