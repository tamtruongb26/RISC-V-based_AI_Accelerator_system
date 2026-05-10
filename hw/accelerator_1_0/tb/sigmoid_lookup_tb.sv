`timescale 1ns / 1ps

module sigmoid_lookup_tb;
    logic clk = 1'b0;
    logic ena;
    logic [9:0] addra;
    logic [9:0] doa;
    logic enb;
    logic [9:0] addrb;
    logic [9:0] dob;

    always #5 clk = ~clk;

    sigmoid_lookup dut (
        .pi_clk(clk),
        .pi_ena(ena),
        .pi_addra(addra),
        .po_doa(doa),
        .pi_enb(enb),
        .pi_addrb(addrb),
        .po_dob(dob)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $fatal(1, "%s", msg);
        end
    endtask

    initial begin
        $dumpfile("sigmoid_lookup_tb.vcd");
        $dumpvars(0, sigmoid_lookup_tb);

        ena = 1'b1;
        enb = 1'b1;
        addra = 10'd0;
        addrb = 10'd512;
        @(posedge clk);
        #1;
        check(doa === 10'd256, "sigmoid LUT address 0 mismatch");
        check(dob === 10'd0, "sigmoid LUT address 512 mismatch");

        addra = 10'd16;
        addrb = 10'd1023;
        @(posedge clk);
        #1;
        check(doa === 10'd319, "sigmoid LUT address 16 mismatch");
        check(dob === 10'd252, "sigmoid LUT address 1023 mismatch");

        $display("sigmoid_lookup_tb PASS");
        $finish;
    end

    initial begin
        repeat (50) @(posedge clk);
        $fatal(1, "sigmoid_lookup_tb timeout");
    end
endmodule
