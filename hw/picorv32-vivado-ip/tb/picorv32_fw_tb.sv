`timescale 1ns / 1ps

module picorv32_fw_tb;
    logic clk = 1'b0;
    logic resetn = 1'b0;

    // PicoRV32 signals
    logic trap;
    logic mem_valid;
    logic mem_instr;
    logic mem_ready;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_wstrb;
    logic [31:0] mem_rdata;
    logic trace_valid;
    logic [35:0] trace_data;

    // BRAM model (64KB, 65536 bytes)
    reg [7:0] bram [0:65535];

    always #5 clk = ~clk;

    // PicoRV32 instantiation
    picorv32 #(
        .ENABLE_COUNTERS(0),
        .ENABLE_COUNTERS64(0),
        .REGS_INIT_ZERO(1),
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
        .trace_valid(trace_valid),
        .trace_data(trace_data)
    );

    // Memory routing logic
    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
        end else begin
            mem_ready <= 1'b0; // Default

            if (mem_valid && !mem_ready) begin
                // BRAM Access: 0x00000000 to 0x0000FFFF (64KB)
                if (mem_addr >= 32'h00000000 && mem_addr < 32'h00010000) begin
                    mem_ready <= 1'b1;
                    if (mem_wstrb == 0) begin
                        mem_rdata <= {bram[mem_addr+3], bram[mem_addr+2], bram[mem_addr+1], bram[mem_addr]};
                    end else begin
                        if (mem_wstrb[0]) bram[mem_addr]   <= mem_wdata[7:0];
                        if (mem_wstrb[1]) bram[mem_addr+1] <= mem_wdata[15:8];
                        if (mem_wstrb[2]) bram[mem_addr+2] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) bram[mem_addr+3] <= mem_wdata[31:24];
                    end
                end
                // Mailbox or DDR write access interception (0x10000000+)
                else if (mem_addr >= 32'h10000000 && mem_addr < 32'h20000000) begin
                    mem_ready <= 1'b1;
                    if (mem_wstrb != 0) begin
                        $display("[%t] FIRMWARE WRITE to DDR: Addr=%08x, Data=%08x", $time, mem_addr, mem_wdata);
                        if (mem_addr == 32'h10000800) begin // RAAS_DDR_MAILBOX_OFFSET = 0x800
                            $display("[%t] >>> MAILBOX UPDATED: 0x%08x <<<", $time, mem_wdata);
                            if (mem_wdata == 32'hCAFEBABE) $display("     Status: STARTED");
                            if (mem_wdata == 32'hDEAD0001) begin $display("     Status: DMA_TIMEOUT"); $finish; end
                            if (mem_wdata == 32'hC0DEC0DE) begin $display("     Status: PASS"); $finish; end
                            if (mem_wdata == 32'hDEADBEEF) begin $display("     Status: FAIL"); $finish; end
                        end
                    end else begin
                        // Mock read from DDR
                        mem_rdata <= 32'h00000000;
                    end
                end
                // Accelerator access (0x40000000) or DMA access (0x40010000)
                else if (mem_addr >= 32'h40000000) begin
                    mem_ready <= 1'b1;
                    if (mem_wstrb != 0) begin
                        $display("[%t] FIRMWARE WRITE to PERIPH: Addr=%08x, Data=%08x", $time, mem_addr, mem_wdata);
                    end else begin
                        // Mock read (e.g., status is DONE for accelerator, IDLE for DMA)
                        if (mem_addr == 32'h40000010) mem_rdata <= 32'h00000002; // STATUS DONE
                        else if (mem_addr == 32'h40010004 || mem_addr == 32'h40010034) mem_rdata <= 32'h00000002; // DMASR IDLE
                        else mem_rdata <= 32'h00000000;
                    end
                end
                else begin
                    $display("[%t] ERROR: Unmapped address access: %08x", $time, mem_addr);
                    mem_ready <= 1'b1; // avoid hang
                end
            end
        end
    end

    initial begin
        $display("Loading firmware into BRAM...");
        // Use readmemh with hex formatted file
        $readmemh("/home/tam/Documents/RAAS/sw/picorv32/build/firmware.hex", bram);

        $dumpfile("picorv32_fw_tb.vcd");
        $dumpvars(0, picorv32_fw_tb);

        // Hold reset
        resetn = 1'b0;
        #100;
        
        // Release reset
        $display("[%t] Releasing PicoRV32 reset...", $time);
        resetn = 1'b1;

        // Run for a while
        #500000;
        $display("[%t] Timeout reached. Testbench finished.", $time);
        $finish;
    end

    always @(posedge clk) begin
        if (trace_valid) begin
            //$display("[%t] TRACE: PC=%08x, Instr=%08x", $time, trace_data[35:4], trace_data[31:0]);
            // The top 32 bits are PC? In PicoRV32 trace_data is usually {4'b0, pc}. Wait, it's 36 bits: {4'b..., 32'b...}.
            // Actually it is: {4'b mask, 32'b data}. For instructions, the data is the PC or instruction itself.
            // Let's just print mem_addr when fetching.
        end
        if (mem_valid && mem_instr && mem_ready) begin
            $display("[%t] FETCH: PC=%08x, Instr=%08x", $time, mem_addr, {bram[mem_addr+3], bram[mem_addr+2], bram[mem_addr+1], bram[mem_addr]});
        end
    end

    always @(posedge clk) begin
        if (trap) begin
            $display("[%t] PicoRV32 TRAP detected! Firmware crashed or halted.", $time);
            $finish;
        end
    end
endmodule
