// Bus-functional stand-in for T80s used by the board test (sim/tb_board.cpp).
// Instead of executing Z80 code it replays a fixed list of memory reads and
// writes with Z80-like timing (T1-T3 per access, on CEN), and checks each
// read against an expected value. Exercises the board's address decode, the
// LD-V1000 handshake, the AY ports and the scoreboard latches.
module T80s #(parameter Mode = 0, parameter T2Write = 1, parameter IOWait = 1) (
    input  wire        RESET_n, CLK, CEN, WAIT_n, INT_n, NMI_n, BUSRQ_n,
    output reg         M1_n, MREQ_n, IORQ_n, RD_n, WR_n,
    output wire        RFSH_n, HALT_n, BUSAK_n,
    input  wire        OUT0,
    output reg  [15:0] A,
    input  wire [7:0]  DI,
    output reg  [7:0]  DO
);
    assign RFSH_n = 1'b1;
    assign HALT_n = 1'b1;
    assign BUSAK_n = 1'b1;

    // op: [35:34] kind (0 write, 1 read+check, 2 wait N x 1024 CEN, 3 end)
    //     [33:18] address  [17:10] data/expected  [9:2] mask
    localparam W = 2'd0, R = 2'd1, WAIT = 2'd2, END = 2'd3;
    reg [35:0] prog [0:255];
    reg [7:0]  pc;
    reg [2:0]  t;
    reg [19:0] wait_cnt;
    integer    fails = 0, checks = 0;
    reg        done = 1'b0;

    function [35:0] op(input [1:0] k, input [15:0] a, input [7:0] d, input [7:0] m);
        op = {k, a, d, m, 2'b00};
    endfunction

    task send_ld(input [7:0] b);   // latch byte, then pulse E008 bit 5 low
        begin
            prog[pc] = op(W, 16'hE020, b, 8'h00);    pc = pc + 1;
            prog[pc] = op(W, 16'hE008, 8'h60, 8'h00); pc = pc + 1;
            prog[pc] = op(W, 16'hE008, 8'h40, 8'h00); pc = pc + 1;
            prog[pc] = op(W, 16'hE008, 8'h60, 8'h00); pc = pc + 1;
        end
    endtask

    initial begin
        pc = 0;
        // ROM bytes loaded by the testbench: 0000=11 0001=22 0002=33 0003=44 7FFF=A5
        prog[pc] = op(R, 16'h0000, 8'h11, 8'hFF); pc = pc + 1;
        prog[pc] = op(R, 16'h0003, 8'h44, 8'hFF); pc = pc + 1;
        prog[pc] = op(R, 16'h7FFF, 8'hA5, 8'hFF); pc = pc + 1;
        // RAM write/read and mirror at B800
        prog[pc] = op(W, 16'hA123, 8'h5A, 8'h00); pc = pc + 1;
        prog[pc] = op(R, 16'hA123, 8'h5A, 8'hFF); pc = pc + 1;
        prog[pc] = op(R, 16'hB923, 8'h5A, 8'hFF); pc = pc + 1;
        // inputs: testbench holds "up" and "coin1" -> P1 = FE, SYSTEM low nibble = B
        prog[pc] = op(R, 16'hC008, 8'hFE, 8'hFF); pc = pc + 1;
        prog[pc] = op(R, 16'hC010, 8'h0B, 8'h0F); pc = pc + 1;
        prog[pc] = op(R, 16'hC7D0, 8'h0B, 8'h0F); pc = pc + 1;   // mirrored
        // AY: DIP bank A on port A (reg 14), bank B on port B (reg 15)
        prog[pc] = op(W, 16'hE010, 8'h0E, 8'h00); pc = pc + 1;
        prog[pc] = op(R, 16'hC000, 8'h20, 8'hFF); pc = pc + 1;
        prog[pc] = op(W, 16'hE010, 8'h0F, 8'h00); pc = pc + 1;
        prog[pc] = op(R, 16'hC000, 8'h79, 8'hFF); pc = pc + 1;
        // AY register write/read-back
        prog[pc] = op(W, 16'hE010, 8'h01, 8'h00); pc = pc + 1;
        prog[pc] = op(W, 16'hE000, 8'h0C, 8'h00); pc = pc + 1;
        prog[pc] = op(R, 16'hC000, 8'h0C, 8'h0F); pc = pc + 1;
        // scoreboard: digit 2 = 7, digit 14 = 1, digit 15 = 3
        prog[pc] = op(W, 16'hE03A, 8'h07, 8'h00); pc = pc + 1;
        prog[pc] = op(W, 16'hE036, 8'h01, 8'h00); pc = pc + 1;
        prog[pc] = op(W, 16'hE037, 8'h03, 8'h00); pc = pc + 1;
        // laserdisc: parked + ready
        prog[pc] = op(R, 16'hC020, 8'hFC, 8'hFF); pc = pc + 1;
        // search to frame 00042: FF 0 FF 0 FF 0 FF 4 FF 2 FF F7
        send_ld(8'hFF); send_ld(8'h3F); send_ld(8'hFF); send_ld(8'h3F);
        send_ld(8'hFF); send_ld(8'h3F); send_ld(8'hFF); send_ld(8'h2F);
        send_ld(8'hFF); send_ld(8'h8F); send_ld(8'hFF); send_ld(8'hF7);
        prog[pc] = op(R, 16'hC020, 8'h50, 8'hFF); pc = pc + 1;
        prog[pc] = op(WAIT, 16'd800, 8'h00, 8'h00); pc = pc + 1;   // ~0.2 s (12 fields)
        prog[pc] = op(R, 16'hC020, 8'hD0, 8'hFF); pc = pc + 1;
        // play
        send_ld(8'hFF); send_ld(8'hFD); send_ld(8'hFF);
        prog[pc] = op(R, 16'hC020, 8'hE4, 8'hFF); pc = pc + 1;
        prog[pc] = op(WAIT, 16'd400, 8'h00, 8'h00); pc = pc + 1;
        prog[pc] = op(END, 16'h0000, 8'h00, 8'h00); pc = pc + 1;
        pc = 0;
    end

    wire [1:0]  k    = prog[pc][35:34];
    wire [15:0] addr = prog[pc][33:18];
    wire [7:0]  dat  = prog[pc][17:10];
    wire [7:0]  msk  = prog[pc][9:2];

    always @(posedge CLK) begin
        if (!RESET_n) begin
            t <= 3'd0; M1_n <= 1'b1; MREQ_n <= 1'b1; IORQ_n <= 1'b1;
            RD_n <= 1'b1; WR_n <= 1'b1; A <= 16'h0000; DO <= 8'h00; wait_cnt <= 20'd0;
        end else if (CEN) begin
            case (k)
            END: if (!done) begin
                done = 1'b1;
                $display("  BFM: %0d reads checked, %0d failed", checks, fails);
                if (fails != 0) $fatal(1, "board bus test failed");
                $finish;
            end
            WAIT: begin
                wait_cnt <= wait_cnt + 20'd1;
                if (wait_cnt == {addr[9:0], 10'd0}) begin wait_cnt <= 20'd0; pc <= pc + 8'd1; end
            end
            default: begin
                t <= t + 3'd1;
                case (t)
                3'd0: begin A <= addr; DO <= dat; end
                3'd1: begin MREQ_n <= 1'b0; if (k == R) RD_n <= 1'b0; else WR_n <= 1'b0; end
                3'd3: if (k == R) begin
                          checks = checks + 1;
                          if ((DI & msk) != (dat & msk)) begin
                              fails = fails + 1;
                              $display("  [FAIL] read %04X = %02X, expected %02X (mask %02X)", addr, DI, dat, msk);
                          end else
                              $display("  [ ok ] read %04X = %02X", addr, DI);
                      end
                3'd4: begin MREQ_n <= 1'b1; RD_n <= 1'b1; WR_n <= 1'b1; t <= 3'd0; pc <= pc + 8'd1; end
                default: ;
                endcase
            end
            endcase
        end
    end

    wire _unused = &{1'b0, WAIT_n, INT_n, NMI_n, BUSRQ_n, OUT0};
endmodule
