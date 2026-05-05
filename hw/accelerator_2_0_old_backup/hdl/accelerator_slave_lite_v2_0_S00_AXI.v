
`timescale 1 ns / 1 ps

	module accelerator_slave_lite_v2_0_S00_AXI #
	(
		parameter integer C_S_AXI_DATA_WIDTH	= 32,
		parameter integer C_S_AXI_ADDR_WIDTH	= 5,
		parameter integer SA_N = 8
	)
	(
		// User ports
        output wire [31:0]  po_tile_m_size,      // slv_reg0
        output wire [31:0]  po_tile_k_size,      // slv_reg1
        output wire [31:0]  po_tile_n_size,      // slv_reg2
        output wire [31:0]  po_control,          // slv_reg3: bit[0]=START, bit[2:1]=ACT_MODE
        input wire  [31:0]  pi_status,           // slv_reg4: bit[0]=BUSY, bit[1]=DONE
        input wire          pi_wren_status,
		// User ports ends

		input wire  S_AXI_ACLK,
		input wire  S_AXI_ARESETN,
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
		input wire [2 : 0] S_AXI_AWPROT,
		input wire  S_AXI_AWVALID,
		output wire  S_AXI_AWREADY,
		input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
		input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
		input wire  S_AXI_WVALID,
		output wire  S_AXI_WREADY,
		output wire [1 : 0] S_AXI_BRESP,
		output wire  S_AXI_BVALID,
		input wire  S_AXI_BREADY,
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
		input wire [2 : 0] S_AXI_ARPROT,
		input wire  S_AXI_ARVALID,
		output wire  S_AXI_ARREADY,
		output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
		output wire [1 : 0] S_AXI_RRESP,
		output wire  S_AXI_RVALID,
		input wire  S_AXI_RREADY
	);

	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_awaddr;
	reg  	axi_awready;
	reg  	axi_wready;
	reg [1 : 0] 	axi_bresp;
	reg  	axi_bvalid;
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_araddr;
	reg  	axi_arready;
	reg [1 : 0] 	axi_rresp;
	reg  	axi_rvalid;

	localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
	localparam integer OPT_MEM_ADDR_BITS = 2;

	// Registers:
	// slv_reg0 = REG_TILE_M_SIZE
	// slv_reg1 = REG_TILE_K_SIZE
	// slv_reg2 = REG_TILE_N_SIZE
	// slv_reg3 = REG_CONTROL {ACT_MODE[2:1], START[0]}
	// slv_reg4 = REG_STATUS  {DONE[1], BUSY[0]} (read-only, written by HW)
	// slv_reg5 = REG_ARRAY_SIZE (read-only, = SA_N)
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg0;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg1;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg2;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg3;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg4;
	wire [C_S_AXI_DATA_WIDTH-1:0]	slv_reg5 = SA_N; // Read-only constant

	integer	 byte_index;

	assign S_AXI_AWREADY	= axi_awready;
	assign S_AXI_WREADY	= axi_wready;
	assign S_AXI_BRESP	= axi_bresp;
	assign S_AXI_BVALID	= axi_bvalid;
	assign S_AXI_ARREADY	= axi_arready;
	assign S_AXI_RRESP	= axi_rresp;
	assign S_AXI_RVALID	= axi_rvalid;

	 reg [1:0] state_write;
	 reg [1:0] state_read;
	 localparam Idle = 2'b00, Raddr = 2'b10, Rdata = 2'b11, Waddr = 2'b10, Wdata = 2'b11;

	// Write state machine (same as accelerator_1_0)
	always @(posedge S_AXI_ACLK)
	  begin
	     if (S_AXI_ARESETN == 1'b0)
	       begin
	         axi_awready <= 0;
	         axi_wready <= 0;
	         axi_bvalid <= 0;
	         axi_bresp <= 0;
	         axi_awaddr <= 0;
	         state_write <= Idle;
	       end
	     else
	       begin
	         case(state_write)
	           Idle:
	             begin
	               if(S_AXI_ARESETN == 1'b1)
	                 begin
	                   axi_awready <= 1'b1;
	                   axi_wready <= 1'b1;
	                   state_write <= Waddr;
	                 end
	               else state_write <= state_write;
	             end
	           Waddr:
	             begin
	               if (S_AXI_AWVALID && S_AXI_AWREADY)
	                  begin
	                    axi_awaddr <= S_AXI_AWADDR;
	                    if(S_AXI_WVALID)
	                      begin
	                        axi_awready <= 1'b1;
	                        state_write <= Waddr;
	                        axi_bvalid <= 1'b1;
	                      end
	                    else
	                      begin
	                        axi_awready <= 1'b0;
	                        state_write <= Wdata;
	                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                      end
	                  end
	               else
	                  begin
	                    state_write <= state_write;
	                    if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                   end
	             end
	          Wdata:
	             begin
	               if (S_AXI_WVALID)
	                 begin
	                   state_write <= Waddr;
	                   axi_bvalid <= 1'b1;
	                   axi_awready <= 1'b1;
	                 end
	                else
	                 begin
	                   state_write <= state_write;
	                   if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
	                 end
	             end
	          endcase
	        end
	      end

	// Register write logic
	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      slv_reg0 <= 0;
	      slv_reg1 <= 0;
	      slv_reg2 <= 0;
	      slv_reg3 <= 0;
	    end
	  else begin
	    // Auto-clear START bit after 1 cycle
	    if (slv_reg3[0]) slv_reg3[0] <= 1'b0;

	    if (S_AXI_WVALID)
	      begin
	        case ( (S_AXI_AWVALID) ? S_AXI_AWADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] : axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
	          3'h0:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 )
	                slv_reg0[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	          3'h1:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 )
	                slv_reg1[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	          3'h2:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 )
	                slv_reg2[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	          3'h3:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 )
	                slv_reg3[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	          default : begin
	                      slv_reg0 <= slv_reg0;
	                      slv_reg1 <= slv_reg1;
	                      slv_reg2 <= slv_reg2;
	                      slv_reg3 <= slv_reg3;
	                    end
	        endcase
	      end
	  end
	end

	// Read state machine (same as accelerator_1_0)
	  always @(posedge S_AXI_ACLK)
	    begin
	      if (S_AXI_ARESETN == 1'b0)
	        begin
	         axi_arready <= 1'b0;
	         axi_rvalid <= 1'b0;
	         axi_rresp <= 1'b0;
	         state_read <= Idle;
	        end
	      else
	        begin
	          case(state_read)
	            Idle:
	              begin
	                if (S_AXI_ARESETN == 1'b1)
	                  begin
	                    state_read <= Raddr;
	                    axi_arready <= 1'b1;
	                  end
	                else state_read <= state_read;
	              end
	            Raddr:
	              begin
	                if (S_AXI_ARVALID && S_AXI_ARREADY)
	                  begin
	                    state_read <= Rdata;
	                    axi_araddr <= S_AXI_ARADDR;
	                    axi_rvalid <= 1'b1;
	                    axi_arready <= 1'b0;
	                  end
	                else state_read <= state_read;
	              end
	            Rdata:
	              begin
	                if (S_AXI_RVALID && S_AXI_RREADY)
	                  begin
	                    axi_rvalid <= 1'b0;
	                    axi_arready <= 1'b1;
	                    state_read <= Raddr;
	                  end
	                else state_read <= state_read;
	              end
	           endcase
	          end
	        end

	// Read data mux
	  assign S_AXI_RDATA = (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h0) ? slv_reg0 :
	                       (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h1) ? slv_reg1 :
	                       (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h2) ? slv_reg2 :
	                       (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h3) ? slv_reg3 :
	                       (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h4) ? slv_reg4 :
	                       (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h5) ? slv_reg5 : 0;

	// User logic: Config outputs → Control Unit
	assign po_tile_m_size = slv_reg0;
	assign po_tile_k_size = slv_reg1;
	assign po_tile_n_size = slv_reg2;
	assign po_control     = slv_reg3;

	// Status register: written by control unit
	always @(posedge S_AXI_ACLK) begin
		if (!S_AXI_ARESETN) begin
			slv_reg4 <= 0;
		end else if (pi_wren_status) begin
			slv_reg4 <= pi_status;
		end
	end

	endmodule
