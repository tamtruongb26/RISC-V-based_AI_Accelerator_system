`timescale 1ns / 1ps

module accelerator_master_stream_tb;
    localparam int DATA_WIDTH = 32;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [9:0]  pi_num_transfers;
    logic [31:0] pi_mlp_data;
    logic        pi_write_req;
    logic        po_write_done;
    logic        m_axis_tvalid;
    logic [31:0] m_axis_tdata;
    logic [3:0]  m_axis_tstrb;
    logic        m_axis_tlast;
    logic        m_axis_tready;

    always #5 clk = ~clk;

    accelerator_master_stream_v1_0_M00_AXIS #(
        .C_M_AXIS_TDATA_WIDTH(DATA_WIDTH),
        .C_M_START_COUNT(0)
    ) dut (
        .pi_num_transfers(pi_num_transfers),
        .pi_mlp_data(pi_mlp_data),
        .pi_write_req(pi_write_req),
        .po_write_done(po_write_done),
        .M_AXIS_ACLK(clk),
        .M_AXIS_ARESETN(rst_n),
        .M_AXIS_TVALID(m_axis_tvalid),
        .M_AXIS_TDATA(m_axis_tdata),
        .M_AXIS_TSTRB(m_axis_tstrb),
        .M_AXIS_TLAST(m_axis_tlast),
        .M_AXIS_TREADY(m_axis_tready)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $fatal(1, "%s", msg);
        end
    endtask

    task automatic send_word(input logic [31:0] data, input bit expected_last);
        begin
            @(posedge clk);
            pi_mlp_data  <= data;
            pi_write_req <= 1'b1;
            m_axis_tready <= 1'b1;
            @(posedge clk);
            check(m_axis_tvalid === 1'b1, "TVALID must follow pi_write_req");
            check(m_axis_tdata === data, "TDATA mismatch");
            check(m_axis_tstrb === 4'hF, "TSTRB mismatch");
            check(m_axis_tlast === expected_last, "TLAST mismatch");
            check(po_write_done === 1'b1, "write_done must assert on handshake");
            pi_write_req <= 1'b0;
            m_axis_tready <= 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("accelerator_master_stream_tb.vcd");
        $dumpvars(0, accelerator_master_stream_tb);

        pi_num_transfers = 10'd2;
        pi_mlp_data = '0;
        pi_write_req = 1'b0;
        m_axis_tready = 1'b0;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        pi_mlp_data <= 32'hCAFE_BABE;
        pi_write_req <= 1'b1;
        m_axis_tready <= 1'b0;
        @(posedge clk);
        check(m_axis_tvalid === 1'b1, "TVALID can assert while receiver is not ready");
        check(po_write_done === 1'b0, "write_done must wait for TREADY");
        pi_write_req <= 1'b0;

        send_word(32'h1111_2222, 1'b0);
        send_word(32'h3333_4444, 1'b1);
        send_word(32'h5555_6666, 1'b0);

        $display("accelerator_master_stream_tb PASS");
        $finish;
    end

    initial begin
        repeat (200) @(posedge clk);
        $fatal(1, "accelerator_master_stream_tb timeout");
    end
endmodule
