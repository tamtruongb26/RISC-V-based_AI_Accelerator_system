`timescale 1ns / 1ps

module bram_tb;
    logic clk = 1'b0;
    logic ena;
    logic wea;
    logic [3:0] addra;
    logic [15:0] dia;
    logic [15:0] doa;
    logic enb;
    logic web;
    logic [3:0] addrb;
    logic [15:0] dib;
    logic [15:0] dob;

    always #5 clk = ~clk;

    bram #(
        .WADDR(4),
        .WDATA(16)
    ) dut (
        .pi_clka(clk),
        .pi_ena(ena),
        .pi_wea(wea),
        .pi_addra(addra),
        .pi_dia(dia),
        .po_doa(doa),
        .pi_clkb(clk),
        .pi_enb(enb),
        .pi_web(web),
        .pi_addrb(addrb),
        .pi_dib(dib),
        .po_dob(dob)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $fatal(1, "%s", msg);
        end
    endtask

    initial begin
        $dumpfile("bram_tb.vcd");
        $dumpvars(0, bram_tb);

        ena = 1'b0;
        wea = 1'b0;
        addra = '0;
        dia = '0;
        enb = 1'b0;
        web = 1'b0;
        addrb = '0;
        dib = '0;

        @(posedge clk);
        ena <= 1'b1;
        wea <= 1'b1;
        addra <= 4'd3;
        dia <= 16'h1234;
        enb <= 1'b1;
        web <= 1'b1;
        addrb <= 4'd4;
        dib <= 16'hABCD;
        @(posedge clk);
        #1;
        check(doa === 16'h1234, "port A write-first output mismatch");
        check(dob === 16'hABCD, "port B write-first output mismatch");

        wea <= 1'b0;
        web <= 1'b0;
        addra <= 4'd4;
        addrb <= 4'd3;
        @(posedge clk);
        #1;
        check(doa === 16'hABCD, "port A read mismatch");
        check(dob === 16'h1234, "port B read mismatch");

        $display("bram_tb PASS");
        $finish;
    end

    initial begin
        repeat (50) @(posedge clk);
        $fatal(1, "bram_tb timeout");
    end
endmodule
