#!/usr/bin/env python3
"""
lenet_reference.py — Q1.4.11 fixed-point reference model for LeNet-5

Runs LeNet-5 inference in fixed-point arithmetic matching the hardware.
Produces golden outputs per layer for firmware debugging.

Usage:
    python3 lenet_reference.py [--image-index N]
"""

import argparse
import struct
import os
import sys

# ── Q1.4.11 fixed-point helpers ──────────────────────────────────────────

FRAC_BITS = 11
SCALE = 1 << FRAC_BITS  # 2048
Q_MIN = -32768
Q_MAX = 32767

def float_to_q(val):
    """Float → Q1.4.11 (signed 16-bit)."""
    v = int(round(val * SCALE))
    return max(Q_MIN, min(Q_MAX, v))

def q_to_float(val):
    """Q1.4.11 → float."""
    # sign-extend 16-bit
    if val >= 0x8000:
        val -= 0x10000
    return val / SCALE

def q_mul(a, b):
    """Q1.4.11 × Q1.4.11 → Q1.4.11 (truncate, no rounding)."""
    prod = a * b  # 32-bit result in Q2.8.22
    # Right-shift by FRAC_BITS to get back to Q1.4.11
    result = prod >> FRAC_BITS
    return max(Q_MIN, min(Q_MAX, result))

def q_add(a, b):
    """Q1.4.11 + Q1.4.11 → Q1.4.11 (saturate)."""
    result = a + b
    return max(Q_MIN, min(Q_MAX, result))

def q_relu(x):
    return max(0, x)

# ── Load hex weights ─────────────────────────────────────────────────────

def load_hex(path):
    """Load Q1.4.11 hex file → list of signed int16."""
    values = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16)
            if v >= 0x8000:
                v -= 0x10000
            values.append(v)
    return values

# ── Matrix operations in Q1.4.11 ─────────────────────────────────────────

def gemm_q(A, W, bias, M, K, N, apply_relu=True):
    """
    C[M×N] = A[M×K] × W[K×N] + bias[N]
    All in Q1.4.11. A, W, bias are flat lists.
    Returns flat list C[M×N].
    """
    C = [0] * (M * N)
    for m in range(M):
        for n in range(N):
            acc = 0
            for k in range(K):
                a_val = A[m * K + k]
                w_val = W[k * N + n]
                # Accumulate in wider precision (like hardware 40-bit acc)
                acc += a_val * w_val
            # Truncate accumulated result back to Q1.4.11 range
            # Hardware does: trunc Q2.8.22 → add bias → saturate Q1.4.11
            result = acc >> FRAC_BITS
            if bias is not None:
                result = result + bias[n]
            result = max(Q_MIN, min(Q_MAX, result))
            if apply_relu:
                result = q_relu(result)
            C[m * N + n] = result
    return C

def im2col_q(data, C_in, H, W, kH, kW, stride=1):
    """
    im2col transform. data layout: CHW (channel-first, flat).
    Returns flat matrix [H_out*W_out × C_in*kH*kW].
    """
    H_out = (H - kH) // stride + 1
    W_out = (W - kW) // stride + 1
    M = H_out * W_out
    K = C_in * kH * kW
    result = [0] * (M * K)

    for h_out in range(H_out):
        for w_out in range(W_out):
            row = h_out * W_out + w_out
            col = 0
            for c in range(C_in):
                for kh in range(kH):
                    for kw in range(kW):
                        h_in = h_out * stride + kh
                        w_in = w_out * stride + kw
                        result[row * K + col] = data[c * H * W + h_in * W + w_in]
                        col += 1
    return result

def maxpool2x2_q(data, C, H, W):
    """Max-pool 2×2 stride 2. data layout: CHW flat. Returns CHW flat."""
    H_out = H // 2
    W_out = W // 2
    result = [0] * (C * H_out * W_out)
    for c in range(C):
        for h in range(H_out):
            for w in range(W_out):
                vals = [
                    data[c*H*W + (2*h)*W + (2*w)],
                    data[c*H*W + (2*h)*W + (2*w+1)],
                    data[c*H*W + (2*h+1)*W + (2*w)],
                    data[c*H*W + (2*h+1)*W + (2*w+1)],
                ]
                result[c*H_out*W_out + h*W_out + w] = max(vals)
    return result

def transpose_weights(w_flat, shape_out, shape_in_per_filter):
    """
    Transpose from PyTorch [C_out, K_total] to GEMM [K_total, C_out].
    w_flat: flat list in PyTorch order [C_out × K_total]
    Returns: flat list in [K_total × C_out] order.
    """
    C_out = shape_out
    K_total = shape_in_per_filter
    # w_flat is [C_out, K_total] row-major
    result = [0] * (K_total * C_out)
    for co in range(C_out):
        for k in range(K_total):
            result[k * C_out + co] = w_flat[co * K_total + k]
    return result

# ── Load MNIST image ─────────────────────────────────────────────────────

def load_mnist_image(data_dir, index=0):
    """Load image + label from raw MNIST files. Returns (pixels_28x28, label)."""
    img_path = os.path.join(data_dir, 't10k-images-idx3-ubyte')
    lbl_path = os.path.join(data_dir, 't10k-labels-idx1-ubyte')

    with open(img_path, 'rb') as f:
        magic, num, rows, cols = struct.unpack('>IIII', f.read(16))
        assert magic == 2051 and rows == 28 and cols == 28
        f.seek(16 + index * 784)
        pixels = list(f.read(784))

    with open(lbl_path, 'rb') as f:
        magic, num = struct.unpack('>II', f.read(8))
        assert magic == 2049
        f.seek(8 + index)
        label = f.read(1)[0]

    return pixels, label

# ── Main ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image-index', type=int, default=0)
    parser.add_argument('--export-dir', default=None,
                        help='Path to export_0.986 directory')
    args = parser.parse_args()

    # Paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    model_dir = args.export_dir or os.path.join(
        repo_root, 'model', 'LeNet5-MNIST-PyTorch', 'models', 'export_0.986')
    mnist_dir = os.path.join(
        repo_root, 'model', 'LeNet5-MNIST-PyTorch', 'test', 'MNIST', 'raw')

    print(f"Model dir: {model_dir}")
    print(f"MNIST dir: {mnist_dir}")

    # Load weights (PyTorch order: [C_out, C_in, kH, kW] flattened)
    conv1_w_raw = load_hex(os.path.join(model_dir, 'conv1.weight_q1_4_11.hex'))
    conv1_b     = load_hex(os.path.join(model_dir, 'conv1.bias_q1_4_11.hex'))
    conv2_w_raw = load_hex(os.path.join(model_dir, 'conv2.weight_q1_4_11.hex'))
    conv2_b     = load_hex(os.path.join(model_dir, 'conv2.bias_q1_4_11.hex'))
    fc1_w_raw   = load_hex(os.path.join(model_dir, 'fc1.weight_q1_4_11.hex'))
    fc1_b       = load_hex(os.path.join(model_dir, 'fc1.bias_q1_4_11.hex'))
    fc2_w_raw   = load_hex(os.path.join(model_dir, 'fc2.weight_q1_4_11.hex'))
    fc2_b       = load_hex(os.path.join(model_dir, 'fc2.bias_q1_4_11.hex'))
    fc3_w_raw   = load_hex(os.path.join(model_dir, 'fc3.weight_q1_4_11.hex'))
    fc3_b       = load_hex(os.path.join(model_dir, 'fc3.bias_q1_4_11.hex'))

    print(f"Loaded weights: conv1={len(conv1_w_raw)}, conv2={len(conv2_w_raw)}, "
          f"fc1={len(fc1_w_raw)}, fc2={len(fc2_w_raw)}, fc3={len(fc3_w_raw)}")

    # Transpose weights: PyTorch [C_out, K_total] → GEMM [K_total, C_out]
    conv1_w = transpose_weights(conv1_w_raw, 6, 25)     # [25, 6]
    conv2_w = transpose_weights(conv2_w_raw, 16, 150)    # [150, 16]
    fc1_w   = transpose_weights(fc1_w_raw, 120, 256)     # [256, 120]
    fc2_w   = transpose_weights(fc2_w_raw, 84, 120)      # [120, 84]
    fc3_w   = transpose_weights(fc3_w_raw, 10, 84)       # [84, 10]

    # Load test image
    pixels, label = load_mnist_image(mnist_dir, args.image_index)
    print(f"\nImage index: {args.image_index}, Label: {label}")

    # Quantize image: pixel [0,255] → float [0,1] → Q1.4.11
    # PyTorch ToTensor() divides by 255
    image_q = [float_to_q(p / 255.0) for p in pixels]
    print(f"Image Q1.4.11 range: [{min(image_q)}, {max(image_q)}]")

    # ── Layer 1: Conv1 ──
    print("\n=== Conv1: im2col(1×28×28, k=5) → GEMM(576×25×6) + ReLU ===")
    im2col_1 = im2col_q(image_q, C_in=1, H=28, W=28, kH=5, kW=5)
    conv1_out_flat = gemm_q(im2col_1, conv1_w, conv1_b, M=576, K=25, N=6, apply_relu=True)
    # Reshape to CHW for next layer: [576] → but it's [H_out*W_out, C_out] = [576, 6]
    # Need to convert to [C_out, H_out, W_out] = [6, 24, 24]
    conv1_chw = [0] * (6 * 24 * 24)
    for hw in range(576):
        for c in range(6):
            h, w = hw // 24, hw % 24
            conv1_chw[c * 24 * 24 + h * 24 + w] = conv1_out_flat[hw * 6 + c]
    print(f"  Conv1 output (first 8): {[q_to_float(x) for x in conv1_out_flat[:8]]}")

    # ── Layer 2: Pool1 ──
    print("\n=== Pool1: maxpool2x2(6×24×24) → 6×12×12 ===")
    pool1_out = maxpool2x2_q(conv1_chw, C=6, H=24, W=24)
    print(f"  Pool1 output (first 8): {[q_to_float(x) for x in pool1_out[:8]]}")

    # ── Layer 3: Conv2 ──
    print("\n=== Conv2: im2col(6×12×12, k=5) → GEMM(64×150×16) + ReLU ===")
    im2col_2 = im2col_q(pool1_out, C_in=6, H=12, W=12, kH=5, kW=5)
    conv2_out_flat = gemm_q(im2col_2, conv2_w, conv2_b, M=64, K=150, N=16, apply_relu=True)
    conv2_chw = [0] * (16 * 8 * 8)
    for hw in range(64):
        for c in range(16):
            h, w = hw // 8, hw % 8
            conv2_chw[c * 8 * 8 + h * 8 + w] = conv2_out_flat[hw * 16 + c]
    print(f"  Conv2 output (first 8): {[q_to_float(x) for x in conv2_out_flat[:8]]}")

    # ── Layer 4: Pool2 ──
    print("\n=== Pool2: maxpool2x2(16×8×8) → 16×4×4 ===")
    pool2_out = maxpool2x2_q(conv2_chw, C=16, H=8, W=8)
    print(f"  Pool2 output (first 8): {[q_to_float(x) for x in pool2_out[:8]]}")
    # Flatten: [16, 4, 4] → [256] (already in correct order for FC)

    # ── Layer 5: FC1 ──
    print("\n=== FC1: GEMM(1×256×120) + ReLU ===")
    fc1_out = gemm_q(pool2_out, fc1_w, fc1_b, M=1, K=256, N=120, apply_relu=True)
    print(f"  FC1 output (first 8): {[q_to_float(x) for x in fc1_out[:8]]}")

    # ── Layer 6: FC2 ──
    print("\n=== FC2: GEMM(1×120×84) + ReLU ===")
    fc2_out = gemm_q(fc1_out, fc2_w, fc2_b, M=1, K=120, N=84, apply_relu=True)
    print(f"  FC2 output (first 8): {[q_to_float(x) for x in fc2_out[:8]]}")

    # ── Layer 7: FC3 ──
    print("\n=== FC3: GEMM(1×84×10) + ReLU ===")
    fc3_out = gemm_q(fc2_out, fc3_w, fc3_b, M=1, K=84, N=10, apply_relu=True)
    print(f"  FC3 output (all 10): {[q_to_float(x) for x in fc3_out]}")

    # ── Argmax ──
    predicted = fc3_out.index(max(fc3_out))
    print(f"\n{'='*50}")
    print(f"Predicted: {predicted}, Label: {label}, "
          f"{'CORRECT' if predicted == label else 'WRONG'}")
    print(f"{'='*50}")

    # ── Dump golden per layer (hex) for firmware debug ──
    golden_dir = os.path.join(script_dir, 'golden')
    os.makedirs(golden_dir, exist_ok=True)

    def dump_hex(name, data):
        path = os.path.join(golden_dir, f'{name}.hex')
        with open(path, 'w') as f:
            for v in data:
                if v < 0:
                    v += 0x10000
                f.write(f'{v:04X}\n')
        print(f"  Written {path} ({len(data)} values)")

    print("\nDumping golden outputs:")
    dump_hex('image_q', image_q)
    dump_hex('conv1_out', conv1_out_flat)
    dump_hex('pool1_out', pool1_out)
    dump_hex('conv2_out', conv2_out_flat)
    dump_hex('pool2_out', pool2_out)
    dump_hex('fc1_out', fc1_out)
    dump_hex('fc2_out', fc2_out)
    dump_hex('fc3_out', fc3_out)

    return 0 if predicted == label else 1

if __name__ == '__main__':
    sys.exit(main())
