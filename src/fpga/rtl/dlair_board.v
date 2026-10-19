// Dragon's Lair (US, LD-V1000 revisions) game board
//
// Z80 @ 4 MHz, 2 KB RAM, AY-3-8910 @ 2 MHz (sound + DIP switch ports),
// 16-digit LED scoreboard, LD-V1000 parallel interface.
// Memory map from MAME dlair.cpp (dlus_map):
//
//   0000-9FFF  R   program ROM
//   A000-A7FF  RW  RAM (mirrored to BFFF)
//   C000       R   AY-3-8910 data         (mirror 1FC7)
//   C008       R   P1: joystick + action  (active low)
//   C010       R   SYSTEM: start/coin, LD status strobe (b6), command strobe (b7)
//   C020       R   laserdisc status byte
//   E000       W   AY-3-8910 data
//   E008       W   misc: b4 coin counter, b5 push LD data (falling edge),
//                  b6 LD enter (active low), b7 int/ext
//   E010       W   AY-3-8910 address
//   E020       W   laserdisc data latch
//   E030-E037  W   LED digits 8-15  (offset = digit)
//   E038-E03F  W   LED digits 0-7
//
// IRQ: 16 MHz / 8 / 16^4 = 30.5 Hz, held until acknowledged.
//
// Copyright (c) 2026 mcbeefy34. GPL-3.0-or-later (see LICENSE).

`default_nettype none

module dlair_board (
    input  wire        clk,          // system clock (24.75 MHz)
    input  wire        reset,
    input  wire        cen_4m,       // Z80 clock enable, 4 MHz average
    input  wire        cen_2m,       // AY clock enable, 2 MHz average

    // program ROM (synchronous read, 1 clock latency)
    output wire [15:0] rom_addr,
    input  wire [7:0]  rom_data,

    // player inputs, active low as on the real board
    input  wire [7:0]  in_p1,        // b0 up, b1 down, b2 left, b3 right, b4 action
    input  wire [3:0]  in_sys,       // b0 start1, b1 start2, b2 coin1, b3 coin2
    input  wire [7:0]  dsw1,         // AY port A
    input  wire [7:0]  dsw2,         // AY port B

    // laserdisc player
    output reg         ld_data_wr,   // one-clock pulse
    output reg  [7:0]  ld_data,
    output reg         ld_enter_n,
    input  wire [7:0]  ld_status,
    input  wire        ld_status_strobe,
    input  wire        ld_cmd_strobe,

    // scoreboard: 16 digits x 4-bit code (0-9, A-E, F = blank)
    output reg  [63:0] led_digits,
    output reg         coin_counter,

    output wire [9:0]  sound         // AY mix, unsigned
);

// ------------------------------------------------------------------- CPU
wire [15:0] A;
wire [7:0]  cpu_do;
reg  [7:0]  cpu_di;
wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
reg         int_n;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) cpu (
    .RESET_n (~reset),
    .CLK     (clk),
    .CEN     (cen_4m),
    .WAIT_n  (1'b1),
    .INT_n   (int_n),
    .NMI_n   (1'b1),
    .BUSRQ_n (1'b1),
    .M1_n    (m1_n),
    .MREQ_n  (mreq_n),
    .IORQ_n  (iorq_n),
    .RD_n    (rd_n),
    .WR_n    (wr_n),
    .RFSH_n  (rfsh_n),
    .HALT_n  (),
    .BUSAK_n (),
    .OUT0    (1'b0),
    .A       (A),
    .DI      (cpu_di),
    .DO      (cpu_do)
);

// --------------------------------------------------------------- decode
wire mem_rd = !mreq_n && !rd_n && rfsh_n;
wire mem_wr = !mreq_n && !wr_n;
wire int_ack = !m1_n && !iorq_n;

wire sel_rom  = (A[15:13] <= 3'b100);              // 0000-9FFF
wire sel_ram  = (A[15:13] == 3'b101);              // A000-BFFF
wire sel_rd_io= (A[15:13] == 3'b110);              // C000-DFFF
wire sel_wr_io= (A[15:13] == 3'b111);              // E000-FFFF
wire [2:0] io_reg = A[5:3];

assign rom_addr = A;

// single-cycle write strobe at the start of each memory write
reg  mem_wr_d;
always @(posedge clk) mem_wr_d <= reset ? 1'b0 : mem_wr;
wire wr_pulse = mem_wr && !mem_wr_d;

// ------------------------------------------------------------------- RAM
reg  [7:0] ram [0:2047];
reg  [7:0] ram_q;
always @(posedge clk) begin
    if (mem_wr && sel_ram) ram[A[10:0]] <= cpu_do;
    ram_q <= ram[A[10:0]];
end

// ------------------------------------------------------------- AY-3-8910
reg  [3:0] ay_addr;
wire [7:0] ay_dout;
wire ay_wr_n = !(wr_pulse && sel_wr_io && io_reg == 3'd0);

always @(posedge clk) begin
    if (reset) ay_addr <= 4'd0;
    else if (wr_pulse && sel_wr_io && io_reg == 3'd2) ay_addr <= cpu_do[3:0];
end

jt49 #(.COMP(3'b000)) ay (
    .rst_n   (~reset),
    .clk     (clk),
    .clk_en  (cen_2m),
    .addr    (ay_addr),
    .cs_n    (1'b0),
    .wr_n    (ay_wr_n),
    .din     (cpu_do),
    .sel     (1'b1),
    .dout    (ay_dout),
    .sound   (sound),
    .A       (),
    .B       (),
    .C       (),
    .sample  (),
    .IOA_in  (dsw1),
    .IOA_out (),
    .IOA_oe  (),
    .IOB_in  (dsw2),
    .IOB_out (),
    .IOB_oe  ()
);

// ------------------------------------------------------------- read mux
wire [7:0] sys_port = { ld_cmd_strobe, ld_status_strobe, 2'b11, in_sys };

always @(*) begin
    cpu_di = 8'hFF;
    if (int_ack)
        cpu_di = 8'hFF;                       // RST 38h vector, as in MAME
    else if (sel_rom)
        cpu_di = rom_data;
    else if (sel_ram)
        cpu_di = ram_q;
    else if (sel_rd_io) begin
        case (io_reg)
            3'd0:    cpu_di = ay_dout;
            3'd1:    cpu_di = in_p1;
            3'd2:    cpu_di = sys_port;
            3'd4:    cpu_di = ld_status;
            default: cpu_di = 8'hFF;
        endcase
    end
end

// ------------------------------------------------- writes: misc, LD, LEDs
reg  [7:0] misc_last;

always @(posedge clk) begin
    if (reset) begin
        misc_last    <= 8'hFF;
        ld_data      <= 8'hFF;
        ld_data_wr   <= 1'b0;
        ld_enter_n   <= 1'b1;
        coin_counter <= 1'b0;
        led_digits   <= {16{4'hF}};
    end else begin
        ld_data_wr <= 1'b0;
        if (wr_pulse && sel_wr_io) begin
            case (io_reg)
                3'd1: begin                           // E008 misc
                    misc_last    <= cpu_do;
                    coin_counter <= ~cpu_do[4];
                    ld_enter_n   <= cpu_do[6];
                    if (misc_last[5] && !cpu_do[5])   // bit 5 falling: push byte
                        ld_data_wr <= 1'b1;
                end
                3'd4: ld_data <= cpu_do;              // E020 data latch
                3'd6: led_digits[{1'b1, A[2:0]}*4 +: 4] <= cpu_do[3:0];  // E030-E037: digits 8-15
                3'd7: led_digits[{1'b0, A[2:0]}*4 +: 4] <= cpu_do[3:0];  // E038-E03F: digits 0-7
                default: ;
            endcase
        end
    end
end

// ------------------------------------------------------------- 30 Hz IRQ
// 2 MHz / 65536 = 30.52 Hz (16 MHz / 8 / 16 / 16 / 16 / 16 in MAME)
reg [15:0] irq_div;
always @(posedge clk) begin
    if (reset) begin
        irq_div <= 16'd0;
        int_n   <= 1'b1;
    end else begin
        if (cen_2m) begin
            irq_div <= irq_div + 16'd1;
            if (irq_div == 16'hFFFF) int_n <= 1'b0;
        end
        if (int_ack) int_n <= 1'b1;           // irq0_line_hold
    end
end

endmodule
