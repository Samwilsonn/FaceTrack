# FacePull / FaceTrackCAM

FacePull is an iOS 17+ camera app for OBS. It captures with AVFoundation, applies
Vision face framing and optional person-background effects, and displays the
processed result locally. It has an H.264 RTSP stream for OBS. A second iPhone can run FacePull in Remote Control
mode with an optional live video preview (off by default).

## Validation

GitHub Actions builds the iPhone and simulator apps and runs the framing/protocol
tests. That confirms compilation, not real camera, RTSP/OBS, USB, or paired-device
behavior. Follow [DEVICE-TESTS.md](DEVICE-TESTS.md) on an iPhone 13 Pro before using
FacePull for a production stream. The IPA artifact is unsigned and must be signed
with the user's normal iPhone installation process.

## OBS over Wi-Fi

1. Keep the iPhone and Windows PC on the same reachable local network. Start the
   stream in FacePull and keep the app in the foreground.
2. In Settings → Connect, copy **Wi-Fi · H.264**. Its shape is
   `rtsp://PHONE_IP:8554/facepull?token=SAVED_KEY`.
3. Add an OBS **Media Source**, turn off **Local File**, and paste the complete URL
   into **Input**. Set **Network Buffering** to **0 MB** to avoid OBS's default
   2 MB live-video buffer. Set input format to `rtsp` and FFmpeg options to
   `rtsp_transport=tcp fflags=nobuffer flags=low_delay` if OBS exposes those fields.
   Save the source.

The iPhone's raw IP alone is not an OBS media URL. Reserve the iPhone's Wi-Fi
address in the router for a stable saved source. The access key persists across
stream restarts but changes if FacePull's app data is removed. Microphone audio
can be toggled while streaming; the negotiated audio track carries silence while muted.
For timing measurements and Wi-Fi recovery checks, see [LATENCY-TESTS.md](LATENCY-TESTS.md).

## OBS over USB on Windows

See [USB/SETUP.md](USB/SETUP.md). The bridge forwards the H.264 RTSP service to
`rtsp://127.0.0.1:18554/facepull?token=SAVED_KEY`. The source can be saved once.
The separate HTTP port remains available for browser remote control.
The bridge requires Apple's installed Mobile Device service and trusted USB pairing.
Physical USB and OBS reconnect behavior still require acceptance testing.

## Second iPhone remote

Open Settings on the Host to see its six-digit pairing code. On the second phone,
choose **Use as Remote Control**, choose the discovered Host, and enter the code.
Subsequent local-network connections use the saved per-device credential. Control
messages use an encrypted Multipeer Connectivity session; camera images are not
sent to the Remote. Both devices need local-network permission. Remote selection of
an already saved Host background is supported; transferring a new photo from the
Remote is not yet part of this build.

## Camera behavior

FaceTrack offers subject lock or automatic widening for other detected faces.
Custom Background opens recents and Photos without immediately changing the active
background. Saved presets keep the camera setup. The OLED saver dims the screen
after 30 seconds of streaming and wakes on a tap. Backgrounding or locking the
phone stops camera capture; return to the foreground before restarting the stream.

Mijick visual assets are used under the license in [NOTICE.md](NOTICE.md). The
capture and streaming engine is dedicated to FacePull rather than Mijick's camera
manager. See [project.yml](project.yml) for the build configuration.

