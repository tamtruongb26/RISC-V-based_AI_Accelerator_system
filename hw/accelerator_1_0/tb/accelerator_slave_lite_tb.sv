`timescale 1ns / 1ps

module accelerator_slave_lite_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [31:0] po_input_nodes;
    logic [31:0] po_hidden_nodes;
    logic [31:0] po_output_nodes;
    logic [31:0] po_control_signal;
    logic [31:0] pi_status_register;
    logic        pi_wren_status_reg;

    logic [4:0]  awaddr;
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
    logic [4:0]  araddr;
    logic [2:0]  arprot;
    logic        arvalid;
    logic        arready;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready;

    always #5 clk = ~clk;

    accelerator_slave_lite_v1_0_S00_AXI dut (
        .po_input_nodes(po_input_nodes),
        .po_hidden_nodes(po_hidden_nodes),
        .po_output_nodes(po_output_nodes),
        .po_control_signal(po_control_signal),
        .pi_status_register(pi_status_register),
        .pi_wren_status_reg(pi_wren_status_reg),
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

    task automatic axil_write(input logic [4:0] address, input logic [31:0] data);
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
                if (timeout > 20) $fatal(1, "AXI-Lite write address/data timeout");
            end
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid <= 1'b0;
            timeout = 0;
            while (!bvalid) begin
                @(posedge clk);
                timeout++;
                if (timeout > 20) $fatal(1, "AXI-Lite write response timeout");
            end
            check(bresp === 2'b00, "AXI-Lite write response must be OKAY");
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task automatic axil_read(input logic [4:0] address, output logic [31:0] data);
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

        $dumpfile("accelerator_slave_lite_tb.vcd");
        $dumpvars(0, accelerator_slave_lite_tb);

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
        pi_status_register = '0;
        pi_wren_status_reg = 1'b0;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);

        axil_write(5'h00, 32'd784);
        axil_write(5'h04, 32'h0010_0010);
        axil_write(5'h08, 32'd10);
        axil_write(5'h0C, 32'h0000_0003);

        check(po_input_nodes === 32'd784, "input_nodes output mismatch");
        check(po_hidden_nodes === 32'h0010_0010, "hidden_nodes output mismatch");
        check(po_output_nodes === 32'd10, "output_nodes output mismatch");
        check(po_control_signal === 32'h0000_0003, "control_signal output mismatch");

        pi_status_register <= 32'h0000_0001;
        pi_wren_status_reg <= 1'b1;
        @(posedge clk);
        pi_wren_status_reg <= 1'b0;
        axil_read(5'h10, read_data);
        check(read_data === 32'h0000_0001, "status register read mismatch");

        $display("accelerator_slave_lite_tb PASS");
        $finish;
    end

    initial begin
        repeat (300) @(posedge clk);
        $fatal(1, "accelerator_slave_lite_tb timeout");
    end
endmodule
