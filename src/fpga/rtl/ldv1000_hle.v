// Pioneer LD-V1000 laserdisc player - high-level emulation
//
// Speaks the LD-V1000 parallel protocol to the Dragon's Lair board and
// tracks where the "disc" is. It does not produce picture or sound itself;
// it reports the current frame number and whether video/audio should be
// shown, so a separate stage (test pattern now, SD streaming later) can
// render that frame.
//
// Behaviour follows MAME's ldv1000hle.cpp (Ryan Holtz, BSD-3-Clause), which
// runs Dragon's Lair Rev F2 correctly. Deviations are marked "DEVIATION".
//
// Host-facing signals (as seen on the game board, see dlair.cpp):
//   data_wr/data_in  byte latched at E020, pushed on misc_w bit 5 falling
//   status           byte read at C020
//   status_strobe    SYSTEM bit 6, 1 = idle, 0 = strobe active (26 us)
//   cmd_strobe       SYSTEM bit 7, 0 = idle, 1 = strobe active (25 us)
//
// Copyright (c) 2026 mcbeefy34. GPL-3.0-or-later (see LICENSE).

`default_nettype none

module ldv1000_hle #(
    parameter [15:0] MAX_FRAME = 16'd54000
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        ce_1us,        // 1 MHz clock enable
    input  wire        field_start,   // one pulse per video field (59.94 Hz)

    input  wire        data_wr,       // host pushed a byte
    input  wire [7:0]  data_in,
    output reg  [7:0]  status,
    output reg         status_strobe, // 1 idle, 0 active
    output reg         cmd_strobe,    // 0 idle, 1 active

    // player state for the video/audio stage and the debug overlay
    output reg  [15:0] frame,         // current frame number (binary)
    output reg  [2:0]  mode,
    output wire        video_on,
    output wire        audio_on_l,
    output wire        audio_on_r,
    output reg  [7:0]  last_cmd,
    output reg  [7:0]  cmd_count,     // wraps, handy for spotting a stalled host
    output reg  [19:0] target_bcd     // last search / autostop target
);

// ---------------------------------------------------------------- constants
localparam [2:0] MODE_PARK  = 3'd0,
                 MODE_PLAY  = 3'd1,
                 MODE_SCANF = 3'd2,
                 MODE_SCANR = 3'd3,
                 MODE_SEARCH= 3'd4,
                 MODE_STOP  = 3'd5;

localparam [7:0] CMD_CLEAR   = 8'hBF, CMD_0 = 8'h3F, CMD_1 = 8'h0F, CMD_2 = 8'h8F,
                 CMD_3 = 8'h4F, CMD_4 = 8'h2F, CMD_5 = 8'hAF, CMD_6 = 8'h6F,
                 CMD_7 = 8'h1F, CMD_8 = 8'h9F, CMD_9 = 8'h5F,
                 CMD_STORE   = 8'hF5, CMD_RECALL  = 8'h7F, CMD_DISPLAY = 8'hF1,
                 CMD_AUDIO1  = 8'hF4, CMD_AUDIO2  = 8'hFC, CMD_PLAY    = 8'hFD,
                 CMD_STOP    = 8'hFB, CMD_AUTOSTOP= 8'hF3, CMD_SEARCH  = 8'hF7,
                 CMD_SCANF   = 8'hF0, CMD_SCANR   = 8'hF8, CMD_STEPF   = 8'hF6,
                 CMD_STEPR   = 8'hFE, CMD_REJECT  = 8'hF9, CMD_NOENTRY = 8'hFF,
                 CMD_LOAD    = 8'hCC, CMD_DISPOFF = 8'hCD, CMD_DISPON  = 8'hCE,
                 CMD_GETFRM  = 8'hC2, CMD_GET2ND  = 8'hC3, CMD_GET1ST  = 8'hC4,
                 CMD_XFER    = 8'hC8;

localparam [7:0] ST_PARK      = 8'h7C, ST_PLAY  = 8'h64, ST_STOP   = 8'h65,
                 ST_SEARCH    = 8'h50, ST_SEARCH_FINISH = 8'hD0,
                 ST_AUTOSTOP  = 8'h54, ST_SCAN  = 8'h4C, ST_FORWARD = 8'h2E,
                 ST_READY     = 8'h80;

// --------------------------------------------------------------- decoders
function is_digit(input [7:0] b);
    case (b)
        CMD_0, CMD_1, CMD_2, CMD_3, CMD_4, CMD_5, CMD_6, CMD_7, CMD_8, CMD_9: is_digit = 1'b1;
        default: is_digit = 1'b0;
    endcase
endfunction

function [3:0] digit_val(input [7:0] b);
    case (b)
        CMD_1: digit_val = 4'd1;  CMD_2: digit_val = 4'd2;  CMD_3: digit_val = 4'd3;
        CMD_4: digit_val = 4'd4;  CMD_5: digit_val = 4'd5;  CMD_6: digit_val = 4'd6;
        CMD_7: digit_val = 4'd7;  CMD_8: digit_val = 4'd8;  CMD_9: digit_val = 4'd9;
        default: digit_val = 4'd0;
    endcase
endfunction

function is_command(input [7:0] b);
    begin
        is_command = is_digit(b);
        case (b)
            CMD_CLEAR, CMD_STORE, CMD_RECALL, CMD_DISPLAY, CMD_AUDIO1, CMD_AUDIO2,
            CMD_PLAY, CMD_STOP, CMD_AUTOSTOP, CMD_SEARCH, CMD_SCANF, CMD_SCANR,
            CMD_STEPF, CMD_STEPR, CMD_REJECT, CMD_NOENTRY, CMD_LOAD, CMD_DISPOFF,
            CMD_DISPON, CMD_GETFRM, CMD_GET2ND, CMD_GET1ST, CMD_XFER:
                is_command = 1'b1;
            default: ;
        endcase
        if (b >= 8'hA0 && b <= 8'hA7) is_command = 1'b1;   // forward x0 .. x5
        if (b >= 8'hB1 && b <= 8'hBA) is_command = 1'b1;   // skip forward 10 .. 100
    end
endfunction

// play speed in quarter-frames per frame for FWD x0, x1/4, x1/2, x1 .. x5
function [4:0] fwd_speed(input [2:0] n);
    case (n)
        3'd0: fwd_speed = 5'd0;   3'd1: fwd_speed = 5'd1;
        3'd2: fwd_speed = 5'd2;   3'd3: fwd_speed = 5'd4;
        3'd4: fwd_speed = 5'd8;   3'd5: fwd_speed = 5'd12;
        3'd6: fwd_speed = 5'd16;  default: fwd_speed = 5'd20;
    endcase
endfunction

// 5-digit BCD to binary (only the low five digits are meaningful)
function [16:0] bcd2bin(input [19:0] b);
    bcd2bin = b[19:16] * 17'd10000 + b[15:12] * 17'd1000 +
              b[11:8]  * 17'd100   + b[7:4]   * 17'd10 + b[3:0];
endfunction

// ------------------------------------------------------------------- state
reg  [19:0] num;              // digits entered so far (BCD, last 5 kept)
reg  [3:0]  num_len;
reg         junk_pending;     // a non-command byte is waiting in the buffer
reg  [1:0]  audio_en;
reg  [7:0]  pre_stop_status;
reg  [4:0]  speed;            // quarter-frames per frame while playing
reg  [1:0]  speed_frac;
reg  [15:0] search_frame;
reg         search_active;
reg  [4:0]  seek_fields;      // fields left before the search lands
reg  [15:0] stop_frame;
reg         stop_active;
reg         field_odd;
reg  [31:0] pause_us;         // timed STOP (n x 100 ms) countdown
reg         pause_active;

assign video_on   = (mode == MODE_PLAY) || (mode == MODE_STOP);
assign audio_on_l = (mode == MODE_PLAY) && (speed == 5'd4) && audio_en[0];
assign audio_on_r = (mode == MODE_PLAY) && (speed == 5'd4) && audio_en[1];

// seek time: the MAME slider halves the distance every field, so a search
// lands after roughly log2(distance) fields
function [4:0] seek_time(input [16:0] seek_dist);
    integer i;
    begin
        seek_time = 5'd1;
        for (i = 0; i < 17; i = i + 1)
            if (seek_dist[i]) seek_time = i[4:0] + 5'd2;
    end
endfunction

// --------------------------------------------------------- strobe sequencer
// Playing: one status/command strobe pair per field, 500 us after the
// field starts. Parked: one pair every 21 ms.
reg  [9:0]  field_delay_us;
reg         field_delay_run;
reg  [14:0] park_us;
reg  [6:0]  seq_us;
reg         seq_run;

always @(posedge clk) begin
    if (reset) begin
        status_strobe   <= 1'b1;
        cmd_strobe      <= 1'b0;
        field_delay_run <= 1'b0;
        field_delay_us  <= 10'd0;
        park_us         <= 15'd0;
        seq_run         <= 1'b0;
        seq_us          <= 7'd0;
    end else begin
        if (field_start && mode != MODE_PARK) begin
            field_delay_run <= 1'b1;
            field_delay_us  <= 10'd0;
        end
        if (ce_1us) begin
            // field-locked trigger
            if (field_delay_run) begin
                field_delay_us <= field_delay_us + 10'd1;
                if (field_delay_us == 10'd497) begin   // 2 us of pipeline -> 500 us
                    field_delay_run <= 1'b0;
                    seq_run <= 1'b1;
                    seq_us  <= 7'd0;
                end
            end
            // parked trigger
            if (mode == MODE_PARK) begin
                park_us <= park_us + 15'd1;
                if (park_us == 15'd20999) begin
                    park_us <= 15'd0;
                    seq_run <= 1'b1;
                    seq_us  <= 7'd0;
                end
            end else begin
                park_us <= 15'd0;
            end
            // strobe pulses
            if (seq_run) begin
                seq_us <= seq_us + 7'd1;
                status_strobe <= !(seq_us < 7'd26);
                cmd_strobe    <=  (seq_us >= 7'd54 && seq_us < 7'd79);
                if (seq_us == 7'd79) begin
                    seq_run <= 1'b0;
                    status_strobe <= 1'b1;
                    cmd_strobe    <= 1'b0;
                end
            end
        end
    end
end

// ------------------------------------------------------- command + transport
reg  [7:0]  st;       // working copies for the single-cycle command handler
reg  [3:0]  nl;
reg  [19:0] nv;
reg  [16:0] tgt;
reg  [16:0] seek_dist;
reg  [16:0] nf;       // next frame (wide to catch overflow)
reg  [6:0]  adv;

always @(posedge clk) begin
    if (reset) begin
        status         <= ST_PARK | ST_READY;
        mode           <= MODE_PARK;
        frame          <= 16'd0;
        num            <= 20'd0;
        num_len        <= 4'd0;
        junk_pending   <= 1'b0;
        audio_en       <= 2'b11;
        pre_stop_status<= 8'd0;
        speed          <= 5'd4;
        speed_frac     <= 2'd0;
        search_frame   <= 16'd0;
        search_active  <= 1'b0;
        seek_fields    <= 5'd0;
        stop_frame     <= 16'd0;
        stop_active    <= 1'b0;
        field_odd      <= 1'b0;
        pause_us       <= 32'd0;
        pause_active   <= 1'b0;
        last_cmd       <= 8'hFF;
        cmd_count      <= 8'd0;
        target_bcd     <= 20'd0;
    end else begin
        // ---------------- timed pause (STOP with a duration)
        if (pause_active && ce_1us) begin
            if (pause_us == 32'd0) begin
                pause_active <= 1'b0;
                mode   <= MODE_PLAY;
                status <= pre_stop_status;
            end else begin
                pause_us <= pause_us - 32'd1;
            end
        end

        // ---------------- per-field transport
        if (field_start) begin
            field_odd <= ~field_odd;
            if (field_odd) begin   // advance once per frame (every 2nd field)
                case (mode)
                    MODE_PLAY: begin
                        adv = {2'b00, speed} + {5'd0, speed_frac};
                        speed_frac <= adv[1:0];
                        nf = {1'b0, frame} + {12'd0, adv[6:2]};
                        if (stop_active && nf >= {1'b0, stop_frame}) begin
                            nf = {1'b0, stop_frame};
                            stop_active <= 1'b0;
                            mode   <= MODE_STOP;
                            status <= (status & ST_READY) | ST_STOP;
                        end
                        frame <= (nf > {1'b0, MAX_FRAME}) ? MAX_FRAME : nf[15:0];
                    end
                    MODE_SCANF: begin
                        nf = {1'b0, frame} + 17'd66;    // ~2000 frames/s
                        frame <= (nf > {1'b0, MAX_FRAME}) ? MAX_FRAME : nf[15:0];
                    end
                    MODE_SCANR: begin
                        frame <= (frame > 16'd66) ? frame - 16'd66 : 16'd0;
                    end
                    default: ;
                endcase
            end
            if (mode == MODE_SEARCH && search_active) begin
                if (seek_fields <= 5'd1) begin
                    frame         <= search_frame;
                    search_active <= 1'b0;
                    mode          <= MODE_STOP;
                    status        <= ST_SEARCH_FINISH;
                end else begin
                    seek_fields <= seek_fields - 5'd1;
                end
            end
        end

        // ---------------- command bytes from the host
        if (data_wr) begin
            if (!is_command(data_in)) begin
                // MAME queues unknown bytes until a real command arrives
                junk_pending <= 1'b1;
            end else begin
                last_cmd  <= data_in;
                cmd_count <= cmd_count + 8'd1;
                st = status;
                nl = num_len;
                nv = num;
                // a queued unknown byte is processed first: it clears READY
                // (if set) and discards any digits entered so far
                if (junk_pending && st[7]) begin
                    st = st & ~ST_READY;
                    nl = 4'd0;
                    nv = 20'd0;
                end
                junk_pending <= 1'b0;

                if (st[7]) begin
                    st = st & ~ST_READY;
                    tgt = bcd2bin(nv);
                    if (is_digit(data_in)) begin
                        nv = {nv[15:0], digit_val(data_in)};
                        if (nl != 4'd15) nl = nl + 4'd1;
                    end else begin
                        case (data_in)
                            CMD_AUDIO1: audio_en[0] <= (nl == 4'd0) ? ~audio_en[0] : nv[0];
                            CMD_AUDIO2: audio_en[1] <= (nl == 4'd0) ? ~audio_en[1] : nv[0];

                            CMD_PLAY: begin
                                mode <= MODE_PLAY;
                                speed <= 5'd4;
                                st = ST_PLAY;
                                search_active <= 1'b0;
                                stop_active   <= 1'b0;
                                pause_active  <= 1'b0;
                            end

                            CMD_STOP: begin
                                if (nl != 4'd0) begin
                                    // n x 100 ms, then resume
                                    pause_us <= {15'd0, tgt} * 32'd100000;
                                    pause_active <= 1'b1;
                                    pre_stop_status <= st;
                                end
                                mode <= MODE_STOP;
                                st = ST_STOP;
                            end

                            CMD_AUTOSTOP: begin
                                target_bcd <= nv;
                                if (tgt < {1'b0, frame}) begin
                                    mode <= MODE_SEARCH;
                                    st = ST_SEARCH;
                                    search_frame  <= (tgt > {1'b0, MAX_FRAME}) ? MAX_FRAME : tgt[15:0];
                                    search_active <= 1'b1;
                                    seek_fields   <= seek_time({1'b0, frame} - tgt);
                                    stop_active   <= 1'b0;
                                end else begin
                                    // DEVIATION: MAME only sets the status here.
                                    // The real player plays on and stops at the
                                    // target, so do that.
                                    st = ST_AUTOSTOP;
                                    mode <= MODE_PLAY;
                                    speed <= 5'd4;
                                    stop_frame  <= (tgt > {1'b0, MAX_FRAME}) ? MAX_FRAME : tgt[15:0];
                                    stop_active <= 1'b1;
                                end
                            end

                            CMD_SEARCH: begin
                                target_bcd <= nv;
                                seek_dist = (tgt > {1'b0, frame}) ? tgt - {1'b0, frame} : {1'b0, frame} - tgt;
                                mode <= MODE_SEARCH;
                                st = ST_SEARCH;
                                search_frame  <= (tgt > {1'b0, MAX_FRAME}) ? MAX_FRAME : tgt[15:0];
                                search_active <= 1'b1;
                                seek_fields   <= seek_time(seek_dist);
                                stop_active   <= 1'b0;
                                pause_active  <= 1'b0;
                            end

                            CMD_SCANF, CMD_SCANR: begin
                                mode <= (data_in == CMD_SCANF) ? MODE_SCANF : MODE_SCANR;
                                st = ST_SCAN;
                                search_active <= 1'b0;
                                stop_active   <= 1'b0;
                            end

                            CMD_STEPF: begin
                                if (frame < MAX_FRAME) frame <= frame + 16'd1;
                                mode <= MODE_STOP;
                                st = ST_STOP;
                                search_active <= 1'b0;
                                stop_active   <= 1'b0;
                            end

                            CMD_STEPR: begin
                                if (frame != 16'd0) frame <= frame - 16'd1;
                                mode <= MODE_STOP;
                                st = ST_STOP;
                                search_active <= 1'b0;
                                stop_active   <= 1'b0;
                            end

                            CMD_REJECT: begin
                                mode <= MODE_PARK;
                                st = ST_PARK;
                                search_active <= 1'b0;
                                stop_active   <= 1'b0;
                                pause_active  <= 1'b0;
                            end

                            CMD_NOENTRY: st = st | ST_READY;

                            default: begin
                                if (data_in >= 8'hA0 && data_in <= 8'hA7) begin
                                    mode  <= MODE_PLAY;
                                    speed <= fwd_speed(data_in[2:0]);
                                    st = ST_FORWARD;
                                    search_active <= 1'b0;
                                    stop_active   <= 1'b0;
                                end else if (data_in >= 8'hB1 && data_in <= 8'hBA) begin
                                    // DEVIATION: MAME's skip is a slow seek; the
                                    // real player jumps N tracks and keeps playing.
                                    nf = {1'b0, frame} + {13'd0, data_in[3:0]} * 17'd10;
                                    frame <= (nf > {1'b0, MAX_FRAME}) ? MAX_FRAME : nf[15:0];
                                end
                                // CLEAR, STORE, RECALL, DISPLAY, LOAD, display
                                // on/off, GET_* and TRANSFER are no-ops here,
                                // as in MAME. Dragon's Lair does not use them.
                            end
                        endcase
                        nl = 4'd0;
                        nv = 20'd0;
                    end
                end else if (data_in == CMD_NOENTRY) begin
                    st = st | ST_READY;
                end else begin
                    st = st & ~ST_READY;
                end
                status  <= st;
                num_len <= nl;
                num     <= nv;
            end
        end
    end
end

endmodule
