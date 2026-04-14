
`timescale 1 ns / 1 ps

	module accelerator_master_stream_v1_0_M00_AXIS #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line

		// Width of S_AXIS address bus. The slave accepts the read and write addresses of width C_M_AXIS_TDATA_WIDTH.
		parameter integer C_M_AXIS_TDATA_WIDTH	= 32,
		// Start count is the number of clock cycles the master will wait before initiating/issuing any transaction.
		parameter integer C_M_START_COUNT	= 32
	)
	(
		// Users to add ports here
        input  wire [9:0]  pi_num_transfers, // number of 32-bit words to send
        input  wire [31:0] pi_mlp_data,
        input  wire        pi_write_req,     // High to request sending one word
        output wire        po_write_done,    // Handshake back to CU that word was accepted by DMA
		// User ports ends
		// Do not modify the ports beyond this line

		// Global ports
		input wire  M_AXIS_ACLK,
		// 
		input wire  M_AXIS_ARESETN,
		// Master Stream Ports. TVALID indicates that the master is driving a valid transfer, A transfer takes place when both TVALID and TREADY are asserted. 
		output wire  M_AXIS_TVALID,
		// TDATA is the primary payload that is used to provide the data that is passing across the interface from the master.
		output wire [C_M_AXIS_TDATA_WIDTH-1 : 0] M_AXIS_TDATA,
		// TSTRB is the byte qualifier that indicates whether the content of the associated byte of TDATA is processed as a data byte or a position byte.
		output wire [(C_M_AXIS_TDATA_WIDTH/8)-1 : 0] M_AXIS_TSTRB,
		// TLAST indicates the boundary of a packet.
		output wire  M_AXIS_TLAST,
		// TREADY indicates that the slave can accept a transfer in the current cycle.
		input wire  M_AXIS_TREADY
	);
	// Add user logic here

    reg [9:0] tx_counter;
    
    // We assert TVALID exactly when the Control Unit requests a write
    assign M_AXIS_TVALID = pi_write_req;
    assign M_AXIS_TDATA  = pi_mlp_data;
    assign M_AXIS_TSTRB  = {(C_M_AXIS_TDATA_WIDTH/8){1'b1}};
    
    // Last transfer when counter reaches pi_num_transfers - 1
    assign M_AXIS_TLAST  = (tx_counter == pi_num_transfers - 1);

    // Write is accepted when both TVALID and TREADY are high
    wire tx_en = M_AXIS_TVALID && M_AXIS_TREADY;
    assign po_write_done = tx_en;

    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN) begin
            tx_counter <= 0;
        end else if (tx_en) begin
            if (M_AXIS_TLAST) begin
                tx_counter <= 0; // Reset for next layer / next bulk
            end else begin
                tx_counter <= tx_counter + 1;
            end
        end
    end

	// User logic ends

	endmodule
