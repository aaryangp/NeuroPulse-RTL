# ECG Neural Network Inference Engine (ASIC RTL)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Tools: Yosys](https://img.shields.io/badge/EDA-Yosys-blue)](https://yosyshq.net/)
[![Tools: OpenSTA](https://img.shields.io/badge/STA-OpenSTA-green)](https://github.com/The-OpenROAD-Project/OpenSTA)

A high-performance, area-efficient hardware accelerator for classifying ECG signals using a Multi-Layer Perceptron (MLP) architecture. This project implements a full inference pipeline in Verilog HDL, verified via simulation and synthesized targeting a 45nm ASIC flow.

---

## 📌 Project Overview
This project implements a dedicated **2-layer Neural Network** (MLP) specialized for detecting abnormal heartbeats from normalized, peak-centered ECG data. By moving the classification from software to dedicated RTL, the engine achieves ultra-low latency and minimal power consumption, suitable for battery-constrained medical wearables.

### 🧠 MLP Architecture (100:32:1)
- **Input:** 100-sample ECG window (Peak-Centered).
- **Hidden Layer (Layer 1):** 32 Neurons with parallelized **ReLU** activation.
- **Output Layer (Layer 2):** 1 Neuron with a **Piecewise Linear Sigmoid** approximation.
- **Arithmetic:** 16-bit Fixed-Point (**Q7.8 format**) for optimized hardware precision.

---

## 🛠️ Detailed Implementation Breakdown

### 1. Memory-Mapped Input Management
To avoid the physical limitations of a 100-pin input layout, this design utilizes an **internal SRAM-style memory array** (`reg [15:0] input_data [0:99]`). 
- **Scalability:** The architecture mimics real-world SoC designs where data is buffered from an ADC or DMA engine before processing.
- **Efficiency:** Centralizing the data in memory allows the FSM to sequentially fetch samples, significantly reducing routing congestion and physical I/O count.

### 2. Resource-Shared Datapath (MAC Engine)
Instead of instantiating 33 separate multipliers, the engine employs a **Resource-Sharing Strategy**:
- **Single MAC Unit:** A single high-speed Multiply-Accumulate (MAC) unit is time-multiplexed across every neuron in the network.
- **Computation Logic:** The engine performs the weighted sum calculation: $$\sum_{i=0}^{99} (W_i \cdot X_i) + B$$
- **Precision:** The MAC uses 16-bit $Q7.8$ inputs and maintains internal precision before truncating for the activation stage, preventing overflow during the 100-cycle accumulation phase.

### 3. FSM-Based Control Unit
The system is governed by a Finite State Machine (FSM) that manages the lifecycle of a single inference:
- `IDLE`: Resets registers and waits for the `start` pulse.
- `LOAD_PARAM`: Fetches weights and biases from internal ROMs.
- `CALC`: Sequentially iterates through 100 memory indices per neuron.
- `ACTIVATION`: Routes the sum through ReLU (Hidden) or Sigmoid (Output) logic.
- `DONE`: Latches the final probability and pulses the `valid` signal.

### 4. Non-Linear Activation Functions
- **ReLU (Hidden Layer):** Implemented as a hardware-efficient comparator/mux.
- **Piecewise Linear Sigmoid (Output Layer):** Instead of using resource-heavy exponential functions or large Look-Up Tables (LUTs), the Sigmoid curve is approximated using linear segments. This implementation consumes **less than 1%** of the total chip area.

---

## 📊 Synthesis & Physical Metrics
Synthesized using **Yosys** and timing-verified with **OpenSTA** targeting the **Nangate 45nm Open Cell Library**.

| Metric | Value |
| :--- | :--- |
| **Total Area** | 16,573.66 µm² |
| **Cell Count** | 10,081 |
| **Registers (Flip-Flops)** | 1,205 |
| **Combinational Gates** | 8,876 |
| **Target Frequency** | 100 MHz (10ns clock) |
| **Worst Negative Slack (WNS)** | **+3.69 ns** (Timing Met) |
| **Estimated Power** | 10.2 mW |

### Area Breakdown
| Module | Area Contribution |
| :--- | :--- |
| **Weight/Bias Memory** | 26.1% |
| **MAC Unit** | 15.2% |
| **ReLU Logic** | 3.8% |
| **Sigmoid Approx** | 0.6% |
| **Control Logic / FSM** | 54.3% |

---

## ✅ Verification Results
The engine has been verified using a comprehensive testbench suite.
- **Normalization Support:** Verified that normalized signals (0.0 to 1.0) maintain stability within the fixed-point range.
- **Classification Accuracy:** Confirmed binary prediction (Yes/No) capabilities. In tests with peak-centered abnormal spikes, the engine produced an output probability of `00fb` (~98.4%).
- **Noise Floor:** Confirmed that flatline signals do not trigger false positives, ensuring bias values are correctly balanced.

---

## 🤝 Collaboration & Credits
This project was a collaborative effort. Special thanks to:
- **Sandeep Choudhary**
- **Irfan**

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

**Developed by Aaryan Gupta** 
