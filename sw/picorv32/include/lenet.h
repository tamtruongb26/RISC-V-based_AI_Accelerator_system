/******************************************************************************
 * lenet.h — LeNet-5 inference orchestration API
 ******************************************************************************/
#ifndef LENET_H
#define LENET_H

#include <stdint.h>

/*
 * lenet5_infer — Run full LeNet-5 inference on a single image.
 *
 * Assumes PS has already prefilled DDR with:
 *   - Image at LENET_DDR_IMAGE_OFF
 *   - All weights/biases at their respective offsets
 *
 * Executes 7 layers: Conv1→Pool1→Conv2→Pool2→FC1→FC2→FC3→argmax
 * Uses ping-pong buffers (FMAP_A / FMAP_B) for intermediate results.
 *
 * Returns: predicted digit (0–9).
 */
int lenet5_infer(int use_hw);

/* Phase 5: demo 4-config reliability (golden / no-harden / ECC / TMR).
 * Tiêm lỗi tại fault_bit @ fault_trig (cycle từ clear) → chạy LeNet mỗi config,
 * ghi predicted + counter vào DDR REL fields. Tune (bit,trig) để hit Conv read. */
void reliability_demo(uint32_t fault_bit, uint32_t fault_trig);

#endif /* LENET_H */
