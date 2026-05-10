`timescale 1ns / 1ps

module sw_reset_slave_lite_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic po_sw_rstn;

    logic [3:0]  awaddr;
    logic [2:0]  awprot;
    logic        awvalid;
    logic        awready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid;
    logic        wready;
    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;
    logic [3:0]  araddr;
    logic [2:0]  arprot;
    logic        arvalid;
    logic        arready;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready;

    always #5 clk = ~clk;

    sw_reset_slave_lite_v1_0_S00_AXI dut (
        .po_sw_rstn(po_sw_rstn),
        .S_AXI_ACLK(clk),
        .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(awaddr),
        .S_AXI_AWPROT(awprot),
        .S_AXI_AWVALID(awvalid),
        .S_AXI_AWREADY(awready),
        .S_AXI_WDATA(wdata),
        .S_AXI_WSTRB(wstrb),
        .S_AXI_WVALID(wvalid),
        .S_AXI_WREADY(wready),
        .S_AXI_BRESP(bresp),
        .S_AXI_BVALID(bvalid),
        .S_AXI_BREADY(bready),
        .S_AXI_ARADDR(araddr),
        .S_AXI_ARPROT(arprot),
        .S_AXI_ARVALID(arvalid),
        .S_AXI_ARREADY(arready),
        .S_AXI_RDATA(rdata),
        .S_AXI_RRESP(rresp),
        .S_AXI_RVALID(rvalid),
        .S_AXI_RREADY(rready)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $fatal(1, "%s", msg);
        end
    endtask

    task automatic axil_write(input logic [3:0] address, input logic [31:0] data);
        int timeout;
        begin
            @(posedge clk);
            awaddr <= address;
            wdata <= data;
            awvalid <= 1'b1;
            wvalid <= 1'b1;
            bready <= 1'b1;
            timeout = 0;
            while (!(awready && wready)) begin
                @(posedge clk);
                timeout++;
                if (timeout > 20) $fatal(1, "AXI-Lite write timeout");
            end
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid <= 1'b0;
            timeout = 0;
            while (!bvalid) begin
                @(posedge clk);
                timeout++;
                if (timeout > 20) $fatal(1, "AXI-Lite response timeout");
            end
            check(bresp === 2'b00, "AXI-Lite write response must be OKAY");
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task automatic axil_read(input logic [3:0] address, output logic [31:0] data);
        int timeout;
        begin
            @(posedge clk);
            araddr <= address;
            arvalid <= 1'b1;
            rready <= 1'b1;
            timeout = 0;
            while (!arready) begin
                @(posedge clk);
                timeout++;
                if (timeout > 20) $fatal(1, "AXI-Lite read address timeout");
            end
            @(posedge clk);
            arvalid <= 1'b0;
            timeout = 0;
            while (!rvalid) begin
                @(posedge clk);
                timeout++;
                if (timeout > 20) $fatal(1, "AXI-Lite read data timeout");
            end
            data = rdata;
            check(rresp === 2'b00, "AXI-Lite read response must be OKAY");
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    initial begin
        logic [31:0] read_data;

        $dumpfile("sw_reset_slave_lite_tb.vcd");
        $dumpvars(0, sw_reset_slave_lite_tb);

        awaddr = '0;
        awprot = '0;
        awvalid = 1'b0;
        wdata = '0;
        wstrb = 4'hF;
        wvalid = 1'b0;
        bready = 1'b0;
        araddr = '0;
        arprot = '0;
        arvalid = 1'b0;
        rready = 1'b0;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);
        check(po_sw_rstn === 1'b0, "software reset output must reset low");

        axil_write(4'h0, 32'h0000_0001);
        check(po_sw_rstn === 1'b1, "software reset output must follow register bit 0 high");
        axil_read(4'h0, read_data);
        check(read_data[0] === 1'b1, "software reset register readback high mismatch");

        axil_write(4'h0, 32'h0000_0000);
        check(po_sw_rstn === 1'b0, "software reset output must follow register bit 0 low");
        axil_read(4'h0, read_data);
        check(read_data[0] === 1'b0, "software reset register readback low mismatch");

        $display("sw_reset_slave_lite_tb PASS");
        $finish;
    end

    initial begin
        repeat (250) @(posedge clk);
        $fatal(1, "sw_reset_slave_lite_tb timeout");
    end
endmodule
