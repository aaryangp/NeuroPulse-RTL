// ============================================================================
// ECG-ID Neural Network Inference Engine - PERFECT PIPELINE VERSION
// ============================================================================

`timescale 1ns / 1ps

module nn_inference_engine #(
    parameter INPUT_SIZE = 100,
    parameter HIDDEN_SIZE = 32,
    parameter OUTPUT_SIZE = 1,
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS = 8,
    parameter THRESHOLD = 16'sd160
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire signed [DATA_WIDTH-1:0] input_data [0:INPUT_SIZE-1],
    output reg valid,
    output reg signed [DATA_WIDTH-1:0] output_prob,
    output reg busy,
    output reg heartbeat_detected 
);

    // ========================================================================
    // State Machine States
    // ========================================================================
    localparam IDLE             = 3'd0;
    localparam LOAD_BIAS        = 3'd1;  
    localparam HIDDEN_MAC       = 3'd2;
    localparam HIDDEN_RELU      = 3'd3;
    localparam OUTPUT_MAC       = 3'd4;
    localparam LOAD_OUTPUT_BIAS = 3'd5;
    localparam SIGMOID          = 3'd6;
    localparam DONE             = 3'd7;

    reg [2:0] state, next_state;
    reg [6:0] input_idx;     
    reg [5:0] neuron_idx;    

    // ========================================================================
    // Internal Storage 
    // ========================================================================
    reg signed [DATA_WIDTH-1:0] hidden_z [0:HIDDEN_SIZE-1];  
    reg signed [DATA_WIDTH-1:0] hidden_a [0:HIDDEN_SIZE-1];  
    reg signed [31:0] output_z;                              
    
    reg signed [DATA_WIDTH-1:0] current_input;
    reg signed [DATA_WIDTH-1:0] current_weight;
    reg signed [DATA_WIDTH-1:0] current_bias;

    // ========================================================================
    // Instantiations
    // ========================================================================
    wire signed [DATA_WIDTH-1:0] weight_data;
    wire [11:0] weight_addr;
    reg [1:0] layer_select;

    weight_address_calculator addr_calc (
        .layer(layer_select),
        .row_idx(input_idx),
        .col_idx(neuron_idx),
        .addr(weight_addr)
    );

    weight_memory #(.DATA_WIDTH(DATA_WIDTH), .TOTAL_SIZE(3265)) weight_mem (
        .clk(clk),
        .addr(weight_addr),
        .data_out(weight_data)
    );

    wire signed [DATA_WIDTH-1:0] mac_a;
    wire signed [DATA_WIDTH-1:0] mac_b;
    reg mac_enable;
    reg mac_clear;
    wire signed [31:0] mac_result;

    mac_unit #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(32)) mac (
        .clk(clk),
        .rst_n(rst_n),
        .enable(mac_enable),
        .clear(mac_clear),
        .a(mac_a),
        .b(mac_b),
        .acc(mac_result)
    );

    assign mac_a = current_input;
    assign mac_b = current_weight;

    wire signed [DATA_WIDTH-1:0] relu_in [0:HIDDEN_SIZE-1];
    wire signed [DATA_WIDTH-1:0] relu_out [0:HIDDEN_SIZE-1];

    genvar i;
    generate
        for (i = 0; i < HIDDEN_SIZE; i = i + 1) begin : relu_array
            relu #(.DATA_WIDTH(DATA_WIDTH)) relu_inst (
                .data_in(relu_in[i]),    
                .data_out(relu_out[i])   
            );
        end
    endgenerate

    generate
        for (i = 0; i < HIDDEN_SIZE; i = i + 1) begin : relu_connections
            assign relu_in[i] = hidden_z[i];
        end
    endgenerate

    wire signed [DATA_WIDTH-1:0] sigmoid_in;
    wire signed [DATA_WIDTH-1:0] sigmoid_out;

    sigmoid_approx #(.DATA_WIDTH(DATA_WIDTH), .FRAC_BITS(FRAC_BITS)) sigmoid (
        .x(sigmoid_in),
        .y(sigmoid_out)
    );

    assign sigmoid_in = output_z[DATA_WIDTH-1:0];

    // ========================================================================
    // Sequential State Machine & Next State Logic
    // ========================================================================
    always @(*) begin
        case (state)
            LOAD_BIAS:        layer_select = 2'd1;  
            HIDDEN_MAC:       layer_select = 2'd0;  
            OUTPUT_MAC:       layer_select = 2'd2;  
            LOAD_OUTPUT_BIAS: layer_select = 2'd3;  
            SIGMOID:          layer_select = 2'd3;  
            default:          layer_select = 2'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (start) next_state = LOAD_BIAS;
            end
            LOAD_BIAS: begin
                if (input_idx == 1) next_state = HIDDEN_MAC;
            end
            HIDDEN_MAC: begin
                if (input_idx == INPUT_SIZE + 2) begin
                    if (neuron_idx == HIDDEN_SIZE-1) next_state = HIDDEN_RELU;
                    else                             next_state = LOAD_BIAS; 
                end
            end
            HIDDEN_RELU: begin
                next_state = OUTPUT_MAC;
            end
            OUTPUT_MAC: begin
                if (neuron_idx == HIDDEN_SIZE + 2) next_state = LOAD_OUTPUT_BIAS;
            end
            LOAD_OUTPUT_BIAS: begin
                if (input_idx == 1) next_state = SIGMOID;
            end 
            SIGMOID: begin
                if (input_idx == 1) next_state = DONE;
            end
            DONE: begin
                next_state = IDLE;
            end
        endcase
    end

    // ========================================================================
    // Datapath: Main Processing Logic
    // ========================================================================
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_idx <= 0;
            neuron_idx <= 0;
            valid <= 0;
            busy <= 0;
            output_prob <= 0;
            mac_enable <= 0;
            mac_clear <= 0;
            current_input <= 0;
            current_weight <= 0;
            current_bias <= 0;
            output_z <= 0;
            heartbeat_detected <= 0 ;

            for (j = 0; j < HIDDEN_SIZE; j = j + 1) begin
                hidden_z[j] <= 0;
                hidden_a[j] <= 0;
            end
        end else begin
            // Defaults
            mac_enable <= 0;
            mac_clear <= 0;
            valid <= 0;

            case (state)
                IDLE: begin
                    busy <= 0;
                    input_idx <= 0;
                    neuron_idx <= 0;
                    if (start) busy <= 1;
                end

                LOAD_BIAS: begin
                    if (input_idx == 0) begin
                        input_idx <= 1; // Wait 1 cycle for memory fetch
                    end else begin
                        current_bias <= weight_data;  
                        mac_clear <= 1;
                        input_idx <= 0;
                    end
                end

                HIDDEN_MAC: begin
                    // 1. Fetch exactly 1 cycle behind the address to align data
                    if (input_idx > 0 && input_idx <= INPUT_SIZE) begin
                        current_input  <= input_data[input_idx - 1];
                        current_weight <= weight_data; 
                    end
                    
                    // 2. Keep MAC active for 1 extra cycle to finish multiplication
                    mac_enable <= (input_idx > 0 && input_idx <= INPUT_SIZE + 1);
                    
                    // 3. Complete the flush on cycle 102
                    if (input_idx == INPUT_SIZE + 2) begin
                        hidden_z[neuron_idx] <= (mac_result >>> FRAC_BITS) + current_bias;
                        mac_clear <= 1;
                        input_idx <= 0;
                        if (neuron_idx != HIDDEN_SIZE - 1) begin
                            neuron_idx <= neuron_idx + 1;
                        end
                    end else begin
                        input_idx <= input_idx + 1;
                    end
                end

                HIDDEN_RELU: begin
                    for (j = 0; j < HIDDEN_SIZE; j = j + 1) begin
                        hidden_a[j] <= relu_out[j];
                    end
                    neuron_idx <= 0;
                    mac_clear <= 1;
                end

                OUTPUT_MAC: begin
                    if (neuron_idx > 0 && neuron_idx <= HIDDEN_SIZE) begin
                        current_input  <= hidden_a[neuron_idx - 1];
                        current_weight <= weight_data;
                    end
                    
                    mac_enable <= (neuron_idx > 0 && neuron_idx <= HIDDEN_SIZE + 1);
                    
                    if (neuron_idx == HIDDEN_SIZE + 2) begin
                        output_z <= mac_result >>> FRAC_BITS;
                        neuron_idx <= 0;
                        mac_clear <= 1;
                    end else begin
                        neuron_idx <= neuron_idx + 1;
                    end
                end
                 
                LOAD_OUTPUT_BIAS: begin
                    if (input_idx == 0) begin
                        input_idx <= 1;
                    end else begin
                        current_bias <= weight_data;   
                        input_idx <= 0;
                    end
                end

                SIGMOID: begin
                    if (input_idx == 0) begin
                        output_z <= output_z + current_bias;
                        input_idx <= 1;
                    end else begin
                        output_prob <= sigmoid_out;
                        input_idx <= 0;
                    end
                end

                DONE: begin
                    valid <= 1;
                    busy <= 0;

                    if (output_prob > THRESHOLD) begin
                        heartbeat_detected <= 1'b1;
                    end else begin
                        heartbeat_detected <= 1'b0;
                    end
                end
            
            endcase
        end
    end
endmodule


// ============================================================================
// ALL SUPPORTING MODULES
// ============================================================================

module weight_address_calculator #(
    parameter W1_BASE = 0,
    parameter B1_BASE = 3200,
    parameter W2_BASE = 3232,
    parameter B2_BASE = 3264
)(
    input wire [1:0] layer,
    input wire [6:0] row_idx,
    input wire [5:0] col_idx,
    output reg [11:0] addr
);
    always @(*) begin
        case (layer)
            2'd0: addr = W1_BASE + (row_idx << 5) + col_idx; 
            2'd1: addr = B1_BASE + col_idx; 
            2'd2: addr = W2_BASE + col_idx; 
            2'd3: addr = B2_BASE;
            default: addr = 12'd0;
        endcase
    end
endmodule

module weight_memory #(
    parameter DATA_WIDTH = 16,
    parameter TOTAL_SIZE = 3265
)(
    input wire clk,
    input wire [11:0] addr,
    output reg signed [DATA_WIDTH-1:0] data_out
);
    reg signed [DATA_WIDTH-1:0] memory [0:TOTAL_SIZE-1];
    
    initial begin
        $readmemh("nn_weights.hex", memory);  
    end
    //synchronous ROM 
    always @(posedge clk) begin
        if (addr < TOTAL_SIZE) begin
            data_out <= memory[addr];
        end else begin
            data_out <= 16'sd0;
        end
    end
endmodule

module mac_unit #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,
    input wire enable,
    input wire clear,
    input wire signed [DATA_WIDTH-1:0] a,
    input wire signed [DATA_WIDTH-1:0] b,
    output reg signed [ACC_WIDTH-1:0] acc
);
    reg signed [ACC_WIDTH-1:0] mult_result;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 0;
            mult_result <= 0;
        end else begin
            if (clear) begin
                acc <= 0;
                mult_result <= 0;  
            end else if (enable) begin
                mult_result <= a * b; //2-stage pipelining 
                acc <= acc + mult_result;
            end
        end
    end
endmodule

module relu #(
    parameter DATA_WIDTH = 16
)(
    input wire signed [DATA_WIDTH-1:0] data_in,
    output wire signed [DATA_WIDTH-1:0] data_out
);
    assign data_out = (data_in < 0) ? 16'sd0 : data_in;
endmodule

module sigmoid_approx #(
    parameter DATA_WIDTH = 16,
    parameter FRAC_BITS = 8
)(
    input wire signed [DATA_WIDTH-1:0] x,
    output reg signed [DATA_WIDTH-1:0] y
);
    localparam signed [DATA_WIDTH-1:0] NEG4 = -16'sd1024;
    localparam signed [DATA_WIDTH-1:0] NEG2 = -16'sd512;
    localparam signed [DATA_WIDTH-1:0] ZERO = 16'sd0;
    localparam signed [DATA_WIDTH-1:0] POS2 = 16'sd512;
    localparam signed [DATA_WIDTH-1:0] POS4 = 16'sd1024;
    
    always @(*) begin
        if (x <= NEG4) begin
            y = 16'sd5;
        end else if (x <= NEG2) begin
            y = 16'sd5 + ((x - NEG4) >>> 4);
        end else if (x <= ZERO) begin
            y = 16'sd30 + ((x - NEG2) >>> 2);
        end else if (x <= POS2) begin
            y = 16'sd128 + (x >>> 2);
        end else if (x <= POS4) begin
            y = 16'sd226 + ((x - POS2) >>> 4);
        end else begin
            y = 16'sd251;
        end
    end
endmodule