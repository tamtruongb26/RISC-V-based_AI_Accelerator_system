#!/usr/bin/env python3
"""Export one deterministic MNIST smoke-test vector for the RAAS board demo."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_SV = ROOT / "references/Deep-Neural-Network-Hardware-Accelerator/Source/Project/HDL/MLP/tb/top_module/mnist_inputs_weights_biases_bin.sv"
REFERENCE_LABELS = ROOT / "references/Deep-Neural-Network-Hardware-Accelerator/Source/Project/HDL/MLP/tb/top_module/labels.txt"
SIGMOID_RTL = ROOT / "hw/accelerator_1_0/src/sigmoid_lookup.sv"
COMMON_HEADER = ROOT / "sw/common/raas_demo_data.h"
SIM_HEADER = ROOT / "hw/accelerator_1_0/tb/raas_demo_vectors.svh"
SIM_DATA_DIR = ROOT / "build/sim/data"
SIM_IMAGE_MEM = SIM_DATA_DIR / "raas_demo_image.mem"
SIM_BIAS_MEM = SIM_DATA_DIR / "raas_demo_bias.mem"
SIM_WEIGHT_MEM = SIM_DATA_DIR / "raas_demo_weight.mem"
SIM_GOLDEN_MEM = SIM_DATA_DIR / "raas_demo_golden.mem"

INPUT_NODES = 784
HIDDEN1_NODES = 16
HIDDEN2_NODES = 16
OUTPUT_NODES = 10
IMAGE_WORDS = INPUT_NODES // 2
HIDDEN_WORDS = HIDDEN1_NODES // 2
OUTPUT_WORDS = OUTPUT_NODES // 2

LAYER_SHAPES = (
    (INPUT_NODES, HIDDEN1_NODES),
    (HIDDEN1_NODES, HIDDEN2_NODES),
    (HIDDEN2_NODES, OUTPUT_NODES),
)


def parse_sv_array(text: str, name: str) -> list[int]:
    pattern = rf"logic\s+\[15:0\]\s+{re.escape(name)}\s*\[[^\]]+\]\s*=\s*\{{(.*?)\}};"
    match = re.search(pattern, text, flags=re.DOTALL)
    if not match:
        raise ValueError(f"Could not find SystemVerilog array {name}")
    values = [int(bits, 2) for bits in re.findall(r"16'b([01]{16})", match.group(1))]
    if not values:
        raise ValueError(f"SystemVerilog array {name} had no 16-bit values")
    return values


def parse_sigmoid_rom(text: str) -> list[int]:
    rom = [0] * 1024
    seen = set()
    for idx, value in re.findall(r"rom\[(\d+)\]\s*=\s*10'd(\d+)", text):
        i = int(idx)
        if not 0 <= i < 1024:
            raise ValueError(f"Sigmoid ROM index out of range: {i}")
        rom[i] = int(value)
        seen.add(i)
    if len(seen) != 1024:
        missing = sorted(set(range(1024)) - seen)[:8]
        raise ValueError(f"Sigmoid ROM is incomplete, missing {missing}")
    return rom


def read_labels(path: Path) -> list[int]:
    return [int(line.strip()) for line in path.read_text().splitlines() if line.strip()]


def u16(value: int) -> int:
    return value & 0xFFFF


def s16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def u32(value: int) -> int:
    return value & 0xFFFFFFFF


def s32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def pack_u16(lo: int, hi: int) -> int:
    return u16(lo) | (u16(hi) << 16)


def pack_pairs(values: Iterable[int]) -> list[int]:
    packed: list[int] = []
    data = list(values)
    if len(data) % 2:
        raise ValueError("Only even-length packed data is supported by the current accelerator")
    for i in range(0, len(data), 2):
        packed.append(pack_u16(data[i], data[i + 1]))
    return packed


def pack_weights(weights: list[int]) -> list[int]:
    packed: list[int] = []
    offset = 0
    for prev_nodes, curr_nodes in LAYER_SHAPES:
        for pair in range(curr_nodes // 2):
            neuron_a = 2 * pair
            neuron_b = neuron_a + 1
            for inp in range(prev_nodes):
                a = weights[offset + neuron_a * prev_nodes + inp]
                b = weights[offset + neuron_b * prev_nodes + inp]
                packed.append(pack_u16(a, b))
        offset += prev_nodes * curr_nodes
    if offset != len(weights):
        raise ValueError(f"Consumed {offset} weights but reference has {len(weights)}")
    return packed


def bias_to_q1_8_7_bits(bias: int) -> int:
    sign_extend = 0xF800 if bias & 0x8000 else 0
    integer_bits = ((bias >> 11) & 0xF) << 7
    fraction_bits = (bias >> 4) & 0x7F
    return sign_extend | integer_bits | fraction_bits


def neuron_output(inputs: list[int], weights: list[int], bias: int, sigmoid: list[int]) -> int:
    acc = 0
    for inp, weight in zip(inputs, weights):
        acc = s32(acc + (s16(inp) * s16(weight)))

    acc_bits = u32(acc)
    acc_reduced_bits = ((acc_bits >> 31) << 15) | ((acc_bits >> 15) & 0x7FFF)
    summed = s16(acc_reduced_bits) + s16(bias_to_q1_8_7_bits(bias))
    sum_bits = u16(summed)

    if (sum_bits & 0x8000) == 0 and (sum_bits & 0x7800) != 0:
        address = 0x1FF
    elif (sum_bits & 0x8000) != 0 and (sum_bits & 0x7800) != 0x7800:
        address = 0x200
    else:
        address = ((sum_bits >> 15) << 9) | ((sum_bits >> 2) & 0x1FF)

    return (sigmoid[address] << 2) & 0xFFFF


def run_layer(inputs: list[int], weights: list[int], biases: list[int], sigmoid: list[int],
              prev_nodes: int, curr_nodes: int, weight_offset: int, bias_offset: int) -> list[int]:
    outputs: list[int] = []
    for neuron in range(curr_nodes):
        start = weight_offset + neuron * prev_nodes
        row = weights[start:start + prev_nodes]
        outputs.append(neuron_output(inputs, row, biases[bias_offset + neuron], sigmoid))
    return outputs


def run_network(image: list[int], weights: list[int], biases: list[int], sigmoid: list[int]) -> list[int]:
    weight_offset = 0
    bias_offset = 0
    layer_inputs = image
    for prev_nodes, curr_nodes in LAYER_SHAPES:
        layer_outputs = run_layer(layer_inputs, weights, biases, sigmoid, prev_nodes, curr_nodes,
                                  weight_offset, bias_offset)
        weight_offset += prev_nodes * curr_nodes
        bias_offset += curr_nodes
        layer_inputs = layer_outputs
    return layer_inputs


def format_c_array(name: str, values: list[int], indent: str = "    ") -> str:
    lines = [f"static const uint32_t {name}[{len(values)}] = {{"]
    for i in range(0, len(values), 8):
        chunk = ", ".join(f"0x{value:08X}u" for value in values[i:i + 8])
        comma = "," if i + 8 < len(values) else ""
        lines.append(f"{indent}{chunk}{comma}")
    lines.append("};")
    return "\n".join(lines)


def write_mem(path: Path, values: list[int]) -> None:
    path.write_text("".join(f"{value:08X}\n" for value in values))


def select_image(inputs: list[int], labels: list[int], weights: list[int],
                 biases: list[int], sigmoid: list[int]) -> tuple[int, list[int], list[int], int]:
    images = len(inputs) // INPUT_NODES
    if images == 0:
        raise ValueError("No complete MNIST images found in reference array")
    if len(labels) < images:
        images = len(labels)

    fallback: tuple[int, list[int], list[int], int] | None = None
    for index in range(images):
        image = inputs[index * INPUT_NODES:(index + 1) * INPUT_NODES]
        outputs = run_network(image, weights, biases, sigmoid)
        prediction = max(range(OUTPUT_NODES), key=lambda i: outputs[i])
        if fallback is None:
            fallback = (index, image, outputs, prediction)
        if prediction == labels[index]:
            return index, image, outputs, prediction

    assert fallback is not None
    return fallback


def main() -> None:
    reference_text = REFERENCE_SV.read_text()
    biases = parse_sv_array(reference_text, "biases")
    inputs = parse_sv_array(reference_text, "inputs")
    weights = parse_sv_array(reference_text, "weights")
    labels = read_labels(REFERENCE_LABELS)
    sigmoid = parse_sigmoid_rom(SIGMOID_RTL.read_text())

    if len(biases) != HIDDEN1_NODES + HIDDEN2_NODES + OUTPUT_NODES:
        raise ValueError(f"Expected 42 biases, got {len(biases)}")
    if len(weights) != sum(prev * curr for prev, curr in LAYER_SHAPES):
        raise ValueError(f"Expected 12960 weights, got {len(weights)}")

    image_index, image, outputs, prediction = select_image(inputs, labels, weights, biases, sigmoid)
    expected = labels[image_index]

    image_words = pack_pairs(image)
    bias_words = pack_pairs(biases)
    weight_words = pack_weights(weights)
    golden_words = pack_pairs(outputs)

    COMMON_HEADER.parent.mkdir(parents=True, exist_ok=True)
    SIM_HEADER.parent.mkdir(parents=True, exist_ok=True)
    SIM_DATA_DIR.mkdir(parents=True, exist_ok=True)

    COMMON_HEADER.write_text(
        "\n".join([
            "#ifndef RAAS_DEMO_DATA_H",
            "#define RAAS_DEMO_DATA_H",
            "",
            "#include <stdint.h>",
            "#include \"raas_memory_map.h\"",
            "",
            "/* Generated by tools/export_raas_demo_data.py from the fixed-point MNIST references. */",
            f"#define RAAS_DEMO_IMAGE_INDEX {image_index}u",
            f"#define RAAS_DEMO_EXPECTED_DIGIT {expected}u",
            f"#define RAAS_DEMO_GOLDEN_DIGIT {prediction}u",
            "",
            format_c_array("raas_demo_image_words", image_words),
            "",
            format_c_array("raas_demo_bias_words", bias_words),
            "",
            format_c_array("raas_demo_weight_words", weight_words),
            "",
            format_c_array("raas_demo_golden_output_words", golden_words),
            "",
            "#endif",
            "",
        ])
    )

    write_mem(SIM_IMAGE_MEM, image_words)
    write_mem(SIM_BIAS_MEM, bias_words)
    write_mem(SIM_WEIGHT_MEM, weight_words)
    write_mem(SIM_GOLDEN_MEM, golden_words)

    SIM_HEADER.write_text(
        "\n".join([
            "`ifndef RAAS_DEMO_VECTORS_SVH",
            "`define RAAS_DEMO_VECTORS_SVH",
            "",
            "// Generated by tools/export_raas_demo_data.py from the fixed-point MNIST references.",
            f"localparam int RAAS_DEMO_IMAGE_INDEX = {image_index};",
            f"localparam int RAAS_DEMO_EXPECTED_DIGIT = {expected};",
            f"localparam int RAAS_DEMO_GOLDEN_DIGIT = {prediction};",
            "`define RAAS_DEMO_IMAGE_MEM \"../data/raas_demo_image.mem\"",
            "`define RAAS_DEMO_BIAS_MEM \"../data/raas_demo_bias.mem\"",
            "`define RAAS_DEMO_WEIGHT_MEM \"../data/raas_demo_weight.mem\"",
            "`define RAAS_DEMO_GOLDEN_MEM \"../data/raas_demo_golden.mem\"",
            "",
            "`endif",
            "",
        ])
    )

    print(f"selected image {image_index}: expected={expected}, golden={prediction}")
    print(f"wrote {COMMON_HEADER.relative_to(ROOT)}")
    print(f"wrote {SIM_HEADER.relative_to(ROOT)}")
    print("wrote build/sim/data/raas_demo_*.mem")


if __name__ == "__main__":
    main()
