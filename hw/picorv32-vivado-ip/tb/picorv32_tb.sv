`timescale 1ns / 1ps

module picorv32_tb;
    logic clk = 1'b0;
    logic resetn = 1'b0;
    logic trap;
    logic mem_valid;
    logic mem_instr;
    logic mem_ready;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_wstrb;
    logic [31:0] mem_rdata;
    logic mem_la_read;
    logic mem_la_write;
    logic [31:0] mem_la_addr;
    logic [31:0] mem_la_wdata;
    logic [3:0]  mem_la_wstrb;
    logic pcpi_valid;
    logic [31:0] pcpi_insn;
    logic [31:0] pcpi_rs1;
    logic [31:0] pcpi_rs2;
    logic [31:0] eoi;
    logic trace_valid;
    logic [35:0] trace_data;

    always #5 clk = ~clk;

    assign mem_ready = mem_valid;
    assign mem_rdata = 32'h0000_0013; // addi x0, x0, 0 (NOP)

    picorv32 #(
        .ENABLE_COUNTERS(0),
        .ENABLE_COUNTERS64(0),
        .REGS_INIT_ZERO(0),
        .PROGADDR_RESET(32'h0000_0000)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .trap(trap),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_la_read(mem_la_read),
        .mem_la_write(mem_la_write),
        .mem_la_addr(mem_la_addr),
        .mem_la_wdata(mem_la_wdata),
        .mem_la_wstrb(mem_la_wstrb),
        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'h0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(32'h0),
        .eoi(eoi),
        .trace_valid(trace_valid),
        .trace_data(trace_data)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $fatal(1, "%s", msg);
        end
    endtask

    initial begin
        int fetch_count;

        $dumpfile("picorv32_tb.vcd");
        $dumpvars(0, picorv32_tb);

        repeat (5) @(posedge clk);
        resetn <= 1'b1;

        fetch_count = 0;
        repeat (80) begin
            @(posedge clk);
            if (mem_valid && mem_ready && mem_instr) begin
                fetch_count++;
            end
            check(trap === 1'b0, "PicoRV32 trapped while executing NOPs");
        end

        check(fetch_count > 0, "PicoRV32 did not fetch instructions after reset");
        check(mem_wstrb === 4'b0000, "NOP smoke test must not perform writes");

        $display("picorv32_tb PASS fetch_count=%0d last_addr=%08x", fetch_count, mem_addr);
        $finish;
    end

    initial begin
        repeat (200) @(posedge clk);
        $fatal(1, "picorv32_tb timeout");
    end
endmodule
