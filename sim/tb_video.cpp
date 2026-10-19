// Renders ld_testvideo frames to PPM images and checks the timing.
//   make -C sim video   ->  sim/screen_play.ppm, sim/screen_search.ppm, sim/screen_norom.ppm
#include "Vld_testvideo.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vld_testvideo* dut;
static int failures = 0;

static void check(bool ok, const char* what) {
    printf("  [%s] %s\n", ok ? " ok " : "FAIL", what);
    if (!ok) failures++;
}

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

// capture one full frame starting at the next vs pulse
static bool capture(const char* path) {
    std::vector<uint32_t> img(320 * 240, 0);
    int guard = 0;
    while (!dut->vs) { tick(); if (++guard > 400000) return false; }
    int x = 0, y = 0, de_count = 0, lines = 0, hs_count = 0;
    bool prev_de = false;
    long clocks = 0;
    do {
        tick();
        clocks++;
        if (dut->hs) hs_count++;
        if (dut->de) {
            if (x < 320 && y < 240) img[y * 320 + x] = dut->rgb;
            x++; de_count++;
        } else if (prev_de) {
            x = 0; y++; lines++;
        }
        prev_de = dut->de;
    } while (!dut->vs);
    printf("  %s: %ld clocks/frame, %d active lines, %d hs pulses\n", path, clocks, lines, hs_count);
    check(clocks == 394L * 262L, "frame is 394 x 262 clocks (59.94 Hz at 6.1875 MHz)");
    check(lines == 240 && de_count == 320 * 240, "320 x 240 active pixels");
    check(hs_count == 262, "one hs per line");
    FILE* f = fopen(path, "wb");
    fprintf(f, "P6\n320 240\n255\n");
    for (uint32_t p : img) { fputc(p >> 16, f); fputc((p >> 8) & 0xff, f); fputc(p & 0xff, f); }
    fclose(f);
    return true;
}

static void set_leds(const char* s16) {
    // s16 lists digits 0..15, '-' for blank
    uint64_t v = 0;
    for (int i = 0; i < 16; i++) {
        uint64_t c = (s16[i] == '-') ? 0xF : (uint64_t)(s16[i] - '0');
        v |= c << (i * 4);
    }
    dut->led_digits = v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vld_testvideo;
    dut->reset = 1; for (int i = 0; i < 10; i++) tick(); dut->reset = 0;

    printf("playing, frame 1234\n");
    dut->rom_loaded = 1;
    dut->mode = 1; dut->video_on = 1; dut->status = 0xE4; dut->last_cmd = 0xFD;
    dut->cmd_count = 0x2A; dut->frame_bcd = 0x01234; dut->frame_bin = 1234;
    dut->target_bcd = 0x01234; dut->audio_l = 1; dut->audio_r = 0;
    //        P1 score  L L P2 score    credits
    set_leds("001250" "3" "5" "000000" "02");
    // digit 6 = P1 lives, 7 = P2 lives, 8-13 = P2 score, 14-15 credits
    check(capture("screen_play.ppm"), "captured");

    printf("seeking\n");
    dut->mode = 4; dut->video_on = 0; dut->status = 0x50; dut->last_cmd = 0xF7;
    dut->target_bcd = 0x05678;
    check(capture("screen_search.ppm"), "captured");

    printf("no ROM loaded, parked\n");
    dut->rom_loaded = 0; dut->mode = 0; dut->status = 0xFC; dut->frame_bcd = 0; dut->frame_bin = 0;
    set_leds("----------------");
    check(capture("screen_norom.ppm"), "captured");

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures,
           failures == 1 ? "" : "s");
    delete dut;
    return failures ? 1 : 0;
}
