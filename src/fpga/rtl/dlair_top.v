// Dragon's Lair core: board + LD-V1000 + stand-in video, platform-neutral
//
// Clock domains:
//   clk_sys  24.75 MHz  CPU, AY, LD-V1000 (clock enables derived here)
//   clk_vid  6.1875 MHz video timing and rendering (clk_sys / 4, same PLL)
//   rom_clk  bridge clock that loads the program ROM
//
// Copyright (c) 2026 mcbeefy34. GPL-3.0-or-later (see LICENSE).

`default_nettype none

module dlair_top (
    input  wire        clk_sys,
    input  wire        clk_vid,
    input  wire        reset_sys,     // synchronous to clk_sys
    input  wire        reset_vid,     // synchronous to clk_vid

    // program ROM load port (big-endian 32-bit words)
    input  wire        rom_clk,
    input  wire        rom_wr,
    input  wire [13:0] rom_wr_addr,   // word address
    input  wire [31:0] rom_wr_data,
    input  wire        rom_loaded,    // level, clk_sys domain

    // controls, clk_sys domain, active high
    input  wire        btn_up, btn_down, btn_left, btn_right, btn_action,
    input  wire        btn_start1, btn_start2, btn_coin1, btn_coin2,
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    // video, clk_vid domain
    output wire [23:0] video_rgb,
    output wire        video_de,
    output wire        video_hs,
    output wire        video_vs,

    // audio, clk_sys domain, signed
    output reg  [15:0] audio_sample
);

// ------------------------------------------------------- clock enables
// exact 4 MHz and 1 MHz averages from 24.75 MHz: N/24750 accumulators
reg  [14:0] acc4;
reg  [14:0] acc1;
reg         cen_4m, cen_1us, cen_2m, half;
always @(posedge clk_sys) begin
    if (reset_sys) begin
        acc4 <= 15'd0; acc1 <= 15'd0;
        cen_4m <= 1'b0; cen_2m <= 1'b0; cen_1us <= 1'b0; half <= 1'b0;
    end else begin
        cen_4m <= 1'b0; cen_2m <= 1'b0; cen_1us <= 1'b0;
        if (acc4 + 15'd4000 >= 15'd24750) begin
            acc4 <= acc4 + 15'd4000 - 15'd24750;
            cen_4m <= 1'b1;
            half <= ~half;
            cen_2m <= half;
        end else begin
            acc4 <= acc4 + 15'd4000;
        end
        if (acc1 + 15'd1000 >= 15'd24750) begin
            acc1 <= acc1 + 15'd1000 - 15'd24750;
            cen_1us <= 1'b1;
        end else begin
            acc1 <= acc1 + 15'd1000;
        end
    end
end

// --------------------------------------------------------- program ROM
// 40 KB window (0000-9FFF) stored as 16K x 32-bit words
reg  [31:0] rom_mem [0:16383];
reg  [31:0] rom_q;
reg  [1:0]  rom_lane;
wire [15:0] rom_addr;
always @(posedge rom_clk)
    if (rom_wr) rom_mem[rom_wr_addr] <= rom_wr_data;
always @(posedge clk_sys) begin
    rom_q    <= rom_mem[rom_addr[15:2]];
    rom_lane <= rom_addr[1:0];
end
wire [7:0] rom_byte = rom_q[31 - rom_lane * 8 -: 8];

// ------------------------------------------------------------ the board
wire        ld_data_wr;
wire [7:0]  ld_data;
wire        ld_enter_n;
wire [7:0]  ld_status;
wire        ld_status_strobe, ld_cmd_strobe;
wire [63:0] led_digits;
wire [9:0]  ay_sound;

dlair_board board (
    .clk(clk_sys), .reset(reset_sys || !rom_loaded),
    .cen_4m(cen_4m), .cen_2m(cen_2m),
    .rom_addr(rom_addr), .rom_data(rom_byte),
    .in_p1({3'b111, ~btn_action, ~btn_right, ~btn_left, ~btn_down, ~btn_up}),
    .in_sys({~btn_coin2, ~btn_coin1, ~btn_start2, ~btn_start1}),
    .dsw1(dsw1), .dsw2(dsw2),
    .ld_data_wr(ld_data_wr), .ld_data(ld_data), .ld_enter_n(ld_enter_n),
    .ld_status(ld_status), .ld_status_strobe(ld_status_strobe), .ld_cmd_strobe(ld_cmd_strobe),
    .led_digits(led_digits), .coin_counter(),
    .sound(ay_sound)
);

// ------------------------------------------- field timing from video
wire       field_toggle_vid;
reg  [2:0] field_sync;
always @(posedge clk_sys) field_sync <= {field_sync[1:0], field_toggle_vid};
wire field_start = field_sync[2] ^ field_sync[1];

// ---------------------------------------------------------- LD-V1000
wire [15:0] ld_frame;
wire [2:0]  ld_mode;
wire        ld_video_on, ld_audio_l, ld_audio_r;
wire [7:0]  ld_last_cmd, ld_cmd_count;
wire [19:0] ld_target_bcd;

ldv1000_hle ld (
    .clk(clk_sys), .reset(reset_sys), .ce_1us(cen_1us), .field_start(field_start),
    .data_wr(ld_data_wr), .data_in(ld_data), .status(ld_status),
    .status_strobe(ld_status_strobe), .cmd_strobe(ld_cmd_strobe),
    .frame(ld_frame), .mode(ld_mode), .video_on(ld_video_on),
    .audio_on_l(ld_audio_l), .audio_on_r(ld_audio_r),
    .last_cmd(ld_last_cmd), .cmd_count(ld_cmd_count), .target_bcd(ld_target_bcd)
);

// free-running binary -> BCD for the frame counter (double dabble)
reg  [15:0] dd_bin;
reg  [19:0] dd_bcd, frame_bcd;
reg  [4:0]  dd_step;
reg  [19:0] dd_adj;
integer d;
always @(*) begin
    dd_adj = dd_bcd;
    for (d = 0; d < 5; d = d + 1)
        if (dd_adj[d*4 +: 4] >= 4'd5) dd_adj[d*4 +: 4] = dd_adj[d*4 +: 4] + 4'd3;
end
always @(posedge clk_sys) begin
    if (reset_sys) begin
        dd_step <= 5'd0; dd_bin <= 16'd0; dd_bcd <= 20'd0; frame_bcd <= 20'd0;
    end else if (dd_step == 5'd0) begin
        dd_bin  <= ld_frame;
        dd_bcd  <= 20'd0;
        dd_step <= 5'd16;
    end else begin
        dd_bcd  <= {dd_adj[18:0], dd_bin[15]};
        dd_bin  <= {dd_bin[14:0], 1'b0};
        dd_step <= dd_step - 5'd1;
        if (dd_step == 5'd1) frame_bcd <= {dd_adj[18:0], dd_bin[15]};
    end
end

// ------------------------------------------------ snapshot to video
// Once per field the video side asks for fresh values (field toggle),
// the sys side captures them and answers with ack, then the video side
// copies the now-stable capture.
localparam SNAP_W = 3 + 1 + 8 + 8 + 8 + 20 + 16 + 20 + 1 + 1 + 64 + 1;
reg  [SNAP_W-1:0] snap_sys;
reg               ack_sys;
always @(posedge clk_sys) begin
    if (reset_sys) begin
        ack_sys  <= 1'b0;
        snap_sys <= {SNAP_W{1'b0}};
    end else if (field_start) begin
        snap_sys <= {ld_mode, ld_video_on, ld_status, ld_last_cmd, ld_cmd_count,
                     frame_bcd, ld_frame, ld_target_bcd, ld_audio_l, ld_audio_r,
                     led_digits, rom_loaded};
        ack_sys  <= ~ack_sys;
    end
end

reg  [2:0]        ack_vid_s;
reg  [SNAP_W-1:0] snap_vid;
always @(posedge clk_vid) begin
    ack_vid_s <= {ack_vid_s[1:0], ack_sys};
    if (reset_vid)
        snap_vid <= {SNAP_W{1'b0}};
    else if (ack_vid_s[2] ^ ack_vid_s[1])
        snap_vid <= snap_sys;
end

wire [2:0]  v_mode;
wire        v_video_on, v_audio_l, v_audio_r, v_rom_loaded;
wire [7:0]  v_status, v_last_cmd, v_cmd_count;
wire [19:0] v_frame_bcd, v_target_bcd;
wire [15:0] v_frame_bin;
wire [63:0] v_leds;
assign {v_mode, v_video_on, v_status, v_last_cmd, v_cmd_count, v_frame_bcd,
        v_frame_bin, v_target_bcd, v_audio_l, v_audio_r, v_leds, v_rom_loaded} = snap_vid;

ld_testvideo video (
    .clk(clk_vid), .reset(reset_vid),
    .mode(v_mode), .video_on(v_video_on), .status(v_status), .last_cmd(v_last_cmd),
    .cmd_count(v_cmd_count), .frame_bcd(v_frame_bcd), .frame_bin(v_frame_bin),
    .target_bcd(v_target_bcd), .audio_l(v_audio_l), .audio_r(v_audio_r),
    .led_digits(v_leds), .rom_loaded(v_rom_loaded),
    .rgb(video_rgb), .de(video_de), .hs(video_hs), .vs(video_vs),
    .field_toggle(field_toggle_vid)
);

// ------------------------------------------------------------- audio
// AY only for now; disc audio arrives with milestone 2. The AY mix is
// unsigned with silence at 0, so keep it positive to avoid a DC step.
always @(posedge clk_sys)
    audio_sample <= {1'b0, ay_sound, 5'd0};

endmodule
