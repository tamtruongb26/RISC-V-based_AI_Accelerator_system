# Description of C Files

## 1. sigmoid.c

### Purpose
The `sigmoid.c` file contains the sigmoid activation function used in artificial neural networks. The sigmoid function converts input values to values in the range (0, 1), commonly used for binary classification problems.

### How to Run
```bash
gcc sigmoid.c -o sigmoid
./sigmoid
```

---

## 2. mlp_c.c

### Purpose
The `mlp_c.c` file is an implementation of Multi-Layer Perceptron (MLP) - a type of artificial neural network with multiple layers. This file performs:
- Forward propagation
- Backpropagation for training
- Prediction with new data

### How to Run
```bash
gcc mlp_c.c -o mlp_c
./mlp_c
```

---

## Notes
- GCC compiler needs to be installed to compile the C files.
- Additional libraries such as `math.h` may be required if using mathematical functions.