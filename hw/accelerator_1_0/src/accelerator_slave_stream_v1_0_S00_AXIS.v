
`timescale 1 ns / 1 ps

	module accelerator_slave_stream_v1_0_S00_AXIS #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line

		// AXI4Stream sink: Data Width
		parameter integer C_S_AXIS_TDATA_WIDTH	= 32
	)
	(
		// Users to add ports here
        input wire pi_data_read,
        output wire po_mlp_data_valid,
        output wire [31:0] po_mlp_data,
		// User ports ends
		// Do not modify the ports beyond this line

		// AXI4Stream sink: Clock
		input wire  S_AXIS_ACLK,
		// AXI4Stream sink: Reset
		input wire  S_AXIS_ARESETN,
		// Ready to accept data in
		output wire  S_AXIS_TREADY,
		// Data in
		input wire [C_S_AXIS_TDATA_WIDTH-1 : 0] S_AXIS_TDATA,
		// Byte qualifier
		input wire [(C_S_AXIS_TDATA_WIDTH/8)-1 : 0] S_AXIS_TSTRB,
		// Indicates boundary of last packet
		input wire  S_AXIS_TLAST,
		// Data is in valid
		input wire  S_AXIS_TVALID
	);
	// Add user logic here
    reg [C_S_AXIS_TDATA_WIDTH-1 : 0] data_reg;
    reg                              data_valid;

    // Ready signal: zero-bubble handshake (ready if invalid OR being read right now)
    assign S_AXIS_TREADY = !data_valid || pi_data_read;

    always @(posedge S_AXIS_ACLK) begin
        if (!S_AXIS_ARESETN) begin
            data_valid <= 1'b0;
            data_reg   <= 0;
        end else begin
            if (S_AXIS_TVALID && S_AXIS_TREADY) begin
                // Mới có data từ Master (DMA)
                data_reg   <= S_AXIS_TDATA;
                data_valid <= 1'b1;
            end else if (pi_data_read) begin
                // Data đã được Control Unit đọc, đánh dấu không còn valid
                data_valid <= 1'b0;
            end
        end
    end

    assign po_mlp_data_valid = data_valid;
    assign po_mlp_data       = data_reg;

	// User logic ends

	endmodule
