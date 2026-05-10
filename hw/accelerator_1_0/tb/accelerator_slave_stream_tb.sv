`timescale 1ns / 1ps

module accelerator_slave_stream_tb;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic        pi_data_read;
    logic        po_mlp_data_valid;
    logic [31:0] po_mlp_data;
    logic        s_axis_tready;
    logic [31:0] s_axis_tdata;
    logic [3:0]  s_axis_tstrb;
    logic        s_axis_tlast;
    logic        s_axis_tvalid;

    always #5 clk = ~clk;

    accelerator_slave_stream_v1_0_S00_AXIS dut (
        .pi_data_read(pi_data_read),
        .po_mlp_data_valid(po_mlp_data_valid),
        .po_mlp_data(po_mlp_data),
        .S_AXIS_ACLK(clk),
        .S_AXIS_ARESETN(rst_n),
        .S_AXIS_TREADY(s_axis_tready),
        .S_AXIS_TDATA(s_axis_tdata),
        .S_AXIS_TSTRB(s_axis_tstrb),
        .S_AXIS_TLAST(s_axis_tlast),
        .S_AXIS_TVALID(s_axis_tvalid)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $fatal(1, "%s", msg);
        end
    endtask

    task automatic drive_word(input logic [31:0] data);
        begin
            @(posedge clk);
            s_axis_tdata <= data;
            s_axis_tvalid <= 1'b1;
            @(posedge clk);
            check(s_axis_tready === 1'b1, "slave stream must be ready for an empty buffer");
            s_axis_tvalid <= 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("accelerator_slave_stream_tb.vcd");
        $dumpvars(0, accelerator_slave_stream_tb);

        pi_data_read = 1'b0;
        s_axis_tdata = '0;
        s_axis_tstrb = 4'hF;
        s_axis_tlast = 1'b0;
        s_axis_tvalid = 1'b0;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);
        check(s_axis_tready === 1'b1, "TREADY must be high after reset when buffer is empty");

        drive_word(32'h1234_5678);
        check(po_mlp_data_valid === 1'b1, "data_valid must assert after accepted transfer");
        check(po_mlp_data === 32'h1234_5678, "latched data mismatch");
        check(s_axis_tready === 1'b0, "TREADY must drop while unread data is buffered");

        @(posedge clk);
        pi_data_read <= 1'b1;
        s_axis_tdata <= 32'hA5A5_5A5A;
        s_axis_tvalid <= 1'b1;
        @(posedge clk);
        check(s_axis_tready === 1'b1, "TREADY must allow zero-bubble read-and-replace");
        pi_data_read <= 1'b0;
        s_axis_tvalid <= 1'b0;
        @(posedge clk);
        check(po_mlp_data_valid === 1'b1, "replacement data must remain valid");
        check(po_mlp_data === 32'hA5A5_5A5A, "replacement data mismatch");

        @(posedge clk);
        pi_data_read <= 1'b1;
        @(posedge clk);
        pi_data_read <= 1'b0;
        @(posedge clk);
        check(po_mlp_data_valid === 1'b0, "data_valid must clear after read");

        $display("accelerator_slave_stream_tb PASS");
        $finish;
    end

    initial begin
        repeat (200) @(posedge clk);
        $fatal(1, "accelerator_slave_stream_tb timeout");
    end
endmodule
