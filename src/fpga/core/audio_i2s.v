// 48 kHz I2S output for the Pocket's audio interface.
// MCLK 12.288 MHz from clk_74a (fractional accumulator, as in the APF
// template), SCLK = MCLK / 4, 32 SCLKs per channel, 16-bit samples
// MSB first, one SCLK after LRCK changes (standard I2S).
//
// Copyright (c) 2026 mcbeefy34. GPL-3.0-or-later (see LICENSE).

`default_nettype none

module audio_i2s (
    input  wire        clk_74a,
    input  wire [15:0] sample_l,   // any clock domain, slowly changing
    input  wire [15:0] sample_r,
    output reg         audio_mclk = 1'b0,
    output reg         audio_lrck = 1'b0,
    output reg         audio_dac  = 1'b0
);

// MCLK = 12.288 MHz
reg [21:0] accum = 22'd0;
always @(posedge clk_74a) begin
    if (accum + 22'd245760 >= 22'd742500) begin
        accum <= accum + 22'd245760 - 22'd742500;
        audio_mclk <= ~audio_mclk;
    end else begin
        accum <= accum + 22'd245760;
    end
end

// SCLK = 3.072 MHz
reg [1:0] mclk_div = 2'd0;
always @(posedge audio_mclk) mclk_div <= mclk_div + 2'd1;
wire sclk = mclk_div[1];

// bring the samples over: take a value once it reads the same twice
reg [31:0] s1, s2, s3, safe;
always @(posedge sclk) begin
    s1 <= {sample_l, sample_r};
    s2 <= s1;
    s3 <= s2;
    if (s2 == s3) safe <= s3;
end

reg [4:0]  bitcnt = 5'd0;
reg [31:0] shift  = 32'd0;
always @(negedge sclk) begin
    bitcnt    <= bitcnt + 5'd1;
    audio_dac <= shift[31];
    shift     <= {shift[30:0], 1'b0};
    if (bitcnt == 5'd31) begin
        audio_lrck <= ~audio_lrck;
        // lrck goes high for the right channel, low for the left
        shift <= audio_lrck ? {safe[31:16], 16'd0} : {safe[15:0], 16'd0};
    end
end

endmodule
