// Laserdisc stand-in video for milestone 1
//
// 320x240 @ 59.94 Hz from a 6.1875 MHz pixel clock (394 x 262 total).
// Draws what the LD-V1000 emulation thinks is on screen instead of real
// disc video:
//   - top panel: player mode, status byte, last command, search target
//   - middle: scrolling colour bars (moves while the disc plays) with the
//     current frame number in large digits
//   - bottom: the cabinet's LED scoreboard
//
// All inputs must be stable in this clock domain (see dlair_top).
//
// Copyright (c) 2026 mcbeefy34. GPL-3.0-or-later (see LICENSE).

`default_nettype none

module ld_testvideo (
    input  wire        clk,            // pixel clock
    input  wire        reset,

    input  wire [2:0]  mode,
    input  wire        video_on,
    input  wire [7:0]  status,
    input  wire [7:0]  last_cmd,
    input  wire [7:0]  cmd_count,
    input  wire [19:0] frame_bcd,
    input  wire [15:0] frame_bin,
    input  wire [19:0] target_bcd,
    input  wire        audio_l,
    input  wire        audio_r,
    input  wire [63:0] led_digits,
    input  wire        rom_loaded,

    output reg  [23:0] rgb,
    output reg         de,
    output reg         hs,
    output reg         vs,
    output reg         field_toggle    // flips at the start of every field
);

localparam H_TOTAL = 10'd394, H_ACTIVE = 10'd320, H_START = 10'd40;
localparam V_TOTAL = 10'd262, V_ACTIVE = 10'd240, V_START = 10'd12;

reg [9:0] hc, vc;

always @(posedge clk) begin
    if (reset) begin
        hc <= 10'd0;
        vc <= 10'd0;
        field_toggle <= 1'b0;
    end else begin
        if (hc == H_TOTAL - 10'd1) begin
            hc <= 10'd0;
            if (vc == V_TOTAL - 10'd1) begin
                vc <= 10'd0;
                field_toggle <= ~field_toggle;
            end else begin
                vc <= vc + 10'd1;
            end
        end else begin
            hc <= hc + 10'd1;
        end
    end
end

wire       active = (hc >= H_START) && (hc < H_START + H_ACTIVE) &&
                    (vc >= V_START) && (vc < V_START + V_ACTIVE);
wire [8:0] x = hc - H_START;
wire [7:0] y = vc - V_START;

// ------------------------------------------------------- seven segment art
// MAME led_map: digit code -> segments (bit0 = a ... bit6 = g)
function [6:0] led_map(input [3:0] c);
    case (c)
        4'h0: led_map = 7'h3f; 4'h1: led_map = 7'h06; 4'h2: led_map = 7'h5b; 4'h3: led_map = 7'h4f;
        4'h4: led_map = 7'h66; 4'h5: led_map = 7'h6d; 4'h6: led_map = 7'h7c; 4'h7: led_map = 7'h07;
        4'h8: led_map = 7'h7f; 4'h9: led_map = 7'h67; 4'hA: led_map = 7'h77; 4'hB: led_map = 7'h7c;
        4'hC: led_map = 7'h39; 4'hD: led_map = 7'h5e; 4'hE: led_map = 7'h79; default: led_map = 7'h00;
    endcase
endfunction

// is pixel (px,py) inside a lit segment of a WxH digit with stroke T?
function seg_pix(input [6:0] segs, input [5:0] px, input [5:0] py,
                 input [5:0] W, input [5:0] H, input [5:0] T);
    reg [5:0] mid;
    begin
        mid = H >> 1;
        seg_pix =
            (segs[0] && py < T                      && px >= T && px < W - T) ||
            (segs[1] && px >= W - T && py >= T      && py <= mid)             ||
            (segs[2] && px >= W - T && py >= mid    && py < H - T)            ||
            (segs[3] && py >= H - T                 && px >= T && px < W - T) ||
            (segs[4] && px < T      && py >= mid    && py < H - T)            ||
            (segs[5] && px < T      && py >= T      && py <= mid)             ||
            (segs[6] && py >= mid - (T >> 1) && py < mid - (T >> 1) + T && px >= T && px < W - T);
    end
endfunction

// big frame counter: 5 digits, 32x56, stroke 6, pitch 40, at (64,72)
reg        big_on;
reg [2:0]  big_k;
reg [8:0]  big_dx;
always @(*) begin
    big_on = 1'b0;
    big_k  = 3'd0;
    big_dx = 9'd0;
    if (y >= 8'd72 && y < 8'd128 && x >= 9'd64 && x < 9'd256) begin
        big_k  = (x - 9'd64) / 9'd40;
        big_dx = (x - 9'd64) - big_k * 9'd40;
        if (big_dx < 9'd32)
            big_on = seg_pix(led_map(frame_bcd[(4 - big_k) * 4 +: 4]),
                             big_dx[5:0], y - 8'd72, 6'd32, 6'd56, 6'd6);
    end
end

// scoreboard digits: 12x20, stroke 2, pitch 16
// P1 score digits 0-5 at x=16, P2 score digits 8-13 at x=176, y=178
// P1 lives digit 6 at (24,218), P2 lives digit 7 at (248,218),
// credits digits 14-15 at (112,218) and (128,218)
reg        sb_on;
reg [3:0]  sb_idx;
reg [8:0]  sb_dx;
reg [7:0]  sb_dy;
reg        sb_hit;
always @(*) begin
    sb_hit = 1'b0;
    sb_idx = 4'd0;
    sb_dx  = 9'd0;
    sb_dy  = 8'd0;
    if (y >= 8'd178 && y < 8'd198) begin
        sb_dy = y - 8'd178;
        if (x >= 9'd16 && x < 9'd112) begin
            sb_hit = 1'b1;
            sb_idx = (x - 9'd16) >> 4;
            sb_dx  = (x - 9'd16) & 9'd15;
        end else if (x >= 9'd176 && x < 9'd272) begin
            sb_hit = 1'b1;
            sb_idx = 4'd8 + ((x - 9'd176) >> 4);
            sb_dx  = (x - 9'd176) & 9'd15;
        end
    end else if (y >= 8'd218 && y < 8'd238) begin
        sb_dy = y - 8'd218;
        if (x >= 9'd24 && x < 9'd40)        begin sb_hit = 1'b1; sb_idx = 4'd6;  sb_dx = x - 9'd24;  end
        else if (x >= 9'd248 && x < 9'd264) begin sb_hit = 1'b1; sb_idx = 4'd7;  sb_dx = x - 9'd248; end
        else if (x >= 9'd112 && x < 9'd128) begin sb_hit = 1'b1; sb_idx = 4'd14; sb_dx = x - 9'd112; end
        else if (x >= 9'd128 && x < 9'd144) begin sb_hit = 1'b1; sb_idx = 4'd15; sb_dx = x - 9'd128; end
    end
    sb_on = sb_hit && sb_dx < 9'd12 &&
            seg_pix(led_map(led_digits[sb_idx * 4 +: 4]), sb_dx[5:0], sb_dy[5:0],
                    6'd12, 6'd20, 6'd2);
end

// ------------------------------------------------------------------ text
wire [6:0] ch;
wire [4:0] glyph;
dl_text txt (
    .row(y[7:3]), .col(x[8:3]), .mode(mode), .status(status), .last_cmd(last_cmd),
    .cmd_count(cmd_count), .target_bcd(target_bcd), .audio_l(audio_l),
    .audio_r(audio_r), .ch(ch)
);
dl_font font (.ch(ch), .row(y[2:0]), .bits(glyph));
wire text_on = (x[2:0] >= 3'd1) && (x[2:0] <= 3'd5) && glyph[3'd5 - x[2:0]];

// "NO ROM" warning on row 17 when nothing was loaded
wire [6:0] warn_ch = (x[8:3] == 6'd17) ? 7'd78 : (x[8:3] == 6'd18) ? 7'd79 :
                     (x[8:3] == 6'd20) ? 7'd82 : (x[8:3] == 6'd21) ? 7'd79 :
                     (x[8:3] == 6'd22) ? 7'd77 : 7'd32;
wire [4:0] warn_glyph;
dl_font font_w (.ch(warn_ch), .row(y[2:0]), .bits(warn_glyph));
wire warn_on = !rom_loaded && y[7:3] == 5'd17 &&
               (x[2:0] >= 3'd1) && (x[2:0] <= 3'd5) && warn_glyph[3'd5 - x[2:0]];

// ------------------------------------------------------- disc window art
// scrolling colour bars, 8 x 40 px, shifted 2 px per disc frame
wire [9:0] xs0 = {1'b0, x} + {1'b0, frame_bin[7:0], 1'b0};
wire [9:0] xs1 = (xs0 >= 10'd640) ? xs0 - 10'd640 : (xs0 >= 10'd320) ? xs0 - 10'd320 : xs0;
reg  [23:0] bar;
always @(*) begin
    if      (xs1 < 10'd40)  bar = 24'h606060;
    else if (xs1 < 10'd80)  bar = 24'h606000;
    else if (xs1 < 10'd120) bar = 24'h006060;
    else if (xs1 < 10'd160) bar = 24'h006000;
    else if (xs1 < 10'd200) bar = 24'h600060;
    else if (xs1 < 10'd240) bar = 24'h600000;
    else if (xs1 < 10'd280) bar = 24'h000060;
    else                    bar = 24'h101010;
end

wire in_window = (y >= 8'd56) && (y < 8'd160);
localparam [2:0] MODE_SCANF = 3'd2, MODE_SCANR = 3'd3, MODE_SEARCH = 3'd4;

reg [23:0] pix;
always @(*) begin
    pix = 24'h000000;
    if (in_window) begin
        if (video_on)
            pix = bar;
        else if (mode == MODE_SCANF || mode == MODE_SCANR)
            pix = {1'b0, bar[23:17], 1'b0, bar[15:9], 1'b0, bar[7:1]};
        else if (mode == MODE_SEARCH)
            pix = 24'h000040;
        else
            pix = 24'h080808;
        if (big_on) pix = (video_on ? 24'hFFFFFF : 24'h707070);
    end
    if (sb_on)   pix = 24'hFF2000;
    if (text_on) pix = (y >= 8'd160) ? 24'hE6CC0D : 24'hFFFFFF;
    if (warn_on) pix = 24'hFF4040;
end

// ---------------------------------------------------------------- output
always @(posedge clk) begin
    if (reset) begin
        rgb <= 24'd0;
        de  <= 1'b0;
        hs  <= 1'b0;
        vs  <= 1'b0;
    end else begin
        vs  <= (hc == 10'd0) && (vc == 10'd0);
        hs  <= (hc == 10'd3);
        de  <= active;
        rgb <= active ? pix : 24'd0;
    end
end

endmodule
