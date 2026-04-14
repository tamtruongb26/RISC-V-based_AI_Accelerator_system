
`timescale 1 ns / 1 ps

	module accelerator #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface S00_AXI
		parameter integer C_S00_AXI_DATA_WIDTH	= 32,
		parameter integer C_S00_AXI_ADDR_WIDTH	= 5,

		// Parameters of Axi Slave Bus Interface S00_AXIS
		parameter integer C_S00_AXIS_TDATA_WIDTH	= 32,

		// Parameters of Axi Master Bus Interface M00_AXIS
		parameter integer C_M00_AXIS_TDATA_WIDTH	= 32,
		parameter integer C_M00_AXIS_START_COUNT	= 32
	)
	(
		// Users to add ports here

		// User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface S00_AXI
		input wire  s00_axi_aclk,
		input wire  s00_axi_aresetn,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
		input wire [2 : 0] s00_axi_awprot,
		input wire  s00_axi_awvalid,
		output wire  s00_axi_awready,
		input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
		input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
		input wire  s00_axi_wvalid,
		output wire  s00_axi_wready,
		output wire [1 : 0] s00_axi_bresp,
		output wire  s00_axi_bvalid,
		input wire  s00_axi_bready,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
		input wire [2 : 0] s00_axi_arprot,
		input wire  s00_axi_arvalid,
		output wire  s00_axi_arready,
		output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
		output wire [1 : 0] s00_axi_rresp,
		output wire  s00_axi_rvalid,
		input wire  s00_axi_rready,

		// Ports of Axi Slave Bus Interface S00_AXIS
		input wire  s00_axis_aclk,
		input wire  s00_axis_aresetn,
		output wire  s00_axis_tready,
		input wire [C_S00_AXIS_TDATA_WIDTH-1 : 0] s00_axis_tdata,
		input wire [(C_S00_AXIS_TDATA_WIDTH/8)-1 : 0] s00_axis_tstrb,
		input wire  s00_axis_tlast,
		input wire  s00_axis_tvalid,

		// Ports of Axi Master Bus Interface M00_AXIS
		input wire  m00_axis_aclk,
		input wire  m00_axis_aresetn,
		output wire  m00_axis_tvalid,
		output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0] m00_axis_tdata,
		output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
		output wire  m00_axis_tlast,
		input wire  m00_axis_tready
	);
	
    // --- AXI-Lite (Config & Status) <-> Control Unit ---
    wire [31:0] w_input_nodes;
    wire [31:0] w_hidden_nodes;
    wire [31:0] w_output_nodes;
    wire [31:0] w_control_signal;
    wire [31:0] w_status_register;
    wire        w_wren_status_reg;

    // --- AXI-Stream S00 (Data In) <-> Control Unit & Datapath ---
    wire        w_mlp_data_valid;
    wire [31:0] w_mlp_data_in;
    wire        w_data_read;

    // --- AXI-Stream M00 (Data Out) <-> Control Unit & Datapath ---
    wire [9:0]  w_num_transfers;
    wire        w_write_req;
    wire        w_write_done;
    wire [31:0] w_mlp_data_out;
    
// Instantiation of Axi Bus Interface S00_AXI
	accelerator_slave_lite_v1_0_S00_AXI # ( 
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
	) accelerator_slave_lite_v1_0_S00_AXI_inst (
		.S_AXI_ACLK(s00_axi_aclk),
		.S_AXI_ARESETN(s00_axi_aresetn),
		.S_AXI_AWADDR(s00_axi_awaddr),
		.S_AXI_AWPROT(s00_axi_awprot),
		.S_AXI_AWVALID(s00_axi_awvalid),
		.S_AXI_AWREADY(s00_axi_awready),
		.S_AXI_WDATA(s00_axi_wdata),
		.S_AXI_WSTRB(s00_axi_wstrb),
		.S_AXI_WVALID(s00_axi_wvalid),
		.S_AXI_WREADY(s00_axi_wready),
		.S_AXI_BRESP(s00_axi_bresp),
		.S_AXI_BVALID(s00_axi_bvalid),
		.S_AXI_BREADY(s00_axi_bready),
		.S_AXI_ARADDR(s00_axi_araddr),
		.S_AXI_ARPROT(s00_axi_arprot),
		.S_AXI_ARVALID(s00_axi_arvalid),
		.S_AXI_ARREADY(s00_axi_arready),
		.S_AXI_RDATA(s00_axi_rdata),
		.S_AXI_RRESP(s00_axi_rresp),
		.S_AXI_RVALID(s00_axi_rvalid),
		.S_AXI_RREADY(s00_axi_rready),
		// Added user ports
		.po_input_nodes(w_input_nodes),
		.po_hidden_nodes(w_hidden_nodes),
		.po_output_nodes(w_output_nodes),
		.po_control_signal(w_control_signal),
		.pi_status_register(w_status_register),
		.pi_wren_status_reg(w_wren_status_reg)
	);

// Instantiation of Axi Bus Interface S00_AXIS
	accelerator_slave_stream_v1_0_S00_AXIS # ( 
		.C_S_AXIS_TDATA_WIDTH(C_S00_AXIS_TDATA_WIDTH)
	) accelerator_slave_stream_v1_0_S00_AXIS_inst (
		.S_AXIS_ACLK(s00_axis_aclk),
		.S_AXIS_ARESETN(s00_axis_aresetn),
		.S_AXIS_TREADY(s00_axis_tready),
		.S_AXIS_TDATA(s00_axis_tdata),
		.S_AXIS_TSTRB(s00_axis_tstrb),
		.S_AXIS_TLAST(s00_axis_tlast),
		.S_AXIS_TVALID(s00_axis_tvalid),
		// Added user ports
		.pi_data_read(w_data_read),
		.po_mlp_data_valid(w_mlp_data_valid),
		.po_mlp_data(w_mlp_data_in)
	);

// Instantiation of Axi Bus Interface M00_AXIS
	accelerator_master_stream_v1_0_M00_AXIS # ( 
		.C_M_AXIS_TDATA_WIDTH(C_M00_AXIS_TDATA_WIDTH),
		.C_M_START_COUNT(C_M00_AXIS_START_COUNT)
	) accelerator_master_stream_v1_0_M00_AXIS_inst (
		.M_AXIS_ACLK(m00_axis_aclk),
		.M_AXIS_ARESETN(m00_axis_aresetn),
		.M_AXIS_TVALID(m00_axis_tvalid),
		.M_AXIS_TDATA(m00_axis_tdata),
		.M_AXIS_TSTRB(m00_axis_tstrb),
		.M_AXIS_TLAST(m00_axis_tlast),
		.M_AXIS_TREADY(m00_axis_tready),
		// Added user ports
		.pi_num_transfers(w_num_transfers),
		.pi_mlp_data(w_mlp_data_out),
		.pi_write_req(w_write_req),
		.po_write_done(w_write_done)
	);

	// Add user logic here
    // =========================================================================
    // Internal Wires
    // =========================================================================
    // Clock and Reset
    wire sys_clk   = s00_axi_aclk;
    wire sys_rst_n = s00_axi_aresetn;


    // --- Control Unit <-> Datapath (BRAMs) ---
    wire [10:0] w_bram_inp_addra;
    wire [10:0] w_bram_inp_addrb;
    wire        w_bram_inp_ena;
    wire        w_bram_inp_enb;
    wire        w_bram_inp_wea;
    wire        w_bram_inp_web;

    wire [10:0] w_bram_bia_addra;
    wire [10:0] w_bram_bia_addrb;
    wire        w_bram_bia_ena;
    wire        w_bram_bia_enb;
    wire        w_bram_bia_wea;
    wire        w_bram_bia_web;

    wire [10:0] w_bram_wei_addra;
    wire [10:0] w_bram_wei_addrb;
    wire        w_bram_wei_ena;
    wire        w_bram_wei_enb;
    wire        w_bram_wei_wea;
    wire        w_bram_wei_web;

    wire [10:0] w_bram_reg_addra;
    wire [10:0] w_bram_reg_addrb;
    wire        w_bram_reg_ena;
    wire        w_bram_reg_enb;
    wire        w_bram_reg_wea;
    wire        w_bram_reg_web;

    // --- Control Unit <-> Datapath (Neurons) ---
    wire        w_valid;
    wire        w_clc_accumulator;
    wire        w_accumulation_done;

    // =========================================================================
    // Control Unit Instantiation
    // =========================================================================
    control_unit control_unit_inst (
        .pi_clk(sys_clk),
        .pi_rst_n(sys_rst_n),
        
        .pi_input_nodes(w_input_nodes),
        .pi_hidden_nodes(w_hidden_nodes),
        .pi_output_nodes(w_output_nodes),
        .pi_control_signal(w_control_signal),
        .po_status_register(w_status_register),
        .po_wren_status_reg(w_wren_status_reg),

        .pi_mlp_data(w_mlp_data_in),
        .pi_mlp_data_valid(w_mlp_data_valid),
        .po_data_read(w_data_read),

        .po_num_transfers(w_num_transfers),
        .po_write_req(w_write_req),
        .pi_write_done(w_write_done),

        .po_bram_inp_addra(w_bram_inp_addra),
        .po_bram_inp_addrb(w_bram_inp_addrb),
        .po_bram_inp_ena(w_bram_inp_ena),
        .po_bram_inp_enb(w_bram_inp_enb),
        .po_bram_inp_wea(w_bram_inp_wea),
        .po_bram_inp_web(w_bram_inp_web),

        .po_bram_bia_addra(w_bram_bia_addra),
        .po_bram_bia_addrb(w_bram_bia_addrb),
        .po_bram_bia_ena(w_bram_bia_ena),
        .po_bram_bia_enb(w_bram_bia_enb),
        .po_bram_bia_wea(w_bram_bia_wea),
        .po_bram_bia_web(w_bram_bia_web),

        .po_bram_wei_addra(w_bram_wei_addra),
        .po_bram_wei_addrb(w_bram_wei_addrb),
        .po_bram_wei_ena(w_bram_wei_ena),
        .po_bram_wei_enb(w_bram_wei_enb),
        .po_bram_wei_wea(w_bram_wei_wea),
        .po_bram_wei_web(w_bram_wei_web),

        .po_bram_reg_addra(w_bram_reg_addra),
        .po_bram_reg_addrb(w_bram_reg_addrb),
        .po_bram_reg_ena(w_bram_reg_ena),
        .po_bram_reg_enb(w_bram_reg_enb),
        .po_bram_reg_wea(w_bram_reg_wea),
        .po_bram_reg_web(w_bram_reg_web),

        .po_valid(w_valid),
        .po_clc_accumulator(w_clc_accumulator),
        .po_accumulation_done(w_accumulation_done)
    );

    // =========================================================================
    // Data Path Instantiation
    // =========================================================================
    data_path data_path_inst (
        .pi_clk(sys_clk),
        .pi_rst_n(sys_rst_n),

        .pi_axi_data(w_mlp_data_in),
        .po_axi_data(w_mlp_data_out),

        .pi_bram_inp_addra(w_bram_inp_addra),
        .pi_bram_inp_addrb(w_bram_inp_addrb),
        .pi_bram_inp_ena(w_bram_inp_ena),
        .pi_bram_inp_enb(w_bram_inp_enb),
        .pi_bram_inp_wea(w_bram_inp_wea),
        .pi_bram_inp_web(w_bram_inp_web),

        .pi_bram_bia_addra(w_bram_bia_addra),
        .pi_bram_bia_addrb(w_bram_bia_addrb),
        .pi_bram_bia_ena(w_bram_bia_ena),
        .pi_bram_bia_enb(w_bram_bia_enb),
        .pi_bram_bia_wea(w_bram_bia_wea),
        .pi_bram_bia_web(w_bram_bia_web),

        .pi_bram_wei_addra(w_bram_wei_addra),
        .pi_bram_wei_addrb(w_bram_wei_addrb),
        .pi_bram_wei_ena(w_bram_wei_ena),
        .pi_bram_wei_enb(w_bram_wei_enb),
        .pi_bram_wei_wea(w_bram_wei_wea),
        .pi_bram_wei_web(w_bram_wei_web),

        .pi_bram_reg_addra(w_bram_reg_addra),
        .pi_bram_reg_addrb(w_bram_reg_addrb),
        .pi_bram_reg_ena(w_bram_reg_ena),
        .pi_bram_reg_enb(w_bram_reg_enb),
        .pi_bram_reg_wea(w_bram_reg_wea),
        .pi_bram_reg_web(w_bram_reg_web),

        .pi_valid(w_valid),
        .pi_clc_accumulator(w_clc_accumulator),
        .pi_accumulation_done(w_accumulation_done)
    );

	// User logic ends

	endmodule
