# Archived audio implementation

FacePull is now video-only. This folder preserves the previous AAC microphone,
silent-audio generator, and AAC RTP packetizer for reference; none is built into
the app or the Swift package. The former integration remains in Git history.

There is no audio SDP track, audio RTP/RTCP output, microphone permission request,
or Host/Remote mic toggle in the active app. Existing OBS sources must reconnect
after installing this version to renegotiate the video-only stream.
