`timescale 1ns / 1ps

`include "raas_demo_vectors.svh"

module accelerator_smoke_tb;
    localparam int INPUT_WORDS = 392;
    localparam int HIDDEN_WORDS = 8;
    localparam int OUTPUT_WORDS = 5;
    localparam int INPUT_NODES = 784;
    localparam int HIDDEN_NODES = 16;
    localparam int OUTPUT_NODES = 10;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #5 clk = ~clk;

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

    logic [31:0] hidden1_words [0:HIDDEN_WORDS - 1];
    logic [31:0] hidden2_words [0:HIDDEN_WORDS - 1];
    logic [31:0] final_words [0:OUTPUT_WORDS - 1];
    logic [31:0] raas_demo_image_words [0:INPUT_WORDS - 1];
    logic [31:0] raas_demo_bias_words [0:20];
    logic [31:0] raas_demo_weight_words [0:6479];
    logic [31:0] raas_demo_golden_output_words [0:OUTPUT_WORDS - 1];

    initial begin
        $readmemh(`RAAS_DEMO_IMAGE_MEM, raas_demo_image_words);
        $readmemh(`RAAS_DEMO_BIAS_MEM, raas_demo_bias_words);
        $readmemh(`RAAS_DEMO_WEIGHT_MEM, raas_demo_weight_words);
        $readmemh(`RAAS_DEMO_GOLDEN_MEM, raas_demo_golden_output_words);
    end

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

    task automatic axil_write(input logic [4:0] address, input logic [31:0] data);
        begin
            @(posedge clk);
            s00_axi_awaddr <= address;
            s00_axi_awvalid <= 1'b1;
            s00_axi_wdata <= data;
            s00_axi_wvalid <= 1'b1;
            s00_axi_bready <= 1'b1;
            do begin
                @(posedge clk);
            end while (!(s00_axi_awready && s00_axi_wready));
            s00_axi_awvalid <= 1'b0;
            s00_axi_wvalid <= 1'b0;
            do begin
                @(posedge clk);
            end while (!s00_axi_bvalid);
            s00_axi_bready <= 1'b0;
        end
    endtask

    task automatic axis_send(input logic [31:0] data, input bit last);
        begin
            @(posedge clk);
            s00_axis_tdata <= data;
            s00_axis_tlast <= last;
            s00_axis_tvalid <= 1'b1;
            do begin
                @(posedge clk);
            end while (!(s00_axis_tvalid && s00_axis_tready));
            s00_axis_tvalid <= 1'b0;
            s00_axis_tlast <= 1'b0;
        end
    endtask

    task automatic capture_word(output logic [31:0] data, output bit last);
        int timeout;
        begin
            timeout = 0;
            while (1) begin
                @(posedge clk);
                if (m00_axis_tvalid && m00_axis_tready) begin
                    data = m00_axis_tdata;
                    last = m00_axis_tlast;
                    return;
                end
                timeout++;
                if (timeout > 1000000) begin
                    $fatal(1, "Timed out waiting for accelerator output");
                end
            end
        end
    endtask

    task automatic capture_hidden1;
        logic [31:0] word;
        bit last;
        begin
            m00_axis_tready <= 1'b1;
            for (int i = 0; i < HIDDEN_WORDS; i++) begin
                capture_word(word, last);
                hidden1_words[i] = word;
                if (last !== (i == HIDDEN_WORDS - 1)) begin
                    $fatal(1, "Hidden1 TLAST mismatch at word %0d", i);
                end
            end
            m00_axis_tready <= 1'b0;
        end
    endtask

    task automatic capture_hidden2;
        logic [31:0] word;
        bit last;
        begin
            m00_axis_tready <= 1'b1;
            for (int i = 0; i < HIDDEN_WORDS; i++) begin
                capture_word(word, last);
                hidden2_words[i] = word;
                if (last !== (i == HIDDEN_WORDS - 1)) begin
                    $fatal(1, "Hidden2 TLAST mismatch at word %0d", i);
                end
            end
            m00_axis_tready <= 1'b0;
        end
    endtask

    task automatic capture_final;
        logic [31:0] word;
        bit last;
        begin
            m00_axis_tready <= 1'b1;
            for (int i = 0; i < OUTPUT_WORDS; i++) begin
                capture_word(word, last);
                final_words[i] = word;
                if (last !== (i == OUTPUT_WORDS - 1)) begin
                    $fatal(1, "Final TLAST mismatch at word %0d", i);
                end
            end
            m00_axis_tready <= 1'b0;
        end
    endtask

    initial begin
        int bias_offset;
        int weight_offset;

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

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (10) @(posedge clk);

        axil_write(5'h00, INPUT_NODES);
        axil_write(5'h04, 32'h0010_0010);
        axil_write(5'h08, OUTPUT_NODES);
        axil_write(5'h0C, 32'h0000_0003);

        for (int i = 0; i < INPUT_WORDS; i++) begin
            axis_send(raas_demo_image_words[i], i == INPUT_WORDS - 1);
        end

        bias_offset = 0;
        weight_offset = 0;

        for (int pair = 0; pair < HIDDEN_WORDS; pair++) begin
            axis_send(raas_demo_bias_words[bias_offset], 1'b1);
            bias_offset++;
            for (int i = 0; i < INPUT_NODES; i++) begin
                axis_send(raas_demo_weight_words[weight_offset + i], i == INPUT_NODES - 1);
            end
            weight_offset += INPUT_NODES;
        end
        capture_hidden1();

        for (int i = 0; i < HIDDEN_WORDS; i++) begin
            axis_send(hidden1_words[i], i == HIDDEN_WORDS - 1);
        end
        for (int pair = 0; pair < HIDDEN_WORDS; pair++) begin
            axis_send(raas_demo_bias_words[bias_offset], 1'b1);
            bias_offset++;
            for (int i = 0; i < HIDDEN_NODES; i++) begin
                axis_send(raas_demo_weight_words[weight_offset + i], i == HIDDEN_NODES - 1);
            end
            weight_offset += HIDDEN_NODES;
        end
        capture_hidden2();

        for (int i = 0; i < HIDDEN_WORDS; i++) begin
            axis_send(hidden2_words[i], i == HIDDEN_WORDS - 1);
        end
        for (int pair = 0; pair < OUTPUT_WORDS; pair++) begin
            axis_send(raas_demo_bias_words[bias_offset], 1'b1);
            bias_offset++;
            for (int i = 0; i < HIDDEN_NODES; i++) begin
                axis_send(raas_demo_weight_words[weight_offset + i], i == HIDDEN_NODES - 1);
            end
            weight_offset += HIDDEN_NODES;
        end
        capture_final();

        axil_write(5'h0C, 32'h0000_0001);
        repeat (20) @(posedge clk);

        $write("RAAS final words:");
        for (int i = 0; i < OUTPUT_WORDS; i++) begin
            $write(" %08x", final_words[i]);
        end
        $write("\nRAAS golden words:");
        for (int i = 0; i < OUTPUT_WORDS; i++) begin
            $write(" %08x", raas_demo_golden_output_words[i]);
        end
        $write("\n");

        for (int i = 0; i < OUTPUT_WORDS; i++) begin
            if (final_words[i] !== raas_demo_golden_output_words[i]) begin
                $fatal(1, "Final word %0d mismatch: got %08x expected %08x",
                       i, final_words[i], raas_demo_golden_output_words[i]);
            end
        end

        $display("RAAS accelerator smoke PASS: image=%0d expected=%0d predicted=%0d",
                 RAAS_DEMO_IMAGE_INDEX, RAAS_DEMO_EXPECTED_DIGIT, RAAS_DEMO_GOLDEN_DIGIT);
        $finish;
    end
endmodule
