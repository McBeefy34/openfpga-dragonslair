// Board-level test: dlair_top with a bus-functional CPU (stubs/T80s_bfm.v)
// replaying reads/writes. Checks decode, inputs, DIPs via the AY, the
// scoreboard latches and an LD-V1000 search + play over the real handshake.
//   make -C sim board
#include "Vdlair_top.h"
#include "Vdlair_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vdlair_top* dut;
static uint64_t sys_cycles = 0;
static int failures = 0;

static void check(bool ok, const char* what) {
    printf("  [%s] %s\n", ok ? " ok " : "FAIL", what);
    if (!ok) failures++;
}

// clk_sys = 4 x clk_vid, phase aligned
static void tick() {
    for (int h = 0; h < 2; h++) {
        dut->clk_sys = h;
        dut->rom_clk = h;
        if (h == 1 && (sys_cycles & 3) == 0) dut->clk_vid = 1;
        if (h == 1 && (sys_cycles & 3) == 2) dut->clk_vid = 0;
        dut->eval();
    }
    sys_cycles++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vdlair_top;
    dut->reset_sys = 1; dut->reset_vid = 1; dut->rom_loaded = 0;
    dut->dsw1 = 0x20; dut->dsw2 = 0x79;
    for (int i = 0; i < 32; i++) tick();
    dut->reset_sys = 0; dut->reset_vid = 0;

    // load ROM words (big-endian): 0000: 11 22 33 44, 7FFC: 00 00 00 A5
    dut->rom_wr = 1;
    dut->rom_wr_addr = 0;      dut->rom_wr_data = 0x11223344; tick();
    dut->rom_wr_addr = 0x1FFF; dut->rom_wr_data = 0x000000A5; tick();
    dut->rom_wr = 0;
    dut->rom_loaded = 1;
    dut->btn_up = 1; dut->btn_coin1 = 1;

    printf("board bus test\n");
    while (!Verilated::gotFinish() && sys_cycles < 24750000ULL * 2) tick();
    check(Verilated::gotFinish(), "BFM program ran to the end");

    auto* r = dut->rootp;
    uint64_t leds = r->dlair_top__DOT__led_digits;
    check(((leds >> 8) & 0xF) == 7, "scoreboard digit 2 = 7");
    check(((leds >> 56) & 0xF) == 1 && ((leds >> 60) & 0xF) == 3, "credits digits 14,15 = 1,3");
    check(((leds >> 0) & 0xF) == 0xF, "untouched digits stay blank");
    unsigned frame = r->dlair_top__DOT__ld_frame;
    unsigned mode = r->dlair_top__DOT__ld_mode;
    printf("  LD-V1000 frame %u, mode %u, cmds %u\n", frame, mode, r->dlair_top__DOT__ld_cmd_count);
    check(mode == 1 && frame > 42 && frame < 60, "searched to 42, now playing past it");
    check(r->dlair_top__DOT__ld_target_bcd == 0x00042, "target 00042");
    // BCD converter lags by up to 17 cycles; run a little and compare exactly
    for (int i = 0; i < 64; i++) tick();
    frame = r->dlair_top__DOT__ld_frame;
    unsigned want = (frame / 10000) << 16 | (frame / 1000 % 10) << 12 | (frame / 100 % 10) << 8 |
                    (frame / 10 % 10) << 4 | (frame % 10);
    check(r->dlair_top__DOT__frame_bcd == want, "double-dabble BCD matches frame number");

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures, failures == 1 ? "" : "s");
    dut->final();
    delete dut;
    return failures ? 1 : 0;
}
