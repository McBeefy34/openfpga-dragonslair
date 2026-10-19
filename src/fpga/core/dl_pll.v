// Core PLL: 74.25 MHz in
//   outclk_0  6.1875 MHz   video pixel clock     (742.5 MHz VCO / 120)
//   outclk_1  6.1875 MHz   same, +90 degrees     (40404 ps)
//   outclk_2  24.75  MHz   system clock          (742.5 MHz VCO / 30)
//
// Written in the same form Quartus' PLL IP generator emits, so no IP
// regeneration is needed. Swap in a generated mf_pllbase if you prefer.
//
// Copyright (c) 2026 mcbeefy34. GPL-3.0-or-later (see LICENSE).

`timescale 1ns/10ps

module dl_pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire locked
);

`ifdef SIMULATION
    // crude model for simulation only
    reg c_vid = 0, c_vid90 = 0, c_sys = 0;
    always #20.202 c_sys = ~c_sys;                      // 24.75 MHz
    always @(posedge c_sys) begin : divide
        reg [1:0] n;
        n = n + 1'b1;
        if (n == 2'd0 || n == 2'd2) c_vid <= ~c_vid;
    end
    always @(c_vid) c_vid90 <= #40.404 c_vid;
    assign outclk_0 = c_vid;
    assign outclk_1 = c_vid90;
    assign outclk_2 = c_sys;
    assign locked   = 1'b1;
`else
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(3),
        .output_clock_frequency0("6.187500 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("6.187500 MHz"),
        .phase_shift1("40404 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("24.750000 MHz"),
        .phase_shift2("0 ps"),
        .duty_cycle2(50),
        .output_clock_frequency3("0 MHz"),
        .phase_shift3("0 ps"),
        .duty_cycle3(50),
        .output_clock_frequency4("0 MHz"),
        .phase_shift4("0 ps"),
        .duty_cycle4(50),
        .output_clock_frequency5("0 MHz"),
        .phase_shift5("0 ps"),
        .duty_cycle5(50),
        .output_clock_frequency6("0 MHz"),
        .phase_shift6("0 ps"),
        .duty_cycle6(50),
        .output_clock_frequency7("0 MHz"),
        .phase_shift7("0 ps"),
        .duty_cycle7(50),
        .output_clock_frequency8("0 MHz"),
        .phase_shift8("0 ps"),
        .duty_cycle8(50),
        .output_clock_frequency9("0 MHz"),
        .phase_shift9("0 ps"),
        .duty_cycle9(50),
        .output_clock_frequency10("0 MHz"),
        .phase_shift10("0 ps"),
        .duty_cycle10(50),
        .output_clock_frequency11("0 MHz"),
        .phase_shift11("0 ps"),
        .duty_cycle11(50),
        .output_clock_frequency12("0 MHz"),
        .phase_shift12("0 ps"),
        .duty_cycle12(50),
        .output_clock_frequency13("0 MHz"),
        .phase_shift13("0 ps"),
        .duty_cycle13(50),
        .output_clock_frequency14("0 MHz"),
        .phase_shift14("0 ps"),
        .duty_cycle14(50),
        .output_clock_frequency15("0 MHz"),
        .phase_shift15("0 ps"),
        .duty_cycle15(50),
        .output_clock_frequency16("0 MHz"),
        .phase_shift16("0 ps"),
        .duty_cycle16(50),
        .output_clock_frequency17("0 MHz"),
        .phase_shift17("0 ps"),
        .duty_cycle17(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (rst),
        .outclk   ({outclk_2, outclk_1, outclk_0}),
        .locked   (locked),
        .fboutclk ( ),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
`endif

endmodule
