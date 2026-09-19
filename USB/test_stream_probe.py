"""Exercise the Windows latency probe against a synthetic RTSP/RTP source."""
import json
import pathlib
import socket
import struct
import subprocess
import threading
import time
import unittest


class StreamProbeTests(unittest.TestCase):
    def run_probe(self, audio=False, drift=False):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(10)
        port = listener.getsockname()[1]
        token = 'PRIVATE_TEST_TOKEN'
        url = f'rtsp://127.0.0.1:{port}/facepull?token={token}'
        failures = []

        def serve():
            try:
                with listener.accept()[0] as peer:
                    peer.settimeout(5)
                    source = peer.makefile('rb')
                    while True:
                        line = source.readline()
                        if not line:
                            return
                        method = line.split()[0]
                        cseq = None
                        while True:
                            header = source.readline()
                            if header in (b'\r\n', b''):
                                break
                            if header.lower().startswith(b'cseq:'):
                                cseq = int(header.split(b':')[1])
                        body = b''
                        extra = b''
                        if method == b'DESCRIBE':
                            body = (f'v=0\r\nm=video 0 RTP/AVP 96\r\n'
                                    f'a=control:rtsp://127.0.0.1:{port}/facepull/trackID=0?token={token}\r\n'
                                    f'a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z2QAKKw=,aO48gA==\r\n').encode()
                            if audio:
                                body += b'm=audio 0 RTP/AVP 97\r\n'
                        if method == b'SETUP':
                            extra = b'Session: test;timeout=60\r\n'
                        response = (f'RTSP/1.0 200 OK\r\nCSeq: {cseq}\r\nContent-Length: {len(body)}\r\n'.encode()
                                    + extra + b'\r\n' + body)
                        peer.sendall(response[:5])
                        peer.sendall(response[5:])
                        if method == b'PLAY':
                            # Interleaved RTCP precedes video; sequence and clock wrap.
                            peer.sendall(b'$\x01\x00\x08\x80\xc9\x00\x01\x00\x00\x00\x01')
                            start = time.monotonic()
                            for index in range(50):
                                deadline = start + index * (0.06 if drift else 1 / 30)
                                time.sleep(max(0, deadline - time.monotonic()))
                                stamp = (0xfffff000 + index * 3000) & 0xffffffff
                                packet = struct.pack('!BBHII', 0x80, 0xe0, (65530 + index) & 0xffff, stamp, 1)
                                packet += b'\x65\x01' if index % 30 == 0 else b'\x41\x01'
                                peer.sendall(b'$\x00' + struct.pack('!H', len(packet)) + packet)
                            return
            except (ConnectionError, BrokenPipeError):
                pass  # The probe intentionally closes when its sample is complete.
            except Exception as error:
                failures.append(repr(error))
            finally:
                listener.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        result = subprocess.run([
            'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(pathlib.Path(__file__).with_name('Measure-Stream.ps1')),
            '-Url', url, '-DurationSeconds', '1'
        ], capture_output=True, text=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
        thread.join(timeout=6)
        self.assertFalse(failures, failures)
        self.assertNotIn(token, result.stdout + result.stderr)
        return result

    def test_wrap_fragmented_responses_and_video_report(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report['headersInSDP'])
        self.assertGreater(report['frames'], 20)
        self.assertEqual(report['rtpSequenceDiscontinuities'], 0)
        self.assertGreater(report['keyframes'], 0)
        self.assertIn('does not measure constant network delay', report['limitation'])

    def test_detects_increasing_arrival_delay(self):
        result = self.run_probe(drift=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertGreater(report['additionalArrivalDelayMs'], 200)

    def test_rejects_old_audio_video_stream_without_leaking_key(self):
        result = self.run_probe(audio=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
