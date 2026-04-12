import math

file_path = r"d:\RV_ACC\hw\sigmoid_lookup.sv"

with open(file_path, "w") as f:
    f.write("//==============================================================================\n")
    f.write("// sigmoid_lookup.sv\n")
    f.write("// MLP Accelerator \n")
    f.write("//==============================================================================\n\n")
    f.write("module sigmoid_lookup (\n")
    f.write("    input               pi_clk,\n")
    f.write("    input               pi_ena,\n")
    f.write("    input      [9:0]    pi_addra,\n")
    f.write("    output reg [9:0]    po_doa,\n")
    f.write("    input               pi_enb,\n")
    f.write("    input      [9:0]    pi_addrb,\n")
    f.write("    output reg [9:0]    po_dob\n")
    f.write(");\n\n")
    f.write("    (* rom_style = \"block\" *) reg [9:0] rom [0:1023];\n\n")
    f.write("    initial begin\n")
    
    for addr in range(1024):
        if addr < 512:
            val = addr
        else:
            val = addr - 1024
        
        x = val / 32.0
        try:
            exp_val = math.exp(-x)
        except OverflowError:
            exp_val = float('inf')
        
        sigmoid_val = 1.0 / (1.0 + exp_val)
        out_val = round(sigmoid_val * 512)
        
        if out_val > 512:
            out_val = 512
        if out_val < 0:
            out_val = 0
            
        f.write(f"        rom[{addr}] = 10'd{out_val}; // x = {x:.5f}, sig = {sigmoid_val:.5f}\n")
        
    f.write("    end\n\n")
    f.write("    always @(posedge pi_clk) begin\n")
    f.write("        if (pi_ena) begin\n")
    f.write("            po_doa <= rom[pi_addra];\n")
    f.write("        end\n")
    f.write("    end\n\n")
    f.write("    always @(posedge pi_clk) begin\n")
    f.write("        if (pi_enb) begin\n")
    f.write("            po_dob <= rom[pi_addrb];\n")
    f.write("        end\n")
    f.write("    end\n\n")
    f.write("endmodule\n")

print("Generated sigmoid_lookup.sv")
