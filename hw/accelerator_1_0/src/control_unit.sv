`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/11/2026 03:19:13 PM
// Design Name: 
// Module Name: control_unit
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module control_unit(
    input  wire        pi_clk,
    input  wire        pi_rst_n,
    
    // Cấu hình từ AXI-Lite
    input  wire [31:0] pi_input_nodes,
    input  wire [31:0] pi_hidden_nodes,
    input  wire [31:0] pi_output_nodes,
    input  wire [31:0] pi_control_signal, // {30'd0, DATA_RDY, NN_EN}
    output reg  [31:0] po_status_register, // bit 0 = BSY
    output reg         po_wren_status_reg,
    
    // Giao tiếp với AXI-Stream (Nhận từ DMA)
    input  wire [31:0] pi_mlp_data,
    input  wire        pi_mlp_data_valid,
    output wire        po_data_read,

    // Giao tiếp với AXI-Stream (Gửi về DMA qua M00_AXIS)
    output wire [9:0]  po_num_transfers,
    output wire        po_write_req,
    input  wire        pi_write_done,

    // Giao tiếp với datapath (BRAMs)
    output wire [10:0] po_bram_inp_addra,
    output wire [10:0] po_bram_inp_addrb,
    output wire        po_bram_inp_ena,
    output wire        po_bram_inp_enb,
    output wire        po_bram_inp_wea,
    output wire        po_bram_inp_web,

    output wire [10:0] po_bram_bia_addra,
    output wire [10:0] po_bram_bia_addrb,
    output wire        po_bram_bia_ena,
    output wire        po_bram_bia_enb,
    output wire        po_bram_bia_wea,
    output wire        po_bram_bia_web,

    output wire [10:0] po_bram_wei_addra,
    output wire [10:0] po_bram_wei_addrb,
    output wire        po_bram_wei_ena,
    output wire        po_bram_wei_enb,
    output wire        po_bram_wei_wea,
    output wire        po_bram_wei_web,

    output wire [10:0] po_bram_reg_addra,
    output wire [10:0] po_bram_reg_addrb,
    output wire        po_bram_reg_ena,
    output wire        po_bram_reg_enb,
    output wire        po_bram_reg_wea,
    output wire        po_bram_reg_web,

    // Neuron Signals
    output wire        po_valid,
    output wire        po_clc_accumulator,
    output wire        po_accumulation_done
);
    //==========================================================================
    // 1. Parameters & Types
    //==========================================================================
    typedef enum logic [3:0] {
        ST_OFF               = 4'd0,
        ST_IDLE              = 4'd1,
        ST_SET_LAYERS_INFO   = 4'd2,
        ST_LOAD_INPUTS       = 4'd3,
        ST_LOAD_BIASES       = 4'd4,
        ST_LOAD_WEIGHTS      = 4'd5,
        ST_NEURON_CALC       = 4'd6,
        ST_WAIT_SIG          = 4'd7,
        ST_WAIT_SIG2         = 4'd8,
        ST_STORE_RESULT      = 4'd9,
        ST_PREPARE_SEND      = 4'd10,
        ST_SEND_DATA_TO_CPU  = 4'd11,
        ST_PREPARE_INPUTS    = 4'd12,
        ST_WAIT_DATA_RDY_LOW = 4'd13
    } state_t;

    state_t state;

    //==========================================================================
    // 2. Registers
    //==========================================================================
    reg [9:0] current_layer [0:2];
    reg [9:0] previous_layer [0:2];
    
    reg [1:0] working_on_layer;
    reg [9:0] iter_done; 

    reg [9:0] inp_cnt;
    reg [9:0] bia_cnt;
    reg [9:0] wei_cnt;
    reg [9:0] neu_cnt;
    reg [9:0] tx_cnt;

    reg       wait_bram;
    reg       neu_valid_reg;

    wire nn_en    = pi_control_signal[0];
    wire data_rdy = pi_control_signal[1];

    //==========================================================================
    // 3. Status Output
    //==========================================================================
    always @(*) begin
        po_status_register = 32'd0;
        if (state != ST_OFF && state != ST_IDLE && state != ST_WAIT_DATA_RDY_LOW) begin
            po_status_register = 32'd1; // BSY = 1
        end
        po_wren_status_reg = 1'b1;
    end

    //==========================================================================
    // 4. AXI Handshakes
    //==========================================================================
    assign po_data_read = ((state == ST_LOAD_INPUTS && inp_cnt < (previous_layer[working_on_layer]>>1)) ||
                           (state == ST_LOAD_BIASES && bia_cnt == 0) ||
                           (state == ST_LOAD_WEIGHTS && wei_cnt < previous_layer[working_on_layer])) 
                           && pi_mlp_data_valid;

    assign po_write_req     = (state == ST_SEND_DATA_TO_CPU) && !wait_bram;
    assign po_num_transfers = current_layer[working_on_layer] >> 1;

    //==========================================================================
    // 5. Datapath Control Comb Logic
    //==========================================================================
    // a. Input BRAM
    assign po_bram_inp_ena = 1'b1;
    assign po_bram_inp_enb = 1'b1;
    assign po_bram_inp_wea = (state == ST_LOAD_INPUTS && pi_mlp_data_valid);
    assign po_bram_inp_web = (state == ST_LOAD_INPUTS && pi_mlp_data_valid);
    
    assign po_bram_inp_addra = (state == ST_LOAD_INPUTS) ? (inp_cnt << 1) : 
                               (state == ST_NEURON_CALC) ? (neu_cnt) : 11'd0;
    assign po_bram_inp_addrb = (state == ST_LOAD_INPUTS) ? ((inp_cnt << 1) | 11'd1) : 
                               (state == ST_NEURON_CALC) ? (neu_cnt) : 11'd0;

    // b. Bias BRAM
    assign po_bram_bia_ena = 1'b1;
    assign po_bram_bia_enb = 1'b1;
    assign po_bram_bia_wea = (state == ST_LOAD_BIASES && pi_mlp_data_valid);
    assign po_bram_bia_web = (state == ST_LOAD_BIASES && pi_mlp_data_valid);
    assign po_bram_bia_addra = 11'd0; 
    assign po_bram_bia_addrb = 11'd1;

    // c. Weight BRAM
    assign po_bram_wei_ena = 1'b1;
    assign po_bram_wei_enb = 1'b1;
    assign po_bram_wei_wea = (state == ST_LOAD_WEIGHTS && pi_mlp_data_valid);
    assign po_bram_wei_web = (state == ST_LOAD_WEIGHTS && pi_mlp_data_valid);
    
    assign po_bram_wei_addra = (state == ST_LOAD_WEIGHTS) ? (wei_cnt << 1) :
                               (state == ST_NEURON_CALC) ? (neu_cnt << 1) : 11'd0;
    assign po_bram_wei_addrb = (state == ST_LOAD_WEIGHTS) ? ((wei_cnt << 1) | 11'd1) :
                               (state == ST_NEURON_CALC) ? ((neu_cnt << 1) | 11'd1) : 11'd0;

    // d. Output Reg BRAM
    assign po_bram_reg_ena = 1'b1;
    assign po_bram_reg_enb = 1'b1;
    assign po_bram_reg_wea = (state == ST_STORE_RESULT);
    assign po_bram_reg_web = (state == ST_STORE_RESULT);
    
    assign po_bram_reg_addra = (state == ST_STORE_RESULT) ? (iter_done << 1) :
                               (state == ST_PREPARE_SEND || state == ST_SEND_DATA_TO_CPU) ? (tx_cnt << 1) : 11'd0;
    assign po_bram_reg_addrb = (state == ST_STORE_RESULT) ? ((iter_done << 1) | 11'd1) :
                               (state == ST_PREPARE_SEND || state == ST_SEND_DATA_TO_CPU) ? ((tx_cnt << 1) | 11'd1) : 11'd0;

    // e. Neuron Signals
    assign po_valid = neu_valid_reg;
    assign po_clc_accumulator = (state == ST_LOAD_WEIGHTS);
    assign po_accumulation_done = (state == ST_WAIT_SIG);


    //==========================================================================
    // 6. FSM Sequential Logic
    //==========================================================================
    always @(posedge pi_clk or negedge pi_rst_n) begin
        if (!pi_rst_n) begin
            state <= ST_OFF;
            working_on_layer <= 0;
            iter_done <= 0;
            inp_cnt <= 0;
            bia_cnt <= 0;
            wei_cnt <= 0;
            neu_cnt <= 0;
            tx_cnt <= 0;
            wait_bram <= 0;
            neu_valid_reg <= 0;
            
            // clear array elements
            current_layer[0] <= 0;  previous_layer[0] <= 0;
            current_layer[1] <= 0;  previous_layer[1] <= 0;
            current_layer[2] <= 0;  previous_layer[2] <= 0;
        end else begin
            case (state)
                ST_OFF: begin
                    if (nn_en) state <= ST_IDLE;
                end
                ST_IDLE: begin
                    if (!nn_en) state <= ST_OFF;
                    else if (data_rdy) state <= ST_SET_LAYERS_INFO;
                end
                ST_SET_LAYERS_INFO: begin
                    // Store layer configurations
                    current_layer[0]  <= pi_hidden_nodes[15:0];
                    previous_layer[0] <= pi_input_nodes[9:0];
                    
                    current_layer[1]  <= pi_hidden_nodes[31:16];
                    previous_layer[1] <= pi_hidden_nodes[15:0];

                    current_layer[2]  <= pi_output_nodes[9:0];
                    previous_layer[2] <= pi_hidden_nodes[31:16];
                    
                    working_on_layer <= 0;
                    iter_done <= 0;
                    inp_cnt <= 0;
                    
                    state <= ST_LOAD_INPUTS;
                end
                ST_LOAD_INPUTS: begin
                    if (inp_cnt == (previous_layer[working_on_layer] >> 1)) begin
                        bia_cnt <= 0;
                        state <= ST_LOAD_BIASES;
                    end else if (pi_mlp_data_valid) begin
                        inp_cnt <= inp_cnt + 1;
                    end
                end
                ST_LOAD_BIASES: begin 
                    if (bia_cnt == 1) begin
                        wei_cnt <= 0;
                        state <= ST_LOAD_WEIGHTS;
                    end else if (pi_mlp_data_valid) begin
                        bia_cnt <= 1; 
                    end
                end
                ST_LOAD_WEIGHTS: begin
                    if (wei_cnt == previous_layer[working_on_layer]) begin
                        neu_cnt <= 0;
                        neu_valid_reg <= 0;
                        state <= ST_NEURON_CALC;
                    end else if (pi_mlp_data_valid) begin
                        wei_cnt <= wei_cnt + 1;
                    end
                end
                ST_NEURON_CALC: begin
                    if (neu_cnt == 0) begin
                        neu_valid_reg <= 1; 
                        neu_cnt <= neu_cnt + 1;
                    end else if (neu_cnt == previous_layer[working_on_layer]) begin
                        // Phục vụ cycle dữ liệu cuối cùng từ BRAM
                        neu_valid_reg <= 1; 
                        neu_cnt <= neu_cnt + 1;
                    end else if (neu_cnt == previous_layer[working_on_layer] + 1) begin
                        // Kết thúc chuỗi tích lũy
                        neu_valid_reg <= 0;
                        state <= ST_WAIT_SIG;
                    end else begin
                        neu_cnt <= neu_cnt + 1;
                    end
                end
                ST_WAIT_SIG: begin 
                    // Pipeline Sigmoid (po_accumulation_done is driven 1 combinatorially here)
                    state <= ST_WAIT_SIG2; 
                end
                ST_WAIT_SIG2: begin 
                    // Wait for BRAM reg pipeline
                    state <= ST_STORE_RESULT;
                end
                ST_STORE_RESULT: begin
                    iter_done <= iter_done + 1;
                    if (iter_done + 1 == (current_layer[working_on_layer] >> 1)) begin
                        tx_cnt <= 0;
                        state <= ST_PREPARE_SEND; // 1 dummy cycle delay for BRAM read
                    end else begin
                        bia_cnt <= 0;
                        state <= ST_LOAD_BIASES;
                    end
                end
                ST_PREPARE_SEND: begin
                    wait_bram <= 0;
                    state <= ST_SEND_DATA_TO_CPU;
                end
                ST_SEND_DATA_TO_CPU: begin
                    if (wait_bram) begin
                        wait_bram <= 0; // Nghỉ 1 nhịp cho data BRAM đọc xong
                    end else if (pi_write_done) begin
                        if (tx_cnt == (current_layer[working_on_layer] >> 1) - 1) begin
                            state <= ST_PREPARE_INPUTS;
                        end else begin
                            tx_cnt <= tx_cnt + 1;
                            wait_bram <= 1'b1;
                        end
                    end
                end
                ST_PREPARE_INPUTS: begin
                    if (working_on_layer == 2) begin
                        // Hoàn thành cả 3 layers
                        state <= ST_WAIT_DATA_RDY_LOW;
                    end else begin
                        working_on_layer <= working_on_layer + 1;
                        iter_done <= 0;
                        inp_cnt <= 0;
                        state <= ST_LOAD_INPUTS;
                    end
                end
                ST_WAIT_DATA_RDY_LOW: begin
                    // Bắt buộc Software/CPU phải hạ cờ báo data_rdy xuống để tránh chạy lại 2 lần
                    if (!data_rdy) begin
                        state <= ST_IDLE;
                    end
                end
            endcase
            
            // Failsafe
            if (!nn_en && state != ST_OFF) begin
                state <= ST_OFF;
                working_on_layer <= 0;
                neu_valid_reg <= 0;
            end
        end
    end

endmodule
