# RAAS smoke test — Vitis IDE setup guide

Hướng dẫn step-by-step để chạy smoke test PicoRV32 firmware trên Ultra96-v2 qua JTAG. PS app load PicoRV32 firmware vào BRAM, prefill DDR test data, deassert reset, poll mailbox.

---

## Prerequisites

- ✅ Vivado RAS.bd compiled, bitstream `fpga/RAS.runs/impl_1/RAS_wrapper.bit`
- ✅ PicoRV32 firmware built: `cd sw/picorv32 && make` → `build/firmware_image.h` xuất hiện
- ✅ Test data generated bằng Python có `numpy` → `sw/vitis/RAS_application/src/smoketest_data.h` xuất hiện
- Ultra96-v2 board + USB-JTAG cable + USB-UART (cùng micro-USB cable)
- Vitis 2025.2.1 (cùng Vivado version)

---

## Step 1: Export Hardware từ Vivado

1. Open `fpga/RAS.xpr` trong Vivado.
2. `File → Export → Export Hardware`.
3. ✓ **Include bitstream**.
4. Output path: `fpga/RAS_wrapper.xsa`.
5. Click Finish. Đợi vài giây.

---

## Step 2: Tạo Platform Project trong Vitis IDE

1. Launch Vitis IDE: terminal chạy `/home/tam/Documents/app/2025.2.1/Vitis/bin/vitis &`.
2. Chọn workspace repo hiện tại: `/home/tam/Documents/RAAS/sw/vitis`.
3. `File → New → Platform Project`.
   - **Project name**: `RAS_platform`
   - **Create from hardware specification (XSA)**: ✓
   - **Hardware specification (.xsa)**: browse → `/home/tam/Documents/RAAS/fpga/RAS_wrapper.xsa`
   - **Operating system**: `standalone`
   - **Processor**: `psu_cortexa53_0`
   - **Generate boot components**: ☐ (không tick — dùng JTAG, không SD card)
4. Finish. Platform sẽ build tự động (~1-2 phút).
5. Verify: trong Explorer thấy `RAS_platform`. Repo hiện tại đã có platform ở `sw/vitis/RAS_platform`.

---

## Step 3: Tạo Application Project

1. `File → New → Application Project`.
2. Page **Platform**: chọn `RAS_platform` đã tạo.
3. Page **Application Project Details**:
   - **Application project name**: `RAS_application`
   - **System project name**: tự sinh (`RAS_application_system`)
   - **Domain**: `standalone_psu_cortexa53_0` (auto)
   - **CPU**: `psu_cortexa53_0`
4. Page **Domain**: giữ default.
5. Page **Templates**: chọn `Empty Application (C)`.
6. Finish.

---

## Step 4: Verify BSP settings (cache + UART)

1. Mở `RAS_platform → standalone_psu_cortexa53_0 → Board Support Package` (double-click `BSP Settings`).
2. **Standalone library settings**:
   - `stdin` = `psu_uart_0`
   - `stdout` = `psu_uart_0`
3. Save BSP. Vitis re-build platform (~30s).

---

## Step 5: Import source files

3 header cần có trong app source folder hiện tại `sw/vitis/RAS_application/src/`:

```bash
cd /home/tam/Documents/RAAS
WS=/home/tam/Documents/RAAS/sw/vitis/RAS_application/src
VITIS_PY=/home/tam/Documents/app/2025.2.1/tps/lnx64/python-3.13.0/bin/python3
VITIS_PY_LIB=/home/tam/Documents/app/2025.2.1/tps/lnx64/python-3.13.0/lib

cp sw/common/raas_map.h "$WS/"
cp sw/picorv32/build/firmware_image.h "$WS"
LD_LIBRARY_PATH="$VITIS_PY_LIB" "$VITIS_PY" tools/gen_smoketest.py --out "$WS/smoketest_data.h"
```

Lưu ý: `smoketest_data.h` là file được sinh ra, không phải source bắt buộc phải có sẵn để `cp`. Dòng cũ `cp .../sw/vitis/RAS_smoketest/src/smoketest_data.h ...` chỉ đúng khi đã dùng folder `RAS_smoketest` làm nơi stash file sinh ra. Với tree hiện tại, sinh thẳng vào `RAS_application/src` như trên là rõ nhất. Nếu dùng `/usr/bin/python3` mà báo `ModuleNotFoundError: No module named 'numpy'`, dùng đúng `VITIS_PY` như command trên.

Sau đó **refresh** project: chuột phải `RAS_application → Refresh` (F5).

---

## Step 6: Tạo `main.c` — paste full source

Trong Vitis: chuột phải `RAS_application/src → New → Source File → main.c`. Paste content sau:

```c
/******************************************************************************
 * main.c — RAAS smoke test PS app (Ultra96-v2 bare-metal A53)
 *
 * Workflow:
 *   1. Hold PicoRV32 in reset.
 *   2. Load firmware bytes vào BRAM @ PS view 0xA0000000.
 *   3. Prefill DDR @ PS view 0x10000000 với weights/bias/input/golden.
 *   4. Init mailbox = MBX_BOOT.
 *   5. Cache flush DDR (PicoRV32 đọc qua HP0 non-coherent).
 *   6. Release PicoRV32 reset.
 *   7. Poll mailbox; print result.
 ******************************************************************************/
#include <stdio.h>
#include <stdint.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "raas_map.h"
#include "firmware_image.h"     /* pico_firmware[], pico_firmware_len */
#include "smoketest_data.h"     /* smoketest_weights/bias/input/golden */

/* Poll limits — tốc độ A53 ~1 GHz, mỗi iteration vài cycle */
#define MAILBOX_POLL_LIMIT     100000000u
#define DDR_PS_BASE            RAAS_PS_DDR_BASE   /* = 0x10000000 */
#define BRAM_PS_BASE           RAAS_PS_BRAM_BASE  /* = 0xA0000000 */

/* ── Helper: load PicoRV32 firmware (uint8_t array) vào BRAM (32-bit AXI) ─ */
static void load_firmware_to_bram(void)
{
    uint32_t word_count = (pico_firmware_len + 3u) / 4u;
    for (uint32_t w = 0; w < word_count; w++) {
        uint32_t value = 0u;
        for (uint32_t b = 0; b < 4; b++) {
            uint32_t idx = w * 4u + b;
            if (idx < pico_firmware_len) {
                value |= ((uint32_t)pico_firmware[idx]) << (b * 8u);
            }
        }
        Xil_Out32(BRAM_PS_BASE + w * 4u, value);
    }
    /* BRAM via axi_bram_ctrl_2 ở vùng PL peripheral (Device memory non-cacheable
     * trong default MMU). Flush vẫn an toàn idempotent. */
    Xil_DCacheFlushRange(BRAM_PS_BASE, pico_firmware_len);
}

/* ── Helper: copy 32-bit aligned data → DDR ─────────────────────────────── */
static void write_words_to_ddr(uint32_t ddr_offset, const uint32_t *src,
                               uint32_t word_count)
{
    for (uint32_t i = 0; i < word_count; i++) {
        Xil_Out32(DDR_PS_BASE + ddr_offset + i * 4u, src[i]);
    }
}

static void write_uint16_to_ddr(uint32_t ddr_offset, const uint16_t *src,
                                uint32_t cell_count)
{
    /* DDR ghi qua 32-bit. Pack 2×u16 thành 1×u32 cẩn thận với endian. */
    for (uint32_t i = 0; i < cell_count; i += 2) {
        uint32_t lo = (uint32_t)src[i];
        uint32_t hi = (i + 1 < cell_count) ? (uint32_t)src[i + 1] : 0u;
        uint32_t word = (hi << 16) | lo;
        Xil_Out32(DDR_PS_BASE + ddr_offset + (i / 2) * 4u, word);
    }
}

/* ── Helper: prefill DDR + flush ─────────────────────────────────────────── */
static void prefill_ddr(void)
{
    write_words_to_ddr(RAAS_DDR_WEIGHTS_OFFSET,
                       smoketest_weights, RAAS_WEIGHTS_WORDS);
    write_words_to_ddr(RAAS_DDR_BIAS_OFFSET,
                       smoketest_bias, RAAS_BIAS_WORDS);
    write_words_to_ddr(RAAS_DDR_INPUT_OFFSET,
                       smoketest_input, RAAS_INPUT_WORDS);
    write_uint16_to_ddr(RAAS_DDR_GOLDEN_OFFSET,
                        smoketest_golden, RAAS_OUTPUT_CELLS);

    /* Init mailbox = BOOT */
    Xil_Out32(DDR_PS_BASE + RAAS_DDR_MAILBOX_OFFSET, RAAS_MBX_BOOT);

    /* QUAN TRỌNG: flush A53 cache để PicoRV32 (HP0 non-coherent) thấy data */
    Xil_DCacheFlushRange(DDR_PS_BASE, RAAS_DDR_USED_SIZE);
}

/* ── Helper: poll mailbox với cache invalidate ───────────────────────────── */
static uint32_t wait_mailbox_change(void)
{
    for (uint32_t i = 0; i < MAILBOX_POLL_LIMIT; i++) {
        Xil_DCacheInvalidateRange(DDR_PS_BASE + RAAS_DDR_MAILBOX_OFFSET, 4);
        uint32_t value = Xil_In32(DDR_PS_BASE + RAAS_DDR_MAILBOX_OFFSET);
        if (value != RAAS_MBX_BOOT && value != RAAS_MBX_STARTED) {
            return value;
        }
    }
    return 0xFFFFFFFFu;  /* timeout */
}

/* ── Helper: print captured output cells (debug) ─────────────────────────── */
static void print_output_buffer(void)
{
    Xil_DCacheInvalidateRange(DDR_PS_BASE + RAAS_DDR_OUTPUT_OFFSET,
                              RAAS_OUTPUT_CELLS * 2);
    volatile const uint16_t *out =
        (volatile const uint16_t *)(DDR_PS_BASE + RAAS_DDR_OUTPUT_OFFSET);
    volatile const uint16_t *gold =
        (volatile const uint16_t *)(DDR_PS_BASE + RAAS_DDR_GOLDEN_OFFSET);

    xil_printf("Output buffer (first 8 cells, hex Q1.4.11):\r\n");
    for (uint32_t i = 0; i < 8; i++) {
        xil_printf("  [%2d] got=0x%04x exp=0x%04x %s\r\n",
                   i, (uint32_t)out[i], (uint32_t)gold[i],
                   (out[i] == gold[i]) ? "OK" : "DIFF");
    }
}

int main(void)
{
    xil_printf("\r\n=== RAAS smoke test boot ===\r\n");
    xil_printf("Firmware size: %u bytes\r\n", (unsigned int)pico_firmware_len);

    /* 1. Hold PicoRV32 in reset */
    Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_HOLD);
    xil_printf("PicoRV32 held in reset\r\n");

    /* 2. Load firmware vào BRAM */
    load_firmware_to_bram();
    xil_printf("Loaded firmware to BRAM @ 0x%08x\r\n", (unsigned int)BRAM_PS_BASE);

    /* 3-4. Prefill DDR + init mailbox + cache flush */
    prefill_ddr();
    xil_printf("Prefilled DDR @ 0x%08x\r\n", (unsigned int)DDR_PS_BASE);

    /* 5. Release PicoRV32 reset */
    Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_RUN);
    xil_printf("PicoRV32 released — polling mailbox...\r\n");

    /* 6. Poll mailbox */
    uint32_t result = wait_mailbox_change();

    switch (result) {
    case RAAS_MBX_PASS:
        xil_printf("\r\n>>> RESULT: PASS <<<\r\n");
        break;
    case RAAS_MBX_FAIL:
        xil_printf("\r\n>>> RESULT: FAIL <<<\r\n");
        print_output_buffer();
        break;
    case RAAS_MBX_DMA_TIMEOUT:
        xil_printf("\r\n>>> RESULT: DMA TIMEOUT <<<\r\n");
        break;
    case RAAS_MBX_DMA_ERROR:
        xil_printf("\r\n>>> RESULT: DMA ERROR (DMASR err bit) <<<\r\n");
        break;
    case RAAS_MBX_ACCEL_TIMEOUT:
        xil_printf("\r\n>>> RESULT: ACCELERATOR TIMEOUT <<<\r\n");
        break;
    case 0xFFFFFFFFu:
        xil_printf("\r\n>>> RESULT: PS POLL TIMEOUT (firmware not running?) <<<\r\n");
        break;
    default:
        xil_printf("\r\n>>> RESULT: UNKNOWN 0x%08x <<<\r\n", (unsigned int)result);
        break;
    }

    while (1) {}
    return 0;  /* unreachable */
}
```

---

## Step 7: Build

1. Chuột phải `RAS_application → Build Project` (Ctrl+B).
2. Console phải hiện target `RAS_application.elf` build xong.
3. Output nằm dưới `sw/vitis/RAS_application/build/` (~ vài trăm KB).

---

## Step 8: Run via JTAG

### 8.1 Setup hardware

1. Cắm Ultra96-v2 USB-JTAG cable (micro-USB sang PC).
2. Bật nguồn board.
3. UART monitor: terminal khác chạy:
   ```bash
   sudo picocom -b 115200 /dev/ttyUSB1
   ```
   (Hoặc `/dev/ttyUSB0` tùy enumeration. Check `dmesg | grep tty` sau khi cắm.)

### 8.2 Run trong Vitis IDE

1. Trong Vitis: chuột phải `RAS_application → Run As → 1 Launch Hardware`.
2. Lần đầu: chọn `Run Configurations → Single Application Debug → New Configuration`.
3. Verify:
   - **Bitstream**: `RAS_wrapper.bit` (auto-detect từ platform)
   - **PS init**: `psu_init.tcl` (auto)
4. Click `Run`.
5. UART monitor sẽ in:
   ```
   === RAAS smoke test boot ===
   Firmware size: 800 bytes
   PicoRV32 held in reset
   Loaded firmware to BRAM @ 0xa0000000
   Prefilled DDR @ 0x10000000
   PicoRV32 released — polling mailbox...
   
   >>> RESULT: PASS <<<
   ```

### 8.3 (Alternative) Run via xsdb script

Nếu muốn skip Vitis IDE Run dialog, dùng xsdb command-line. Xem `scripts/jtag_smoketest.tcl` (sẽ viết ở Step 14.6).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| UART không in gì | UART0 không enabled trong BSP | Step 4 verify `stdout = psu_uart_0` |
| `>>> PS POLL TIMEOUT <<<` | PicoRV32 không boot (firmware sai BRAM) | Check `Xil_Out32` thay vì `memcpy` ở `load_firmware_to_bram()` |
| `>>> RESULT: FAIL <<<` 64 cells diff | Cache không flush, PicoRV32 đọc data cũ | Verify `Xil_DCacheFlushRange(DDR_PS_BASE, RAAS_DDR_USED_SIZE)` được gọi sau prefill |
| `>>> RESULT: DMA TIMEOUT <<<` | DMA accelerator AXIS không nối đúng | Mở Vivado BD, verify `axi_dma_0/M_AXIS_MM2S → accelerator_1/S00_AXIS` |
| `>>> RESULT: ACCEL TIMEOUT <<<` | accelerator state machine stuck | Check timing constraint, hoặc tăng `ACCEL_TIMEOUT` trong sw/picorv32/src/main.c |
| Build fail "raas_map.h not found" | Header chưa nằm trong app src hoặc include path thiếu | Verify file nằm ở `sw/vitis/RAS_application/src/`; nếu cần add include `${workspace_loc:/RAS_application/src}` |

---

## File checklist trước khi build

```
sw/vitis/RAS_application/src/
├── main.c                  ← Step 6 paste
├── raas_map.h              ← copy từ sw/common/
├── firmware_image.h        ← copy từ sw/picorv32/build/
└── smoketest_data.h        ← generate bằng tools/gen_smoketest.py
```

Nếu thiếu file nào → build fail với "header not found".

---

## Re-run sau khi đổi firmware

Workflow re-run khi sửa PicoRV32 firmware:

```bash
cd sw/picorv32 && make
```

`make` sẽ rebuild `build/firmware_image.h` và auto-copy sang `../vitis/RAS_application/src/firmware_image.h`.

Trong Vitis: F5 refresh project → Ctrl+B build → Run.

(Vitis build app source trong `RAS_application/src`, nên firmware header cần nằm ở đó; Makefile hiện đã auto-copy đúng folder này.)
