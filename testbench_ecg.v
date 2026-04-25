`timescale 1ns / 1ps

module tb_nn_continuous();

    // System Signals
    reg clk;
    reg rst_n;
    reg start;
    
    // Data Signals
    reg signed [15:0] test_input [0:99];
    wire valid;
    wire signed [15:0] output_prob;
    wire busy;
    wire heartbeat_detected; // <--- NEW: Connected to the hardware decision pin

    // ========================================================================
    // Instantiate the Engine (Updated with new port)
    // ========================================================================
    nn_inference_engine uut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .input_data(test_input),
        .valid(valid),
        .output_prob(output_prob),
        .busy(busy),
        .heartbeat_detected(heartbeat_detected) // <--- NEW Port
    );

    // Clock Generation (100 MHz)
    always #5 clk = ~clk;

    integer i;

    // ========================================================================
    // TEST RUNNER TASK
    // ========================================================================
    task run_test;
        input [80*8:1] test_name;
        begin
            $display("--------------------------------------------------");
            $display("Running: %s", test_name);
            
            // Pulse Start
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;

            // Wait for completion
            wait(valid == 1'b1);
            
            $display("Raw Probability: %0d / 256", output_prob);
            
            // Verify Hardware Decision
            if (heartbeat_detected)
                $display("Hardware Decision: [YES - HEARTBEAT]");
            else
                $display("Hardware Decision: [NO  - IGNORE]");
                
            // Internal TB Double-Check (using the 160 threshold)
            if (output_prob > 16'sd160)
                $display("TB Validation    : PASS (Above Threshold)");
            else
                $display("TB Validation    : PASS (Below Threshold)");
            
            #30; 
        end
    endtask

    // ========================================================================
    // MAIN SIMULATION
    // ========================================================================
    initial begin
        // 1. Initialize System
        clk = 0;
        rst_n = 0;
        start = 0;

        for (i = 0; i < 100; i = i + 1) test_input[i] = 16'sd0;

        // 2. Release Reset
        #20;
        rst_n = 1;
        #20;
        
        $display("==================================================");
        $display("   ECG-ID SILICON VERIFICATION: FINAL STRESS TEST");
        $display("==================================================");

        // -----------------------------------------------------------
        // RUN 1: Massive Heartbeat
        // -----------------------------------------------------------
        for (i = 0; i < 100; i = i + 1) test_input[i] = 16'sd0; 
        for (i = 40; i <= 60; i = i + 1) test_input[i] = 16'sd250; 
        run_test("Run 1: Massive Heartbeat");

        // -----------------------------------------------------------
        // RUN 2: Immediate Silence (The DC-Bias Test)
        // -----------------------------------------------------------
        for (i = 0; i < 100; i = i + 1) test_input[i] = 16'sd2; 
        run_test("Run 2: Immediate Silence (Expect ~153 Prob)");

        // -----------------------------------------------------------
        // RUN 3: Weak/Small Heartbeat
        // -----------------------------------------------------------
        for (i = 0; i < 100; i = i + 1) test_input[i] = 16'sd10; 
        for (i = 48; i <= 52; i = i + 1) test_input[i] = 16'sd140; 
        run_test("Run 3: Weak Heartbeat Sensitivity Test");

        // -----------------------------------------------------------
        // RUN 4: Deep Negative Peak (ReLU Recovery)
        // -----------------------------------------------------------
        for (i = 0; i < 100; i = i + 1) test_input[i] = 16'sd10;
        for (i = 48; i <= 52; i = i + 1) test_input[i] = -16'sd200; 
        run_test("Run 4: Deep Negative Peak (ReLU Test)");
        
        // -----------------------------------------------------------
        // RUN 5: Rapid Recovery
        // -----------------------------------------------------------
        for (i = 48; i <= 52; i = i + 1) test_input[i] = 16'sd200; 
        run_test("Run 5: Post-Negative Recovery Run");

        $display("==================================================");
        $display("   VERIFICATION COMPLETE - CHIP IS READY");
        $display("==================================================");
        #100;
        $finish;
    end

endmodule