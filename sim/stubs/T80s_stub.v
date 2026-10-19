// Port-compatible stand-in for the VHDL T80s, used only for Verilator
// lint/simulation of the Verilog parts. The real CPU is t80/T80s.vhd.
module T80s #(parameter Mode = 0, parameter T2Write = 1, parameter IOWait = 1) (
    input  wire        RESET_n, CLK, CEN, WAIT_n, INT_n, NMI_n, BUSRQ_n,
    output wire        M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n,
    input  wire        OUT0,
    output wire [15:0] A,
    input  wire [7:0]  DI,
    output wire [7:0]  DO
);
    assign {M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n} = 8'hFF;
    assign A  = 16'h0000;
    assign DO = 8'h00;
    wire _unused = &{1'b0, RESET_n, CLK, CEN, WAIT_n, INT_n, NMI_n, BUSRQ_n, OUT0, DI};
endmodule
