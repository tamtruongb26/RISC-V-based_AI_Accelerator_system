`timescale 1ns / 1ps

module neuron_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic valid;
    logic clc_accumulator;
    logic accumulation_done;
    logic [15:0] inputs;
    logic [15:0] weights;
    logic [15:0] bias;
    logic bram_en;
    logic [9:0] bram_add;

    always #5 clk = ~clk;

    neuron dut (
        .pi_clk(clk),
        .pi_rst_n(rst_n),
        .pi_valid(valid),
        .pi_clc_accumulator(clc_accumulator),
        .pi_accumulation_done(accumulation_done),
        .pi_inputs(inputs),
        .pi_weights(weights),
        .pi_bias(bias),
        .po_BRAM_en(bram_en),
        .po_BRAM_add(bram_add)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $fatal(1, "%s", msg);
        end
    endtask

    initial begin
        $dumpfile("neuron_tb.vcd");
        $dumpvars(0, neuron_tb);

        valid = 1'b0;
        clc_accumulator = 1'b0;
        accumulation_done = 1'b0;
        inputs = 16'h0000;
        weights = 16'h0000;
        bias = 16'h0000;

        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        check(bram_en === 1'b0, "BRAM enable must stay low until accumulation_done");

        inputs <= 16'h0800;  // +1.0 in Q1.4.11
        weights <= 16'h0800; // +1.0 in Q1.4.11
        valid <= 1'b1;
        @(posedge clk);
        valid <= 1'b0;
        accumulation_done <= 1'b1;
        @(posedge clk);
        #1;
        accumulation_done <= 1'b0;
        check(bram_en === 1'b1, "BRAM enable must assert on accumulation_done");
        check(bram_add === 10'd32, "BRAM address for 1.0 MAC result mismatch");

        clc_accumulator <= 1'b1;
        @(posedge clk);
        clc_accumulator <= 1'b0;
        bias <= 16'h0800;
        accumulation_done <= 1'b1;
        @(posedge clk);
        #1;
        accumulation_done <= 1'b0;
        check(bram_add === 10'd32, "BRAM address for +1.0 bias mismatch after clear");

        $display("neuron_tb PASS");
        $finish;
    end

    initial begin
        repeat (100) @(posedge clk);
        $fatal(1, "neuron_tb timeout");
    end
endmodule
