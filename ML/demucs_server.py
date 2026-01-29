#!/usr/bin/env python3
"""
Demucs Real-time Server for BlackHoleMonitorApp
Provides high-quality vocal separation with ~3s latency
"""

import socket
import struct
import threading
import numpy as np
from collections import deque
import time
import os
import sys

# Fix SSL certificate issue on macOS
import ssl
ssl._create_default_https_context = ssl._create_unverified_context

# Add user site-packages to path
sys.path.insert(0, os.path.expanduser('~/Library/Python/3.13/lib/python3.13/site-packages'))

import torch
import torchaudio
from demucs import pretrained
from demucs.apply import apply_model

# Server configuration
HOST = '127.0.0.1'
PORT = 19845
SAMPLE_RATE = 44100
CHANNELS = 2
CHUNK_DURATION = 3.0  # seconds to buffer before processing
OVERLAP = 0.5  # overlap between chunks for smooth transitions

class DemucsServer:
    def __init__(self):
        self.model = None
        self.device = 'mps' if torch.backends.mps.is_available() else 'cpu'
        self.input_buffer = deque()
        self.output_buffer = deque()
        self.buffer_lock = threading.Lock()
        self.running = False
        self.processing_thread = None
        
        # Buffer sizes in samples
        self.chunk_samples = int(CHUNK_DURATION * SAMPLE_RATE)
        self.overlap_samples = int(OVERLAP * SAMPLE_RATE)
        self.hop_samples = self.chunk_samples - self.overlap_samples
        
        # Crossfade window for overlap-add
        self.fade_in = np.linspace(0, 1, self.overlap_samples).astype(np.float32)
        self.fade_out = np.linspace(1, 0, self.overlap_samples).astype(np.float32)
        
        # Previous overlap for crossfade
        self.prev_overlap = None
        
        print(f"[Demucs] Device: {self.device}")
        print(f"[Demucs] Chunk: {CHUNK_DURATION}s ({self.chunk_samples} samples)")
        print(f"[Demucs] Overlap: {OVERLAP}s ({self.overlap_samples} samples)")
        
    def load_model(self):
        """Load Demucs model"""
        print("[Demucs] Loading model (htdemucs)...")
        try:
            self.model = pretrained.get_model('htdemucs')
            self.model.to(self.device)
            self.model.eval()
            print("[Demucs] Model loaded successfully!")
            return True
        except Exception as e:
            print(f"[Demucs] Failed to load model: {e}")
            # Try smaller model
            try:
                print("[Demucs] Trying htdemucs_ft...")
                self.model = pretrained.get_model('htdemucs_ft')
                self.model.to(self.device)
                self.model.eval()
                print("[Demucs] Model htdemucs_ft loaded!")
                return True
            except Exception as e2:
                print(f"[Demucs] Failed to load any model: {e2}")
                return False
    
    def process_audio(self, audio):
        """
        Process audio through Demucs to remove vocals
        audio: numpy array (samples, 2) - stereo interleaved
        returns: numpy array (samples, 2) - instrumentals only
        """
        if self.model is None:
            return audio
            
        try:
            # Convert to torch tensor (channels, samples)
            waveform = torch.from_numpy(audio.T).float().unsqueeze(0)  # (1, 2, samples)
            
            # Ensure correct sample rate
            if SAMPLE_RATE != self.model.samplerate:
                waveform = torchaudio.transforms.Resample(
                    SAMPLE_RATE, self.model.samplerate
                )(waveform)
            
            waveform = waveform.to(self.device)
            
            # Apply model
            with torch.no_grad():
                sources = apply_model(self.model, waveform, device=self.device)
            
            # sources shape: (1, num_sources, 2, samples)
            # htdemucs sources: drums, bass, other, vocals
            # We want everything except vocals (index 3)
            
            # Sum all sources except vocals
            instrumental = sources[0, 0] + sources[0, 1] + sources[0, 2]  # drums + bass + other
            
            # Resample back if needed
            if SAMPLE_RATE != self.model.samplerate:
                instrumental = torchaudio.transforms.Resample(
                    self.model.samplerate, SAMPLE_RATE
                )(instrumental.unsqueeze(0)).squeeze(0)
            
            # Convert back to numpy (samples, 2)
            result = instrumental.cpu().numpy().T
            
            return result.astype(np.float32)
            
        except Exception as e:
            print(f"[Demucs] Processing error: {e}")
            return audio
    
    def processing_loop(self):
        """Background thread for processing audio"""
        print("[Demucs] Processing thread started")
        
        while self.running:
            # Check if we have enough samples to process
            with self.buffer_lock:
                buffer_samples = len(self.input_buffer)
            
            if buffer_samples >= self.chunk_samples:
                # Extract chunk for processing
                with self.buffer_lock:
                    chunk = np.array([self.input_buffer.popleft() 
                                     for _ in range(self.hop_samples)])
                    # Keep overlap in buffer for next chunk
                
                start_time = time.time()
                
                # Reconstruct full chunk with overlap from previous
                if self.prev_overlap is not None:
                    full_chunk = np.vstack([self.prev_overlap, chunk])
                else:
                    # First chunk - pad with zeros
                    full_chunk = np.vstack([np.zeros((self.overlap_samples, CHANNELS), dtype=np.float32), chunk])
                
                # Process through Demucs
                processed = self.process_audio(full_chunk)
                
                # Apply crossfade for overlap-add
                if self.prev_overlap is not None and len(processed) > self.overlap_samples:
                    # Crossfade the overlap region
                    for ch in range(CHANNELS):
                        processed[:self.overlap_samples, ch] *= self.fade_in
                
                # Store overlap for next iteration
                self.prev_overlap = full_chunk[-self.overlap_samples:]
                
                # Output the non-overlap portion
                output_chunk = processed[self.overlap_samples:]
                
                # Add to output buffer
                with self.buffer_lock:
                    for sample in output_chunk:
                        self.output_buffer.append(sample)
                
                proc_time = time.time() - start_time
                print(f"[Demucs] Processed {len(full_chunk)/SAMPLE_RATE:.2f}s in {proc_time:.2f}s "
                      f"(buffer: {buffer_samples/SAMPLE_RATE:.1f}s)")
            else:
                time.sleep(0.01)
        
        print("[Demucs] Processing thread stopped")
    
    def handle_client(self, conn, addr):
        """Handle a connected client"""
        print(f"[Demucs] Client connected: {addr}")
        
        try:
            while self.running:
                # Read header (4 bytes: num_samples as int32)
                header = conn.recv(4)
                if not header or len(header) < 4:
                    break
                
                num_samples = struct.unpack('<I', header)[0]
                
                if num_samples == 0:
                    # Heartbeat / status request
                    with self.buffer_lock:
                        output_available = len(self.output_buffer)
                    conn.sendall(struct.pack('<I', output_available))
                    continue
                
                if num_samples == 0xFFFFFFFF:
                    # Request to read output
                    with self.buffer_lock:
                        available = min(4096, len(self.output_buffer))
                        if available > 0:
                            output_data = np.array([self.output_buffer.popleft() 
                                                   for _ in range(available)])
                        else:
                            output_data = np.array([])
                    
                    # Send output
                    conn.sendall(struct.pack('<I', len(output_data)))
                    if len(output_data) > 0:
                        conn.sendall(output_data.astype(np.float32).tobytes())
                    continue
                
                # Read audio data
                data_size = num_samples * CHANNELS * 4  # float32
                audio_data = b''
                while len(audio_data) < data_size:
                    chunk = conn.recv(min(4096, data_size - len(audio_data)))
                    if not chunk:
                        break
                    audio_data += chunk
                
                if len(audio_data) < data_size:
                    break
                
                # Convert to numpy
                samples = np.frombuffer(audio_data, dtype=np.float32).reshape(-1, CHANNELS)
                
                # Add to input buffer
                with self.buffer_lock:
                    for sample in samples:
                        self.input_buffer.append(sample)
                
                # Send ack
                conn.sendall(struct.pack('<I', len(samples)))
                
        except Exception as e:
            print(f"[Demucs] Client error: {e}")
        finally:
            print(f"[Demucs] Client disconnected: {addr}")
            conn.close()
    
    def start(self):
        """Start the server"""
        if not self.load_model():
            print("[Demucs] Cannot start without model")
            return False
        
        self.running = True
        
        # Start processing thread
        self.processing_thread = threading.Thread(target=self.processing_loop, daemon=True)
        self.processing_thread.start()
        
        # Start server
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((HOST, PORT))
        self.server.listen(1)
        
        print(f"[Demucs] Server listening on {HOST}:{PORT}")
        
        try:
            while self.running:
                self.server.settimeout(1.0)
                try:
                    conn, addr = self.server.accept()
                    client_thread = threading.Thread(
                        target=self.handle_client, 
                        args=(conn, addr),
                        daemon=True
                    )
                    client_thread.start()
                except socket.timeout:
                    continue
        except KeyboardInterrupt:
            print("\n[Demucs] Shutting down...")
        finally:
            self.running = False
            self.server.close()
        
        return True
    
    def stop(self):
        """Stop the server"""
        self.running = False


def main():
    print("=" * 50)
    print("Demucs Vocal Separation Server")
    print("=" * 50)
    print(f"PyTorch: {torch.__version__}")
    print(f"MPS available: {torch.backends.mps.is_available()}")
    print()
    
    server = DemucsServer()
    server.start()


if __name__ == "__main__":
    main()
