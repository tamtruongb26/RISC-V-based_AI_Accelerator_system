/******************************************************************************
 * mailbox.c — Mailbox writer implementation
 *
 * Plan ref: §8.3 (Step 14.3).
 ******************************************************************************/

#include "mailbox.h"
#include "io.h"
#include "raas_map.h"

void mailbox_set(uint32_t value)
{
    mmio_write32(RAAS_PICO_DDR_ADDR(RAAS_DDR_MAILBOX_OFFSET), value);
    fence_iorw();
}
