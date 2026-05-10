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

#endif /* LENET_H */
