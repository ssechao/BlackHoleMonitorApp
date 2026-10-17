#!/usr/bin/env python3
"""
Demucs real-time vocal separation server for BlackHoleMonitorApp.

Protocol v2 (see BlackHoleMonitorApp/DSP/DemucsProtocol.swift). Every message
starts with a 12-byte little-endian header: magic "BHMD", type, value.

    HELLO      app -> server  value = sample rate          no payload
    HELLO_ACK  server -> app  value = protocol version     no payload
    AUDIO      app -> server  value = frames   payload = frames x [L, R] float32
    RESULT     server -> app  value = frames   payload = frames x [wetL, wetR, dryL, dryR]

Streaming: each step separates [CONTEXT_S of previous input | HOP_S of new input]
and emits HOP_S of output, cross-fading XFADE_S at chunk boundaries.
Latency is about HOP_S + XFADE_S + processing time.

Usage: demucs_server.py [--port 19845] [--parent-pid PID]
"""

import argparse
import os
import socket
import struct
import sys
import threading
import time

import numpy as np

# Interpreters launched from a GUI app may not see the user site-packages of
# the version demucs was installed for; add it generically (no hardcoded version).
_user_site = os.path.expanduser(
    f"~/Library/Python/{sys.version_info.major}.{sys.version_info.minor}"
    f"/lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages")
if os.path.isdir(_user_site) and _user_site not in sys.path:
    sys.path.append(_user_site)

# python.org builds ship without root certificates: use certifi's bundle for the
# model download instead of disabling TLS verification.
try:
    import certifi
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
except ImportError:
    pass

import torch  # noqa: E402
import torchaudio.functional as AF  # noqa: E402
from demucs import pretrained  # noqa: E402
from demucs.apply import apply_model  # noqa: E402

MAGIC = 0x444D4842  # "BHMD"
PROTOCOL_VERSION = 2
HEADER = struct.Struct("<III")
MSG_HELLO, MSG_HELLO_ACK, MSG_AUDIO, MSG_RESULT = 1, 2, 3, 4
MAX_FRAMES_PER_MESSAGE = 2_000_000

CHANNELS = 2
CONTEXT_S = 1.0     # left context given to the model (not emitted)
HOP_S = 1.5         # new audio emitted per step
XFADE_S = 0.2       # cross-fade between consecutive steps (<= CONTEXT_S)
MAX_BACKLOG_S = 10.0  # drop oldest input if processing falls behind


def log(message):
    print(f"[Demucs] {message}", flush=True)


def recv_exact(conn, size):
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = conn.recv(min(remaining, 1 << 16))
        if not chunk:
            raise ConnectionError("client closed the connection")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def send_message(conn, msg_type, value, payload=b""):
    conn.sendall(HEADER.pack(MAGIC, msg_type, value) + payload)


class Separator:
    """Loads the model once; separate() returns the instrumental part."""

    def __init__(self):
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.model = None

    def load(self):
        for name in ("htdemucs", "htdemucs_ft"):
            try:
                log(f"Loading model {name} on {self.device}...")
                model = pretrained.get_model(name)
                model.to(self.device)
                model.eval()
                self.model = model
                log(f"Model {name} loaded")
                return True
            except Exception as error:  # noqa: BLE001 - try the next model
                log(f"Failed to load {name}: {error}")
        return False

    def separate(self, audio, sample_rate):
        """audio: (frames, 2) float32 at sample_rate -> instrumental (frames, 2)."""
        frames = audio.shape[0]
        waveform = torch.from_numpy(np.ascontiguousarray(audio.T)).float().unsqueeze(0)
        model_rate = self.model.samplerate
        if sample_rate != model_rate:
            waveform = AF.resample(waveform, sample_rate, model_rate)
        with torch.no_grad():
            sources = apply_model(self.model, waveform.to(self.device), device=self.device)
        vocals = self.model.sources.index("vocals")
        instrumental = sources[0].sum(dim=0) - sources[0, vocals]
        instrumental = instrumental.unsqueeze(0).cpu()
        if sample_rate != model_rate:
            instrumental = AF.resample(instrumental, model_rate, sample_rate)
        result = instrumental[0].numpy().T
        # Resampling may be off by a frame: pad/trim to the input length
        if result.shape[0] < frames:
            result = np.vstack([result, np.zeros((frames - result.shape[0], CHANNELS), np.float32)])
        return np.ascontiguousarray(result[:frames], dtype=np.float32)


class Stream:
    """Per-connection streaming state (reset by every HELLO)."""

    def __init__(self, sample_rate):
        self.sample_rate = sample_rate
        self.context = int(CONTEXT_S * sample_rate)
        self.hop = int(HOP_S * sample_rate)
        self.xfade = min(int(XFADE_S * sample_rate), self.context)
        self.max_backlog = int(MAX_BACKLOG_S * sample_rate)
        self.pending = []           # list of (n, 2) arrays not yet processed
        self.pending_frames = 0
        self.history = np.zeros((self.context, CHANNELS), np.float32)
        self.held_wet = np.zeros((self.xfade, CHANNELS), np.float32)
        ramp = np.linspace(0.0, 1.0, self.xfade, dtype=np.float32)[:, None]
        self.fade_in, self.fade_out = ramp, 1.0 - ramp

    def push(self, samples):
        self.pending.append(samples)
        self.pending_frames += samples.shape[0]
        if self.pending_frames > self.max_backlog:
            merged = np.concatenate(self.pending)[-self.max_backlog:]
            log(f"Processing too slow, dropped {self.pending_frames - merged.shape[0]} frames")
            self.pending, self.pending_frames = [merged], merged.shape[0]

    def take_hop(self):
        if self.pending_frames < self.hop:
            return None
        merged = np.concatenate(self.pending)
        hop, rest = merged[:self.hop], merged[self.hop:]
        self.pending, self.pending_frames = ([rest] if rest.size else []), rest.shape[0]
        return hop

    def step(self, separator, hop):
        """Separates one hop and returns RESULT frames (hop, 4)."""
        window = np.vstack([self.history, hop])
        wet = separator.separate(window, self.sample_rate)
        self.history = window[-self.context:]

        c, x, h = self.context, self.xfade, self.hop
        # Output covers input positions [start - x, start + hop - x)
        out_wet = np.empty((h, CHANNELS), np.float32)
        out_wet[:x] = self.held_wet * self.fade_out + wet[c - x:c] * self.fade_in
        out_wet[x:] = wet[c:c + h - x]
        self.held_wet = wet[c + h - x:c + h].copy()
        out_dry = window[c - x:c + h - x]
        return np.ascontiguousarray(np.hstack([out_wet, out_dry]), dtype=np.float32)


class Connection:
    def __init__(self, conn, separator):
        self.conn = conn
        self.separator = separator
        self.lock = threading.Condition()
        self.stream = None
        self.closed = False

    def serve(self):
        worker = threading.Thread(target=self.process_loop, daemon=True)
        worker.start()
        try:
            while True:
                magic, msg_type, value = HEADER.unpack(recv_exact(self.conn, HEADER.size))
                if magic != MAGIC:
                    raise ValueError(f"bad magic 0x{magic:08x} (protocol mismatch)")
                if msg_type == MSG_HELLO:
                    # Sends happen under the lock, so no stale RESULT can follow the ACK
                    with self.lock:
                        self.stream = Stream(int(value))
                        send_message(self.conn, MSG_HELLO_ACK, PROTOCOL_VERSION)
                    log(f"Stream configured at {value} Hz")
                elif msg_type == MSG_AUDIO:
                    if value > MAX_FRAMES_PER_MESSAGE:
                        raise ValueError(f"audio message too large: {value} frames")
                    payload = recv_exact(self.conn, value * CHANNELS * 4)
                    samples = np.frombuffer(payload, dtype="<f4").reshape(-1, CHANNELS)
                    with self.lock:
                        if self.stream is not None:
                            self.stream.push(samples)
                            self.lock.notify()
                else:
                    raise ValueError(f"unexpected message type {msg_type}")
        except (ConnectionError, OSError) as error:
            log(f"Client disconnected: {error}")
        except ValueError as error:
            log(f"Protocol error: {error}")
        finally:
            with self.lock:
                self.closed = True
                self.lock.notify()
            self.conn.close()

    def process_loop(self):
        while True:
            with self.lock:
                while not self.closed and (self.stream is None or self.stream.pending_frames < self.stream.hop):
                    self.lock.wait()
                if self.closed:
                    return
                stream = self.stream
                hop = stream.take_hop()
            started = time.time()
            try:
                result = stream.step(self.separator, hop)
            except Exception as error:  # noqa: BLE001 - keep the stream alive
                log(f"Processing error: {error}")
                continue
            payload = result.astype("<f4").tobytes()
            with self.lock:
                if stream is not self.stream:
                    continue  # reconfigured meanwhile: drop stale output
                try:
                    send_message(self.conn, MSG_RESULT, result.shape[0], payload)
                except OSError:
                    return
            log(f"Processed {HOP_S:.1f}s in {time.time() - started:.2f}s")


def watch_parent(parent_pid):
    """Exit when the app that launched us is gone (crash, force quit)."""
    while True:
        if os.getppid() != parent_pid:
            log("Parent process exited, shutting down")
            os._exit(0)
        time.sleep(1.0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=19845)
    parser.add_argument("--parent-pid", type=int, default=None)
    args = parser.parse_args()

    if args.parent_pid:
        threading.Thread(target=watch_parent, args=(args.parent_pid,), daemon=True).start()

    log(f"PyTorch {torch.__version__}, MPS available: {torch.backends.mps.is_available()}")
    separator = Separator()
    if not separator.load():
        log("Cannot start without a model")
        return 2

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(("127.0.0.1", args.port))
    except OSError as error:
        log(f"Cannot listen on port {args.port}: {error}")
        return 3
    server.listen(1)
    log(f"Listening on 127.0.0.1:{args.port}")

    try:
        while True:
            conn, addr = server.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            log(f"Client connected: {addr}")
            # One client at a time: the app is the only user
            Connection(conn, separator).serve()
    except KeyboardInterrupt:
        log("Shutting down")
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
