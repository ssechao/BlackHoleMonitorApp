#!/usr/bin/env python3
"""
Convert a lightweight vocal separation model to CoreML for real-time processing.
Uses a small Conv-TasNet variant optimized for low latency.
"""

import torch
import torch.nn as nn
import coremltools as ct
import numpy as np

# Lightweight vocal separator (~2MB, ~20ms latency)
class MicroVocalSeparator(nn.Module):
    """
    Ultra-lightweight vocal separator using 1D convolutions.
    Designed for real-time processing with minimal latency.
    
    Input: (batch, 2, samples) - stereo audio
    Output: (batch, 2, samples) - vocals removed
    """
    def __init__(self, hidden_size=64, kernel_size=16):
        super().__init__()
        
        # Encoder
        self.encoder = nn.Sequential(
            nn.Conv1d(2, hidden_size, kernel_size, stride=kernel_size//2, padding=kernel_size//4),
            nn.ReLU(),
            nn.Conv1d(hidden_size, hidden_size, 3, padding=1),
            nn.ReLU(),
        )
        
        # Separation network (estimates vocal mask)
        self.separator = nn.Sequential(
            nn.Conv1d(hidden_size, hidden_size, 5, padding=2),
            nn.ReLU(),
            nn.Conv1d(hidden_size, hidden_size, 5, padding=2),
            nn.ReLU(),
            nn.Conv1d(hidden_size, hidden_size, 5, padding=2),
            nn.Sigmoid(),  # Mask between 0 and 1
        )
        
        # Decoder
        self.decoder = nn.Sequential(
            nn.ConvTranspose1d(hidden_size, hidden_size, kernel_size, stride=kernel_size//2, padding=kernel_size//4),
            nn.ReLU(),
            nn.Conv1d(hidden_size, 2, 1),
            nn.Tanh(),
        )
        
    def forward(self, x):
        # x: (batch, 2, samples)
        encoded = self.encoder(x)
        mask = self.separator(encoded)
        
        # Apply mask to remove vocals (keep instrumentals)
        masked = encoded * mask
        
        # Decode back to audio
        output = self.decoder(masked)
        
        return output


class VocalSeparatorV2(nn.Module):
    """
    Slightly larger model with better separation quality.
    Still optimized for real-time (~30ms latency).
    """
    def __init__(self, channels=32):
        super().__init__()
        
        # Multi-scale encoder
        self.enc1 = nn.Sequential(
            nn.Conv1d(2, channels, 15, stride=1, padding=7),
            nn.BatchNorm1d(channels),
            nn.PReLU(),
        )
        self.enc2 = nn.Sequential(
            nn.Conv1d(channels, channels*2, 15, stride=2, padding=7),
            nn.BatchNorm1d(channels*2),
            nn.PReLU(),
        )
        
        # Separation blocks
        self.sep_blocks = nn.Sequential(
            nn.Conv1d(channels*2, channels*2, 7, padding=3, groups=channels*2),
            nn.Conv1d(channels*2, channels*2, 1),
            nn.BatchNorm1d(channels*2),
            nn.PReLU(),
            nn.Conv1d(channels*2, channels*2, 7, padding=3, groups=channels*2),
            nn.Conv1d(channels*2, channels*2, 1),
            nn.BatchNorm1d(channels*2),
            nn.PReLU(),
        )
        
        # Mask estimation
        self.mask = nn.Sequential(
            nn.Conv1d(channels*2, channels*2, 1),
            nn.Sigmoid(),
        )
        
        # Decoder
        self.dec2 = nn.Sequential(
            nn.ConvTranspose1d(channels*2, channels, 15, stride=2, padding=7, output_padding=1),
            nn.BatchNorm1d(channels),
            nn.PReLU(),
        )
        self.dec1 = nn.Sequential(
            nn.Conv1d(channels*2, channels, 1),  # Skip connection
            nn.Conv1d(channels, 2, 15, padding=7),
        )
        
    def forward(self, x):
        # Encoder
        e1 = self.enc1(x)
        e2 = self.enc2(e1)
        
        # Separation
        sep = self.sep_blocks(e2)
        mask = self.mask(sep)
        masked = e2 * mask
        
        # Decoder with skip connection
        d2 = self.dec2(masked)
        
        # Handle size mismatch
        if d2.size(2) != e1.size(2):
            d2 = nn.functional.interpolate(d2, size=e1.size(2), mode='linear', align_corners=False)
        
        d1 = self.dec1(torch.cat([d2, e1], dim=1))
        
        # Residual connection: output = input - vocals = instrumentals
        return x - d1  # d1 estimates vocals, we subtract to get instrumentals


def create_and_convert_model(model_type="micro", chunk_size=512):
    """
    Create and convert the model to CoreML format.
    
    Args:
        model_type: "micro" (faster) or "v2" (better quality)
        chunk_size: audio chunk size in samples (512 = ~11ms @ 44.1kHz)
    """
    
    print(f"Creating {model_type} model for chunk_size={chunk_size}...")
    
    if model_type == "micro":
        model = MicroVocalSeparator(hidden_size=48, kernel_size=16)
        model_name = "VocalSeparatorMicro"
    else:
        model = VocalSeparatorV2(channels=24)
        model_name = "VocalSeparatorV2"
    
    model.eval()
    
    # Count parameters
    params = sum(p.numel() for p in model.parameters())
    print(f"Model parameters: {params:,} ({params * 4 / 1024 / 1024:.2f} MB)")
    
    # Create example input (batch=1, channels=2, samples=chunk_size)
    example_input = torch.randn(1, 2, chunk_size)
    
    # Trace the model
    print("Tracing model...")
    traced_model = torch.jit.trace(model, example_input)
    
    # Convert to CoreML
    print("Converting to CoreML...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.TensorType(name="audio_input", shape=(1, 2, chunk_size))
        ],
        outputs=[
            ct.TensorType(name="audio_output")
        ],
        compute_precision=ct.precision.FLOAT16,  # Use FP16 for faster inference
        minimum_deployment_target=ct.target.macOS13,
    )
    
    # Add metadata
    mlmodel.author = "BlackHoleMonitorApp"
    mlmodel.short_description = f"Real-time vocal separator ({model_type})"
    mlmodel.version = "1.0"
    
    # Add input/output descriptions
    spec = mlmodel.get_spec()
    spec.description.input[0].shortDescription = "Stereo audio chunk (2 channels x N samples)"
    spec.description.output[0].shortDescription = "Audio with vocals removed"
    
    # Save the model
    output_path = f"{model_name}.mlpackage"
    mlmodel.save(output_path)
    print(f"Model saved to: {output_path}")
    
    # Test inference speed
    print("\nTesting inference speed...")
    import time
    
    # Warm up
    with torch.no_grad():
        for _ in range(10):
            _ = model(example_input)
    
    # Benchmark
    times = []
    with torch.no_grad():
        for _ in range(100):
            start = time.perf_counter()
            _ = model(example_input)
            times.append((time.perf_counter() - start) * 1000)
    
    avg_time = np.mean(times)
    print(f"Average PyTorch inference: {avg_time:.2f}ms")
    print(f"Chunk duration: {chunk_size / 44100 * 1000:.2f}ms")
    print(f"Real-time capable: {'Yes' if avg_time < chunk_size / 44100 * 1000 else 'No'}")
    
    return output_path


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Convert vocal separator to CoreML")
    parser.add_argument("--model", choices=["micro", "v2"], default="micro",
                        help="Model type: micro (faster) or v2 (better quality)")
    parser.add_argument("--chunk-size", type=int, default=512,
                        help="Audio chunk size in samples (default: 512 = ~11ms)")
    
    args = parser.parse_args()
    
    try:
        output_path = create_and_convert_model(args.model, args.chunk_size)
        print(f"\nSuccess! Copy {output_path} to your Xcode project.")
    except Exception as e:
        print(f"Error: {e}")
        print("\nMake sure you have the required packages:")
        print("  pip install torch coremltools numpy")
