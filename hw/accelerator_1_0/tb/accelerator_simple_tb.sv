`timescale 1ns / 1ps

module accelerator_simple_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [4:0]  s00_axi_awaddr;
    logic [2:0]  s00_axi_awprot;
    logic        s00_axi_awvalid;
    logic        s00_axi_awready;
    logic [31:0] s00_axi_wdata;
    logic [3:0]  s00_axi_wstrb;
    logic        s00_axi_wvalid;
    logic        s00_axi_wready;
    logic [1:0]  s00_axi_bresp;
    logic        s00_axi_bvalid;
    logic        s00_axi_bready;
    logic [4:0]  s00_axi_araddr;
    logic [2:0]  s00_axi_arprot;
    logic        s00_axi_arvalid;
    logic        s00_axi_arready;
    logic [31:0] s00_axi_rdata;
    logic [1:0]  s00_axi_rresp;
    logic        s00_axi_rvalid;
    logic        s00_axi_rready;

    logic        s00_axis_tready;
    logic [31:0] s00_axis_tdata;
    logic [3:0]  s00_axis_tstrb;
    logic        s00_axis_tlast;
    logic        s00_axis_tvalid;

    logic        m00_axis_tvalid;
    logic [31:0] m00_axis_tdata;
    logic [3:0]  m00_axis_tstrb;
    logic        m00_axis_tlast;
    logic        m00_axis_tready;

    logic [31:0] hidden1_word;
    logic [31:0] hidden2_word;
    logic [31:0] final_word;

    always #5 clk = ~clk;

    accelerator dut (
        .s00_axi_aclk(clk),
        .s00_axi_aresetn(rst_n),
        .s00_axi_awaddr(s00_axi_awaddr),
        .s00_axi_awprot(s00_axi_awprot),
        .s00_axi_awvalid(s00_axi_awvalid),
        .s00_axi_awready(s00_axi_awready),
        .s00_axi_wdata(s00_axi_wdata),
        .s00_axi_wstrb(s00_axi_wstrb),
        .s00_axi_wvalid(s00_axi_wvalid),
        .s00_axi_wready(s00_axi_wready),
        .s00_axi_bresp(s00_axi_bresp),
        .s00_axi_bvalid(s00_axi_bvalid),
        .s00_axi_bready(s00_axi_bready),
        .s00_axi_araddr(s00_axi_araddr),
        .s00_axi_arprot(s00_axi_arprot),
        .s00_axi_arvalid(s00_axi_arvalid),
        .s00_axi_arready(s00_axi_arready),
        .s00_axi_rdata(s00_axi_rdata),
        .s00_axi_rresp(s00_axi_rresp),
        .s00_axi_rvalid(s00_axi_rvalid),
        .s00_axi_rready(s00_axi_rready),
        .s00_axis_aclk(clk),
        .s00_axis_aresetn(rst_n),
        .s00_axis_tready(s00_axis_tready),
        .s00_axis_tdata(s00_axis_tdata),
        .s00_axis_tstrb(s00_axis_tstrb),
        .s00_axis_tlast(s00_axis_tlast),
        .s00_axis_tvalid(s00_axis_tvalid),
        .m00_axis_aclk(clk),
        .m00_axis_aresetn(rst_n),
        .m00_axis_tvalid(m00_axis_tvalid),
        .m00_axis_tdata(m00_axis_tdata),
        .m00_axis_tstrb(m00_axis_tstrb),
        .m00_axis_tlast(m00_axis_tlast),
        .m00_axis_tready(m00_axis_tready)
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
            s00_axi_awaddr <= address;
            s00_axi_wdata <= data;
            s00_axi_awvalid <= 1'b1;
            s00_axi_wvalid <= 1'b1;
            s00_axi_bready <= 1'b1;
            timeout = 0;
            while (!(s00_axi_awready && s00_axi_wready)) begin
                @(posedge clk);
                timeout++;
                if (timeout > 50) $fatal(1, "AXI-Lite write timeout");
            end
            @(posedge clk);
            s00_axi_awvalid <= 1'b0;
            s00_axi_wvalid <= 1'b0;
            timeout = 0;
            while (!s00_axi_bvalid) begin
                @(posedge clk);
                timeout++;
                if (timeout > 50) $fatal(1, "AXI-Lite response timeout");
            end
            check(s00_axi_bresp === 2'b00, "AXI-Lite write BRESP must be OKAY");
            @(posedge clk);
            s00_axi_bready <= 1'b0;
        end
    endtask

    task automatic axis_send(input logic [31:0] data, input bit last);
        int timeout;
        begin
            @(posedge clk);
            s00_axis_tdata <= data;
            s00_axis_tlast <= last;
            s00_axis_tvalid <= 1'b1;
            timeout = 0;
            while (!(s00_axis_tvalid && s00_axis_tready)) begin
                @(posedge clk);
                timeout++;
                if (timeout > 2000) $fatal(1, "AXI-Stream input timeout");
            end
            @(posedge clk);
            s00_axis_tvalid <= 1'b0;
            s00_axis_tlast <= 1'b0;
        end
    endtask

    task automatic capture_word(output logic [31:0] data);
        int timeout;
        begin
            m00_axis_tready <= 1'b1;
            timeout = 0;
            while (!(m00_axis_tvalid && m00_axis_tready)) begin
                @(posedge clk);
                timeout++;
                if (timeout > 10000) $fatal(1, "AXI-Stream output timeout");
            end
            data = m00_axis_tdata;
            check(m00_axis_tlast === 1'b1, "single-word layer output must assert TLAST");
            @(posedge clk);
            m00_axis_tready <= 1'b0;
        end
    endtask

    task automatic run_small_layer(input logic [31:0] input_word, output logic [31:0] output_word);
        begin
            axis_send(input_word, 1'b1);
            axis_send(32'h0000_0000, 1'b1);
            axis_send(32'h0800_0800, 1'b0);
            axis_send(32'h0800_0800, 1'b1);
            capture_word(output_word);
        end
    endtask

    initial begin
        $dumpfile("accelerator_simple_tb.vcd");
        $dumpvars(0, accelerator_simple_tb);

        s00_axi_awaddr = '0;
        s00_axi_awprot = '0;
        s00_axi_awvalid = 1'b0;
        s00_axi_wdata = '0;
        s00_axi_wstrb = 4'hF;
        s00_axi_wvalid = 1'b0;
        s00_axi_bready = 1'b0;
        s00_axi_araddr = '0;
        s00_axi_arprot = '0;
        s00_axi_arvalid = 1'b0;
        s00_axi_rready = 1'b0;
        s00_axis_tdata = '0;
        s00_axis_tstrb = 4'hF;
        s00_axis_tlast = 1'b0;
        s00_axis_tvalid = 1'b0;
        m00_axis_tready = 1'b0;

        repeat (8) @(posedge clk);
        rst_n <= 1'b1;
        repeat (8) @(posedge clk);

        axil_write(5'h00, 32'd2);
        axil_write(5'h04, 32'h0002_0002);
        axil_write(5'h08, 32'd2);
        axil_write(5'h0C, 32'h0000_0003);

        run_small_layer(32'h0400_0400, hidden1_word);
        run_small_layer(hidden1_word, hidden2_word);
        run_small_layer(hidden2_word, final_word);

        axil_write(5'h0C, 32'h0000_0001);
        repeat (10) @(posedge clk);

        $display("accelerator_simple_tb PASS final_word=%08x", final_word);
        $finish;
    end

    initial begin
        repeat (50000) @(posedge clk);
        $fatal(1, "accelerator_simple_tb timeout");
    end
endmodule
