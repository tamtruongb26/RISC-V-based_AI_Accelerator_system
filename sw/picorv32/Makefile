# =============================================================================
# Makefile — PicoRV32 firmware build (RAAS)
#
# Targets:
#   make all     — build smoke test firmware (src/main.c)
#   make lenet   — build LeNet-5 firmware (src/main_lenet.c)
#   make clean   — remove all build artifacts
#
# Output (for each target):
#   build/firmware*.elf  — debug ELF với symbol
#   build/firmware*.bin  — raw binary (load thẳng vào BRAM)
#   build/firmware*.map  — link map
#   build/firmware*.lst  — disassembly
#   build/firmware*_image.h — C array để PS app embed
# =============================================================================

CROSS    := /home/tam/Documents/app/2025.2.1/gnu/riscv/lin/x86_64-oesdk-linux/usr/bin/riscv32-xilinx-elf/riscv32-xilinx-elf-
CC       := $(CROSS)gcc
LD       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size

BUILD    := build

# Include paths
INCLUDES := -I include -I ../common

# Compiler flags — RV32IM, ilp32 ABI, freestanding bare-metal
CFLAGS   := -march=rv32im -mabi=ilp32 \
            -Os -ffreestanding -fno-builtin \
            -ffunction-sections -fdata-sections \
            -Wall -Wextra -Wno-unused-parameter \
            $(INCLUDES)

ASFLAGS  := -march=rv32im -mabi=ilp32

# Base linker flags (MAP will be set per-target)
LDFLAGS_BASE := -T linker.ld -nostdlib \
                -Wl,--gc-sections \
                -march=rv32im -mabi=ilp32

# Tool to convert .bin → C array
BIN2C    := python3 ../../tools/bin_to_c.py

# Shared modules (used by both smoke test and lenet)
SHARED_C := src/accel.c src/dma.c src/mailbox.c
STARTUP  := startup.S

# ── Smoke test target (default) ──────────────────────────────────────
SMOKE_MAIN   := src/main.c
SMOKE_SRCS   := $(SMOKE_MAIN) $(SHARED_C)
SMOKE_OBJS   := $(addprefix $(BUILD)/smoke.,$(notdir $(SMOKE_SRCS:.c=.o))) $(BUILD)/smoke.startup.o
SMOKE_ELF    := $(BUILD)/firmware.elf
SMOKE_BIN    := $(BUILD)/firmware.bin
SMOKE_MAP    := $(BUILD)/firmware.map
SMOKE_LST    := $(BUILD)/firmware.lst
SMOKE_HDR    := $(BUILD)/firmware_image.h
PS_SMOKE_HDR := ../vitis/RAS_application/src/firmware_image.h

# ── LeNet-5 target ───────────────────────────────────────────────────
LENET_MAIN   := src/main_lenet.c
LENET_SRCS   := $(LENET_MAIN) src/gemm_tile.c src/im2col.c src/pool.c src/lenet.c $(SHARED_C)
LENET_OBJS   := $(addprefix $(BUILD)/lenet.,$(notdir $(LENET_SRCS:.c=.o))) $(BUILD)/lenet.startup.o
LENET_ELF    := $(BUILD)/firmware_lenet.elf
LENET_BIN    := $(BUILD)/firmware_lenet.bin
LENET_MAP    := $(BUILD)/firmware_lenet.map
LENET_LST    := $(BUILD)/firmware_lenet.lst
LENET_HDR    := $(BUILD)/firmware_lenet_image.h
PS_LENET_HDR := ../vitis/RAS_lenet/src/firmware_image.h

.PHONY: all lenet clean size size_lenet

# ═══════════════════════════════════════════════════════════════════════
# Smoke test build
# ═══════════════════════════════════════════════════════════════════════

all: $(SMOKE_BIN) $(SMOKE_LST) $(SMOKE_HDR) install_smoke_hdr size

$(BUILD):
	@mkdir -p $@

$(BUILD)/smoke.%.o: src/%.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/smoke.startup.o: startup.S | $(BUILD)
	$(CC) $(ASFLAGS) -c $< -o $@

$(SMOKE_ELF): $(SMOKE_OBJS) linker.ld | $(BUILD)
	$(LD) $(SMOKE_OBJS) $(LDFLAGS_BASE) -Wl,-Map,$(SMOKE_MAP) -o $@

$(SMOKE_BIN): $(SMOKE_ELF)
	$(OBJCOPY) -O binary $< $@

$(SMOKE_LST): $(SMOKE_ELF)
	$(OBJDUMP) -d -S $< > $@

$(SMOKE_HDR): $(SMOKE_BIN)
	$(BIN2C) $< $@ pico_firmware

install_smoke_hdr: $(SMOKE_HDR)
	@if [ -d $(dir $(PS_SMOKE_HDR)) ]; then \
		cp $(SMOKE_HDR) $(PS_SMOKE_HDR); \
		echo "Copied $(SMOKE_HDR) → $(PS_SMOKE_HDR)"; \
	fi

size: $(SMOKE_ELF)
	@echo ""
	@echo "═══════════════ Smoke test firmware size ═══════════════"
	@$(SIZE) $(SMOKE_ELF)
	@TOTAL=$$($(SIZE) -d $(SMOKE_ELF) | awk 'NR==2 {print $$1+$$2+$$3}'); \
	  echo "Total used: $$TOTAL bytes / 65536 (64KB BRAM)"; \
	  if [ $$TOTAL -gt 65536 ]; then echo "❌ EXCEEDS 64KB!"; exit 1; fi
	@echo "═══════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════════
# LeNet-5 build
# ═══════════════════════════════════════════════════════════════════════

lenet: $(LENET_BIN) $(LENET_LST) $(LENET_HDR) install_lenet_hdr size_lenet

$(BUILD)/lenet.%.o: src/%.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/lenet.startup.o: startup.S | $(BUILD)
	$(CC) $(ASFLAGS) -c $< -o $@

$(LENET_ELF): $(LENET_OBJS) linker.ld | $(BUILD)
	$(LD) $(LENET_OBJS) $(LDFLAGS_BASE) -Wl,-Map,$(LENET_MAP) -o $@

$(LENET_BIN): $(LENET_ELF)
	$(OBJCOPY) -O binary $< $@

$(LENET_LST): $(LENET_ELF)
	$(OBJDUMP) -d -S $< > $@

$(LENET_HDR): $(LENET_BIN)
	$(BIN2C) $< $@ pico_firmware

install_lenet_hdr: $(LENET_HDR)
	@if [ -d $(dir $(PS_LENET_HDR)) ]; then \
		cp $(LENET_HDR) $(PS_LENET_HDR); \
		echo "Copied $(LENET_HDR) → $(PS_LENET_HDR)"; \
	fi

size_lenet: $(LENET_ELF)
	@echo ""
	@echo "═══════════════ LeNet-5 firmware size ═══════════════"
	@$(SIZE) $(LENET_ELF)
	@TOTAL=$$($(SIZE) -d $(LENET_ELF) | awk 'NR==2 {print $$1+$$2+$$3}'); \
	  echo "Total used: $$TOTAL bytes / 65536 (64KB BRAM)"; \
	  if [ $$TOTAL -gt 65536 ]; then echo "❌ EXCEEDS 64KB!"; exit 1; fi
	@echo "═══════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════════
# Verilog simulation hex
# ═══════════════════════════════════════════════════════════════════════

hex: $(BUILD)/firmware.hex
$(BUILD)/firmware.hex: $(SMOKE_ELF)
	$(OBJCOPY) -O verilog $< $@

hex_lenet: $(BUILD)/firmware_lenet.hex
$(BUILD)/firmware_lenet.hex: $(LENET_ELF)
	$(OBJCOPY) -O verilog $< $@

# ═══════════════════════════════════════════════════════════════════════
# Clean
# ═══════════════════════════════════════════════════════════════════════

clean:
	rm -rf $(BUILD)
	@if [ -f $(PS_SMOKE_HDR) ]; then rm $(PS_SMOKE_HDR); echo "Removed $(PS_SMOKE_HDR)"; fi
	@if [ -f $(PS_LENET_HDR) ]; then rm $(PS_LENET_HDR); echo "Removed $(PS_LENET_HDR)"; fi

print-objs:
	@echo "SMOKE_OBJS = $(SMOKE_OBJS)"
	@echo "LENET_OBJS = $(LENET_OBJS)"
