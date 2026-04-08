import numpy as np
from tensorflow.keras.datasets import mnist
from MLP import Network

def vectorized_label(j):
    e = np.zeros((10, 1))
    e[j] = 1.0
    return e


def fixed_point_int(v, frac_bits=11):
    return int(round(v * (1 << frac_bits)))

def save_biases_and_weights(net, bias_file="../bias.txt", weight_file="../weights.txt"):
    # Ghi bias theo thứ tự:
    # hidden1 -> hidden2 -> output
    with open(bias_file, "w") as fb:
        for b in net.biases:
            for v in b.flatten():
                fb.write(f"{fixed_point_int(float(v))}\n")

    # Ghi weight theo thứ tự:
    # weight_1 (16x784) -> weight_2 (16x16) -> weight_3 (10x16)
    with open(weight_file, "w") as fw:
        for w in net.weights:
            for row in w:
                for v in row:
                    fw.write(f"{fixed_point_int(float(v))}\n")

print("Loading MNIST...")
(x_train, y_train), (x_test, y_test) = mnist.load_data()
print("MNIST loaded")

# Normalize
x_train = x_train.astype("float32") / 255.0
x_test = x_test.astype("float32") / 255.0

# Chạy thử trước với tập nhỏ cho nhanh
train_limit = 60000
test_limit = 10000

training_data = [
    (x.reshape(784, 1), vectorized_label(int(y)))
    for x, y in zip(x_train[:train_limit], y_train[:train_limit])
]

test_data = [
    (x.reshape(784, 1), int(y))
    for x, y in zip(x_test[:test_limit], y_test[:test_limit])
]

print("Train samples:", len(training_data))
print("Test samples:", len(test_data))

# Kiến trúc phải khớp với mlp_c.c
net = Network([784, 16, 16, 10])

print("Start training...")
net.SGD(training_data, epochs=33, mini_batch_size=10, eta=3.0, test_data=test_data)
print("Training done")

print("Saving weights and biases...")
save_biases_and_weights(net)
print("Saved: bias.txt, weights.txt")

correct = net.evaluate(test_data)
print("Python correct:", correct)
print("Python accuracy:", correct / len(test_data) * 100)