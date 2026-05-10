`timescale 1ns / 1ps

module sw_reset_tb;
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

    sw_reset dut (
        .po_sw_rstn(po_sw_rstn),
        .s00_axi_aclk(clk),
        .s00_axi_aresetn(rst_n),
        .s00_axi_awaddr(awaddr),
        .s00_axi_awprot(awprot),
        .s00_axi_awvalid(awvalid),
        .s00_axi_awready(awready),
        .s00_axi_wdata(wdata),
        .s00_axi_wstrb(wstrb),
        .s00_axi_wvalid(wvalid),
        .s00_axi_wready(wready),
        .s00_axi_bresp(bresp),
        .s00_axi_bvalid(bvalid),
        .s00_axi_bready(bready),
        .s00_axi_araddr(araddr),
        .s00_axi_arprot(arprot),
        .s00_axi_arvalid(arvalid),
        .s00_axi_arready(arready),
        .s00_axi_rdata(rdata),
        .s00_axi_rresp(rresp),
        .s00_axi_rvalid(rvalid),
        .s00_axi_rready(rready)
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

    initial begin
        $dumpfile("sw_reset_tb.vcd");
        $dumpvars(0, sw_reset_tb);

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
        check(po_sw_rstn === 1'b0, "top output must reset low");

        axil_write(4'h0, 32'h1);
        check(po_sw_rstn === 1'b1, "top output must assert after AXI write");

        axil_write(4'h0, 32'h0);
        check(po_sw_rstn === 1'b0, "top output must deassert after AXI write");

        $display("sw_reset_tb PASS");
        $finish;
    end

    initial begin
        repeat (250) @(posedge clk);
        $fatal(1, "sw_reset_tb timeout");
    end
endmodule
