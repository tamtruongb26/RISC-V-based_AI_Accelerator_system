`timescale 1ns / 1ps

module post_proc (
    input  wire         pi_clk,
    input  wire         pi_rst_n,

    input  wire [39:0]  pi_acc_in,        // Q*.8.22
    input  wire [15:0]  pi_bias,          // Q1.4.11
    input  wire         pi_valid_in,
    input  wire [1:0]   pi_act_mode,      // 00=bypass, 01=ReLU, 10=sigmoid

    output wire [15:0]  po_data_out,      // Q1.4.11
    output wire         po_valid_out
);

    // =============================================================
    // Stage 1 - Add bias (40-bit) + truncate + saturate to Q1.8.7
    // =============================================================
    // Bias upcast Q1.4.11 → Q*.8.22 (sign-extend 13b, append 11 zero LSB)
    wire signed [39:0] bias_q40 = {{13{pi_bias[15]}}, pi_bias, 11'b0};
    wire signed [39:0] sum_q40  = $signed(pi_acc_in) + bias_q40;

    // Truncate Q*.8.22 → Q1.17.7 (drop 15 LSB, keep top 25 bits)
    wire signed [24:0] sum_q187_wide = sum_q40[39:15];

    // Saturate Q1.17.7 → Q1.8.7
    reg signed [15:0] s1_comb;
    always @(*) begin
        if (sum_q187_wide[24:15] == 10'h000)
            s1_comb = sum_q187_wide[15:0];        // small positive, fits
        else if (sum_q187_wide[24:15] == 10'h3FF)
            s1_comb = sum_q187_wide[15:0];        // small negative, fits
        else if (sum_q187_wide[24] == 1'b0)
            s1_comb = 16'h7FFF;                   // overflow positive
        else
            s1_comb = 16'h8000;                   // overflow negative
    end

    reg signed [15:0] s1_reg;
    reg               s1_valid;
    reg  [1:0]        s1_mode;
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            s1_reg   <= 16'h0;
            s1_valid <= 1'b0;
            s1_mode  <= 2'b00;
        end else begin
            s1_reg   <= s1_comb;
            s1_valid <= pi_valid_in;
            s1_mode  <= pi_act_mode;
        end
    end

    // =============================================================
    // Stage 2 - Activation (3 path)
    // =============================================================
    // ── Path 1+2: bypass / ReLU registered ──
    reg signed [15:0] s2_pass_reg;
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            s2_pass_reg <= 16'h0;
        end else begin
            case (s1_mode)
                2'b00:   s2_pass_reg <= s1_reg;                            // bypass
                2'b01:   s2_pass_reg <= s1_reg[15] ? 16'h0 : s1_reg;       // ReLU
                default: s2_pass_reg <= 16'h0;                             // sigmoid path
            endcase
        end
    end

    // ── Path 3: sigmoid LUT (1-cycle latency) ──
    // Saturate Q1.8.7 → Q1.3.6 trước khi addr
    reg [9:0] sig_addr;
    always @(*) begin
        if ($signed(s1_reg) >= $signed(16'sd1024))
            sig_addr = 10'h1FF;                   // +sat (Q1.3.6 max)
        else if ($signed(s1_reg) < $signed(-16'sd1024))
            sig_addr = 10'h200;                   // -sat (Q1.3.6 min)
        else
            sig_addr = s1_reg[10:1];              // shift right 1 (raw_q136 = raw_q187 / 2)
    end

    wire [9:0] sig_data;
    sigmoid_lookup u_sig (
        .pi_clk  (pi_clk),
        .pi_ena  (s1_valid),
        .pi_addr (sig_addr),
        .po_data (sig_data)
    );

    // ── Pipeline metadata ──
    reg       s2_valid;
    reg [1:0] s2_mode;
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            s2_valid <= 1'b0;
            s2_mode  <= 2'b00;
        end else begin
            s2_valid <= s1_valid;
            s2_mode  <= s1_mode;
        end
    end

    // =============================================================
    // Stage 3 - MUX activation + saturate Q1.8.7 → Q1.4.11
    // =============================================================
    // Convert sigmoid Q1.0.9 → Q1.8.7 (raw_q187 = sig_data >> 2)
    wire signed [15:0] sig_q187 = {8'b0, sig_data[9:2]};

    // MUX activation
    wire signed [15:0] act_q187 = (s2_mode == 2'b10) ? sig_q187 : s2_pass_reg;

    // Saturate Q1.8.7 → Q1.4.11 (raw_q1411 = raw_q187 << 4 nếu không tràn)
    reg signed [15:0] s3_reg;
    reg               s3_valid;
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            s3_reg   <= 16'h0;
            s3_valid <= 1'b0;
        end else begin
            if ($signed(act_q187) >= $signed(16'sd2048))
                s3_reg <= 16'h7FFF;               // +sat Q1.4.11
            else if ($signed(act_q187) < $signed(-16'sd2048))
                s3_reg <= 16'h8000;               // -sat Q1.4.11
            else
                s3_reg <= act_q187 <<< 4;
            s3_valid <= s2_valid;
        end
    end

    assign po_data_out  = s3_reg;
    assign po_valid_out = s3_valid;

endmodule