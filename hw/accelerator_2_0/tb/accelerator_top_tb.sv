`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: accelerator_top_tb — end-to-end integration TB cho accelerator
//
// Kịch bản: hw/accelerator_2_0/tb/accelerator_top_tb_scenarios.md
//
// Drive 3 AXI interface qua TB-written drivers (no Vivado VIP):
//   - axi_lite_write/read   (config + status)
//   - axis_push             (data load qua AXIS slave)
//   - always-tready capture (output từ AXIS master)
//
// 4 case:
//   1. Sanity 2x2x2 bypass (hardcoded)
//   2. 3 act mode trên cùng input 4x4x4
//   3. Sweep 50 random tile (bypass)
//   4. Back-to-back 2 tile (no DUT reset giữa)
//
// Pass: "=== ALL ACCELERATOR TOP TESTS PASSED ===".
//////////////////////////////////////////////////////////////////////////////////

module accelerator_top_tb;

    // -------- Parameters --------
    localparam integer SA_N       = 8;
    localparam integer DW         = 16;
    localparam integer AW         = 40;
    localparam integer CLK_PERIOD = 10;       // 100 MHz
    localparam string  DATA_DIR   = "/home/tam/Documents/RAAS/hw/accelerator_2_0/tb/data/";

    // -------- Clock & reset --------
    reg clk = 1'b0;
    reg rst_n;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------- AXI-Lite signals --------
    reg  [4:0]  s00_axi_awaddr;
    reg  [2:0]  s00_axi_awprot;
    reg         s00_axi_awvalid;
    wire        s00_axi_awready;
    reg  [31:0] s00_axi_wdata;
    reg  [3:0]  s00_axi_wstrb;
    reg         s00_axi_wvalid;
    wire        s00_axi_wready;
    wire [1:0]  s00_axi_bresp;
    wire        s00_axi_bvalid;
    reg         s00_axi_bready;
    reg  [4:0]  s00_axi_araddr;
    reg  [2:0]  s00_axi_arprot;
    reg         s00_axi_arvalid;
    wire        s00_axi_arready;
    wire [31:0] s00_axi_rdata;
    wire [1:0]  s00_axi_rresp;
    wire        s00_axi_rvalid;
    reg         s00_axi_rready;

    // -------- AXIS slave signals (TB drives, DUT receives) --------
    reg         s00_axis_tvalid;
    reg  [31:0] s00_axis_tdata;
    reg  [3:0]  s00_axis_tstrb;
    reg         s00_axis_tlast;
    wire        s00_axis_tready;

    // -------- AXIS master signals (DUT drives, TB captures) --------
    wire        m00_axis_tvalid;
    wire [31:0] m00_axis_tdata;
    wire [3:0]  m00_axis_tstrb;
    wire        m00_axis_tlast;
    reg         m00_axis_tready;

    // -------- DUT --------
    accelerator dut (
        .s00_axi_aclk    (clk),
        .s00_axi_aresetn (rst_n),
        .s00_axi_awaddr  (s00_axi_awaddr),
        .s00_axi_awprot  (s00_axi_awprot),
        .s00_axi_awvalid (s00_axi_awvalid),
        .s00_axi_awready (s00_axi_awready),
        .s00_axi_wdata   (s00_axi_wdata),
        .s00_axi_wstrb   (s00_axi_wstrb),
        .s00_axi_wvalid  (s00_axi_wvalid),
        .s00_axi_wready  (s00_axi_wready),
        .s00_axi_bresp   (s00_axi_bresp),
        .s00_axi_bvalid  (s00_axi_bvalid),
        .s00_axi_bready  (s00_axi_bready),
        .s00_axi_araddr  (s00_axi_araddr),
        .s00_axi_arprot  (s00_axi_arprot),
        .s00_axi_arvalid (s00_axi_arvalid),
        .s00_axi_arready (s00_axi_arready),
        .s00_axi_rdata   (s00_axi_rdata),
        .s00_axi_rresp   (s00_axi_rresp),
        .s00_axi_rvalid  (s00_axi_rvalid),
        .s00_axi_rready  (s00_axi_rready),
        .s00_axis_aclk    (clk),
        .s00_axis_aresetn (rst_n),
        .s00_axis_tvalid  (s00_axis_tvalid),
        .s00_axis_tdata   (s00_axis_tdata),
        .s00_axis_tstrb   (s00_axis_tstrb),
        .s00_axis_tlast   (s00_axis_tlast),
        .s00_axis_tready  (s00_axis_tready),
        .m00_axis_aclk    (clk),
        .m00_axis_aresetn (rst_n),
        .m00_axis_tvalid  (m00_axis_tvalid),
        .m00_axis_tdata   (m00_axis_tdata),
        .m00_axis_tstrb   (m00_axis_tstrb),
        .m00_axis_tlast   (m00_axis_tlast),
        .m00_axis_tready  (m00_axis_tready)
    );

    // -------- Capture buffer (always tready, latch words on handshake) --------
    reg  [31:0] capture_buf [0:255];
    integer     capture_count;
    reg         capture_enable;
    reg         capture_reset;       // sync reset cho counter (giữa tile, no DUT reset)

    always @(posedge clk) begin
        if (!rst_n || capture_reset) begin
            capture_count <= 0;
        end else if (capture_enable && m00_axis_tvalid && m00_axis_tready) begin
            capture_buf[capture_count] <= m00_axis_tdata;
            capture_count <= capture_count + 1;
        end
    end

    // -------- Test buffers (loaded từ hex files) --------
    reg [DW-1:0] A_mem    [0:63];     // M*K elements (max 64)
    reg [DW-1:0] W_mem    [0:63];     // SA_N*SA_N padded
    reg [DW-1:0] bias_mem [0:7];      // SA_N elements
    reg [DW-1:0] C_mem    [0:63];     // M*N expected

    // -------- Counters --------
    integer total_tiles  = 0;
    integer total_checks = 0;
    integer errs         = 0;

    // ─────────────────────────────────────────────────────────────
    // AXI-Lite master driver
    // ─────────────────────────────────────────────────────────────
    task automatic axi_lite_write(input [4:0] addr, input [31:0] data);
        @(negedge clk);
        s00_axi_awaddr  = addr;
        s00_axi_awprot  = 3'b0;
        s00_axi_awvalid = 1'b1;
        s00_axi_wdata   = data;
        s00_axi_wstrb   = 4'hF;
        s00_axi_wvalid  = 1'b1;
        s00_axi_bready  = 1'b1;
        // Wait both AWREADY and WREADY
        do @(posedge clk);
        while (!(s00_axi_awready && s00_axi_wready));
        @(negedge clk);
        s00_axi_awvalid = 1'b0;
        s00_axi_wvalid  = 1'b0;
        // Wait BVALID then ack
        do @(posedge clk);
        while (!s00_axi_bvalid);
        @(negedge clk);
        s00_axi_bready  = 1'b0;
    endtask

    task automatic axi_lite_read(input [4:0] addr, output [31:0] data);
        @(negedge clk);
        s00_axi_araddr  = addr;
        s00_axi_arprot  = 3'b0;
        s00_axi_arvalid = 1'b1;
        s00_axi_rready  = 1'b1;
        do @(posedge clk);
        while (!s00_axi_arready);
        @(negedge clk);
        s00_axi_arvalid = 1'b0;
        do @(posedge clk);
        while (!s00_axi_rvalid);
        data = s00_axi_rdata;
        @(negedge clk);
        s00_axi_rready  = 1'b0;
    endtask

    // ─────────────────────────────────────────────────────────────
    // AXIS slave driver (push 1 word)
    // ─────────────────────────────────────────────────────────────
    task automatic axis_push(input [31:0] word);
        @(negedge clk);
        s00_axis_tvalid = 1'b1;
        s00_axis_tdata  = word;
        s00_axis_tstrb  = 4'hF;
        s00_axis_tlast  = 1'b0;
        do @(posedge clk);
        while (!s00_axis_tready);
        @(negedge clk);
        s00_axis_tvalid = 1'b0;
    endtask

    // ─────────────────────────────────────────────────────────────
    // Helper: load tile data từ hex files
    // ─────────────────────────────────────────────────────────────
    task automatic load_case(input string name);
        integer i;
        // Clear buffers
        for (i = 0; i < 64; i = i + 1) A_mem[i] = 16'h0;
        for (i = 0; i < 64; i = i + 1) W_mem[i] = 16'h0;
        for (i = 0; i < 8;  i = i + 1) bias_mem[i] = 16'h0;
        for (i = 0; i < 64; i = i + 1) C_mem[i] = 16'h0;
        $readmemh({DATA_DIR, name, "_A.hex"},    A_mem);
        $readmemh({DATA_DIR, name, "_W.hex"},    W_mem);
        $readmemh({DATA_DIR, name, "_bias.hex"}, bias_mem);
        $readmemh({DATA_DIR, name, "_C.hex"},    C_mem);
    endtask

    // ─────────────────────────────────────────────────────────────
    // Helper: drive 1 tile (load → config → stream → capture → compare)
    // ─────────────────────────────────────────────────────────────
    task automatic run_one_tile(input string name,
                                input integer M_used,
                                input integer K_used,
                                input integer N_used,
                                input integer act_mode);
        integer r, c, p, m, n;
        integer K_pairs, N_pairs;
        integer expected_words;
        integer local_errs;
        reg [15:0] elem_lo, elem_hi;
        reg [15:0] cap_lo, cap_hi;
        reg [15:0] exp_v, got_v;
        reg [31:0] status;
        integer    timeout;

        load_case(name);

        // ── Reset capture for this tile (proper sync reset) ──
        @(negedge clk);
        capture_enable = 1'b0;
        capture_reset  = 1'b1;
        @(posedge clk);
        @(negedge clk);
        capture_reset  = 1'b0;
        capture_enable = 1'b1;

        // ── 1. AXI-Lite config ──
        axi_lite_write(5'h00, M_used);
        axi_lite_write(5'h04, K_used);
        axi_lite_write(5'h08, N_used);

        // ── 2. START + ACT_MODE (CONTROL = {act[1:0], 1'b1}) ──
        axi_lite_write(5'h0C, {29'd0, act_mode[1:0], 1'b1});

        // ── 3. Drive AXIS slave: weights 32 word + bias 4 word + input ──
        // Weights: 8 rows × 4 word/row, even/odd packing
        for (r = 0; r < SA_N; r = r + 1) begin
            for (p = 0; p < 4; p = p + 1) begin
                axis_push({W_mem[r*8 + p*2 + 1], W_mem[r*8 + p*2]});
            end
        end
        // Bias: 4 word
        for (p = 0; p < 4; p = p + 1) begin
            axis_push({bias_mem[p*2 + 1], bias_mem[p*2]});
        end
        // Input: M × ⌈K/2⌉ word
        K_pairs = (K_used + 1) >> 1;
        for (m = 0; m < M_used; m = m + 1) begin
            for (p = 0; p < K_pairs; p = p + 1) begin
                elem_lo = A_mem[m*K_used + 2*p];
                elem_hi = (2*p + 1 < K_used) ? A_mem[m*K_used + 2*p + 1] : 16'h0;
                axis_push({elem_hi, elem_lo});
            end
        end

        // ── 4. Wait DONE bit in STATUS ──
        timeout = 0;
        status  = 32'h0;
        while (!status[1] && timeout < 2000) begin
            axi_lite_read(5'h10, status);
            timeout = timeout + 1;
        end
        if (timeout >= 2000) begin
            $display("[FAIL] %s: TIMEOUT waiting DONE", name);
            errs = errs + 1;
            return;
        end

        // Stop capture
        @(posedge clk);
        capture_enable = 1'b0;

        // ── 5. Verify capture count ──
        N_pairs = (N_used + 1) >> 1;
        expected_words = M_used * N_pairs;
        if (capture_count !== expected_words) begin
            $display("[FAIL] %s: captured %0d words, expected %0d",
                     name, capture_count, expected_words);
            errs = errs + 1;
            return;
        end

        // ── 6. Compare unpacked output cells với C_mem ──
        local_errs = 0;
        for (m = 0; m < M_used; m = m + 1) begin
            for (p = 0; p < N_pairs; p = p + 1) begin
                cap_lo = capture_buf[m*N_pairs + p][15:0];
                cap_hi = capture_buf[m*N_pairs + p][31:16];

                // Even index 2p
                if (2*p < N_used) begin
                    exp_v = C_mem[m*N_used + 2*p];
                    got_v = cap_lo;
                    if (got_v !== exp_v) begin
                        if (local_errs < 3)
                            $display("[FAIL] %s C[%0d][%0d]: got=0x%h (%0d) exp=0x%h (%0d)",
                                     name, m, 2*p, got_v, $signed(got_v),
                                     exp_v, $signed(exp_v));
                        local_errs = local_errs + 1;
                    end
                    total_checks = total_checks + 1;
                end

                // Odd index 2p+1
                if (2*p + 1 < N_used) begin
                    exp_v = C_mem[m*N_used + 2*p + 1];
                    got_v = cap_hi;
                    if (got_v !== exp_v) begin
                        if (local_errs < 3)
                            $display("[FAIL] %s C[%0d][%0d]: got=0x%h (%0d) exp=0x%h (%0d)",
                                     name, m, 2*p+1, got_v, $signed(got_v),
                                     exp_v, $signed(exp_v));
                        local_errs = local_errs + 1;
                    end
                    total_checks = total_checks + 1;
                end
            end
        end

        if (local_errs == 0) begin
            $display("[ OK ] %s (M=%0d K=%0d N=%0d act=%0d)",
                     name, M_used, K_used, N_used, act_mode);
        end else begin
            $display("[FAIL] %s: %0d cells mismatch", name, local_errs);
        end
        errs = errs + local_errs;
        total_tiles = total_tiles + 1;
    endtask

    // ─────────────────────────────────────────────────────────────
    // DUT reset (between tiles)
    // ─────────────────────────────────────────────────────────────
    task automatic reset_dut();
        @(negedge clk);
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // ─────────────────────────────────────────────────────────────
    // Main stimulus
    // ─────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("accelerator_top_tb.vcd");
        $dumpvars(0, accelerator_top_tb);

        // Init signals
        rst_n           = 1'b0;
        s00_axi_awaddr  = 5'h0;  s00_axi_awprot  = 3'b0;  s00_axi_awvalid = 1'b0;
        s00_axi_wdata   = 32'h0; s00_axi_wstrb   = 4'h0;  s00_axi_wvalid  = 1'b0;
        s00_axi_bready  = 1'b0;
        s00_axi_araddr  = 5'h0;  s00_axi_arprot  = 3'b0;  s00_axi_arvalid = 1'b0;
        s00_axi_rready  = 1'b0;
        s00_axis_tvalid = 1'b0;  s00_axis_tdata  = 32'h0;
        s00_axis_tstrb  = 4'h0;  s00_axis_tlast  = 1'b0;
        m00_axis_tready = 1'b1;          // always ready, no backpressure
        capture_enable  = 1'b0;
        capture_reset   = 1'b0;

        // Reset
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ─────────── Case 1: Sanity 2x2x2 bypass ───────────
        $display("");
        $display("==== Case 1: Sanity 2x2x2 bypass ====");
        run_one_tile("top_case1", 2, 2, 2, 0);

        // ─────────── Case 2: 3 act mode trên cùng 4x4x4 ───────────
        $display("");
        $display("==== Case 2: 3 act mode (4x4x4) ====");
        reset_dut();
        run_one_tile("top_case2_bypass",  4, 4, 4, 0);
        reset_dut();
        run_one_tile("top_case2_relu",    4, 4, 4, 1);
        reset_dut();
        run_one_tile("top_case2_sigmoid", 4, 4, 4, 2);

        // ─────────── Case 3: Sweep 50 random tile ───────────
        $display("");
        $display("==== Case 3: Sweep 50 random tile ====");
        run_sweep_50();

        // ─────────── Case 4: Back-to-back 2 tile (no reset giữa) ───────────
        $display("");
        $display("==== Case 4: Back-to-back 2 tile (no reset giữa) ====");
        reset_dut();
        run_one_tile("top_case4a", 8, 8, 8, 0);
        // KHÔNG reset → verify tile B vẫn đúng
        run_one_tile("top_case4b", 8, 8, 8, 0);

        // ─────────── Summary ───────────
        $display("");
        $display("Total tiles run:   %0d", total_tiles);
        $display("Total cell checks: %0d", total_checks);
        if (errs == 0)
            $display("=== ALL ACCELERATOR TOP TESTS PASSED ===");
        else
            $display("=== %0d ACCELERATOR TOP TEST FAILURES ===", errs);
        $finish;
    end

    // ─────────────────────────────────────────────────────────────
    // Sweep helper (50 tile từ manifest hardcoded)
    // ─────────────────────────────────────────────────────────────
    // Manifest format khớp tools/gen_top_sweep.py output (seed=42).
    task automatic run_sweep_50();
        integer Ms [0:49];
        integer Ks [0:49];
        integer Ns [0:49];
        string  name;
        integer i;

        // Manifest copy từ sweep_manifest.txt (seed=42)
        Ms = '{1,7,6,4,4,7,1,6,2,1, 5,8,6,7,6,7,5,2,7,4, 5,3,2,8,7,6,4,7,5,4,
               4,2,1,5,8,1,7,7,3,6, 2,7,6,3,1,8,4,8,6,7};
        Ks = '{7,2,3,4,4,1,5,2,6,6, 8,6,3,8,4,3,8,3,1,4, 7,2,4,2,6,4,3,2,5,6,
               8,4,2,7,6,6,1,3,7,7, 4,7,7,4,8,3,2,6,6,2};
        Ns = '{7,2,7,1,7,7,7,6,4,6, 3,7,5,4,5,5,1,2,2,1, 4,6,6,4,7,5,1,7,5,6,
               5,5,1,5,7,3,5,1,3,4, 8,2,3,4,8,7,1,2,7,1};

        for (i = 0; i < 50; i = i + 1) begin
            name = $sformatf("sweep_%02d", i);
            reset_dut();
            run_one_tile(name, Ms[i], Ks[i], Ns[i], 0);
        end
    endtask

    // -------- Timeout watchdog --------
    initial begin
        #2000000;       // 2 ms
        $display("[TIMEOUT] simulation exceeded 2 ms");
        $finish;
    end

endmodule
