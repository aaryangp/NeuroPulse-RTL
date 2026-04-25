
// Weight Storage Module using Block RAM
// ============================================================================
// Purpose: Efficiently store 3,265 quantized weights in FPGA Block RAM
// Memory Organization:
//   - W1: 3,200 weights (100 inputs x 32 neurons) 
//   - b1: 32 biases
//   - W2: 32 weights (32 inputs x 1 output)
//   - b2: 1 bias
// Total: 3,265 x 16-bit values = 6,530 bytes
// ============================================================================

`timescale 1ns / 1ps

module weight_memory #(
    parameter DATA_WIDTH = 16,
    parameter W1_SIZE = 3200,       // 100 x 32
    parameter B1_SIZE = 32,
    parameter W2_SIZE = 32,
    parameter B2_SIZE = 1,
    parameter TOTAL_SIZE = 3265
)(
    input wire clk,
    input wire [11:0] addr,         // 12-bit address (0-3264)
    output reg signed [DATA_WIDTH-1:0] data_out
);
    // Block RAM Declaration
    reg signed [DATA_WIDTH-1:0] memory [0:TOTAL_SIZE-1];
    
    initial begin
        $readmemh("nn_weights.hex", memory);  
    end
    
    // ========================================================================
    // Synchronous Read (single-cycle latency)
    // ========================================================================
    always @(posedge clk) begin
        if (addr < TOTAL_SIZE) begin
            data_out <= memory[addr];
        end else begin
            data_out <= 16'sd0;  // Safety: return 0 for invalid address
        end
    end

endmodule


// ============================================================================
// Weight Address Calculator
// ============================================================================
// Converts (layer, row, col) indices to linear memory address
// ============================================================================

module weight_address_calculator #(
    parameter W1_BASE = 0,          // W1 starts at address 0
    parameter B1_BASE = 3200,       // b1 starts at address 3200
    parameter W2_BASE = 3232,       // W2 starts at address 3232
    parameter B2_BASE = 3264        // b2 starts at address 3264
)(
    input wire [1:0] layer,         // 0=W1, 1=b1, 2=W2, 3=b2
    input wire [6:0] row_idx,       // 0-99 for W1, 0-31 for others
    input wire [5:0] col_idx,       // 0-31 for W1, unused for others
    output reg [11:0] addr
);

    always @(*) begin
        case (layer)
            2'd0: begin  // W1: 2D array (100 x 32)
                // Address = W1_BASE + (row * 32) + col
                addr = W1_BASE + (row_idx * 7'd32) + col_idx;
            end
            
            2'd1: begin  // b1: 1D array (32)
                addr = B1_BASE + row_idx;
            end
            
            2'd2: begin  // W2: 1D array (32)
                addr = W2_BASE + row_idx;
            end
            
            2'd3: begin  // b2: single value
                addr = B2_BASE;
            end
            
            default: addr = 12'd0;
        endcase
    end

endmodule


// ============================================================================
// Multiply-Accumulate (MAC) Unit
// ============================================================================
// Optimized for DSP48E1 slices (Xilinx) or equivalent
// Performs: acc = acc + (a * b)
// ============================================================================

module mac_unit #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,
    input wire enable,
    input wire clear,               // Clear accumulator
    input wire signed [DATA_WIDTH-1:0] a,
    input wire signed [DATA_WIDTH-1:0] b,
    output reg signed [ACC_WIDTH-1:0] acc
);

    // Multiplier output (uses DSP slice)
    reg signed [ACC_WIDTH-1:0] mult_result;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 0;
            mult_result <= 0;
        end else begin
            if (clear) begin
                acc <= 0;
            end else if (enable) begin
                // Multiply
                mult_result <= a * b;
                
                // Accumulate
                acc <= acc + mult_result;
            end
        end
    end

endmodule


// ============================================================================
// ReLU Activation Module
// ============================================================================
// Simple: output = max(0, input)
// ============================================================================

module relu #(
    parameter DATA_WIDTH = 16
)(
    input wire signed [DATA_WIDTH-1:0] data_in,
    output wire signed [DATA_WIDTH-1:0] data_out
);

    assign data_out = (data_in < 0) ? 16'sd0 : data_in;

endmodule


// ============================================================================
// Sigmoid Approximation Module (Piecewise Linear)
// ============================================================================
// Input: Q7.8 format (-128.0 to 127.99)
// Output: Q7.8 format (0.0 to 1.0, represented as 0 to 256)
// ============================================================================

module sigmoid_approx #(
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS = 8
)(
    input wire signed [DATA_WIDTH-1:0] x,
    output reg signed [DATA_WIDTH-1:0] y
);

    // Piecewise linear approximation with 5 segments
    // Segment boundaries at x = -4, -2, 0, 2, 4
    
    localparam signed [DATA_WIDTH-1:0] NEG4 = -16'sd1024;  // -4.0 in Q7.8
    localparam signed [DATA_WIDTH-1:0] NEG2 = -16'sd512;   // -2.0
    localparam signed [DATA_WIDTH-1:0] ZERO = 16'sd0;      // 0.0
    localparam signed [DATA_WIDTH-1:0] POS2 = 16'sd512;    // 2.0
    localparam signed [DATA_WIDTH-1:0] POS4 = 16'sd1024;   // 4.0
    
    always @(*) begin
        if (x <= NEG4) begin
            // Sigmoid(-4) ≈ 0.018
            y = 16'sd5;
        end else if (x <= NEG2) begin
            // Linear interpolation between -4 and -2
            // y = 0.018 + 0.1 * (x + 4) / 2
            y = 16'sd5 + ((x - NEG4) >>> 4);
        end else if (x <= ZERO) begin
            // Linear interpolation between -2 and 0
            // y = 0.119 + 0.25 * (x + 2) / 2
            y = 16'sd30 + ((x - NEG2) >>> 2);
        end else if (x <= POS2) begin
            // Linear interpolation between 0 and 2
            // y = 0.5 + 0.25 * x / 2
            y = 16'sd128 + (x >>> 2);
        end else if (x <= POS4) begin
            // Linear interpolation between 2 and 4
            // y = 0.881 + 0.1 * (x - 2) / 2
            y = 16'sd226 + ((x - POS2) >>> 4);
        end else begin
            // Sigmoid(4) ≈ 0.982
            y = 16'sd251;
        end
    end

endmodule


// ============================================================================
// Test Pattern Generator (for simulation/verification)
// ============================================================================

/* module test_pattern_generator #(
    parameter DATA_WIDTH = 16,
    parameter INPUT_SIZE = 100
)(
    input wire clk,
    input wire rst_n,
    input wire generate,
    output reg signed [DATA_WIDTH-1:0] test_input [0:INPUT_SIZE-1],
    output reg valid
);

    integer i;
    reg [7:0] counter;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 0;
            counter <= 0;
            for (i = 0; i < INPUT_SIZE; i = i + 1) begin
                test_input[i] <= 0;
            end
        end else if (generate) begin
            // Generate a simple test pattern (sine-wave approximation)
            for (i = 0; i < INPUT_SIZE; i = i + 1) begin
                // Simple pattern: alternating positive/negative values
                if (i < 50) begin
                    test_input[i] <= 16'sd100;  // 0.39 in Q7.8
                end else begin
                    test_input[i] <= -16'sd100; // -0.39
                end
            end
            valid <= 1;
        end else begin
            valid <= 0;
        end
    end

endmodule */
