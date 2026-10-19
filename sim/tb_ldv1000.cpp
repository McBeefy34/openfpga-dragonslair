// Verilator testbench for ldv1000_hle: drives the LD-V1000 protocol the
// way the Dragon's Lair board does and checks the player's responses.
//
//   make -C sim ldv1000
#include "Vldv1000_hle.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>

static Vldv1000_hle* dut;
static uint64_t cycles = 0;
static uint64_t us = 0;
static int failures = 0;
static const int CLK_PER_US = 24;           // close enough for protocol tests
static const int US_PER_FIELD = 16683;       // 59.94 Hz
static int field_us = 0;
static int fields = 0;

// strobe observers
static int status_low_len = 0, cmd_high_len = 0;
static int last_status_low = 0, last_cmd_high = 0;
static int64_t last_status_fall_us = -1, last_cmd_rise_us = -1;
static int64_t last_field_us = -1;
static int64_t strobe_after_field = -1;
static int strobe_count = 0;
static int64_t prev_status_fall = -1;
static int64_t strobe_period = -1;

static void check(bool ok, const char* what) {
    printf("  [%s] %s\n", ok ? " ok " : "FAIL", what);
    if (!ok) failures++;
}

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    cycles++;
}

// run one microsecond: one ce_1us pulse, field_start when due
static void step_us() {
    for (int c = 0; c < CLK_PER_US; c++) {
        dut->ce_1us = (c == 0);
        dut->field_start = (c == 1 && field_us == 0);
        if (dut->field_start) { last_field_us = us; fields++; }
        dut->data_wr = 0;
        tick();
    }
    dut->ce_1us = 0;
    dut->field_start = 0;
    us++;
    field_us = (field_us + 1) % US_PER_FIELD;

    // strobe timing
    bool sl = !dut->status_strobe, ch = dut->cmd_strobe;
    if (sl) status_low_len++;
    else if (status_low_len) { last_status_low = status_low_len; status_low_len = 0; }
    if (sl && status_low_len == 1) {
        last_status_fall_us = us;
        strobe_count++;
        if (prev_status_fall >= 0) strobe_period = us - prev_status_fall;
        prev_status_fall = us;
        if (last_field_us >= 0) strobe_after_field = us - last_field_us;
    }
    if (ch) cmd_high_len++;
    else if (cmd_high_len) { last_cmd_high = cmd_high_len; cmd_high_len = 0; }
    if (ch && cmd_high_len == 1) last_cmd_rise_us = us;
}

static void run_us(int n) { for (int i = 0; i < n; i++) step_us(); }
static void run_fields(int n) { for (int i = 0; i < n; i++) run_us(US_PER_FIELD); }

static void send(uint8_t b) {
    dut->data_in = b;
    dut->data_wr = 1;
    tick();
    dut->data_wr = 0;
    run_us(100);
}

static const uint8_t DIGIT[10] = {0x3F,0x0F,0x8F,0x4F,0x2F,0xAF,0x6F,0x1F,0x9F,0x5F};

// the game's pattern: no-entry before every key so the player accepts it
static void key(uint8_t b) { send(0xFF); send(b); }
static void number(const char* s) { for (; *s; s++) key(DIGIT[*s - '0']); }

static const char* MODES[] = {"PARK","PLAY","SCANF","SCANR","SEARCH","STOP"};
static void show(const char* label) {
    printf("  %-28s status=%02X mode=%-6s frame=%u\n", label, dut->status,
           MODES[dut->mode], dut->frame);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vldv1000_hle;
    dut->reset = 1; for (int i = 0; i < 10; i++) tick(); dut->reset = 0;

    printf("reset / park\n");
    check(dut->status == 0xFC, "status after reset is 0xFC (park | ready)");
    check(dut->mode == 0, "mode is PARK");
    run_us(50000);
    check(strobe_period == 21000, "parked: strobes every 21 ms");
    check(last_status_low == 26, "status strobe low for 26 us");
    check(last_cmd_high == 25, "command strobe high for 25 us");
    check(last_cmd_rise_us - last_status_fall_us == 54, "command strobe 54 us after status strobe");

    printf("search to frame 1234\n");
    number("1234");
    key(0xF7);
    show("after SEARCH");
    check(dut->status == 0x50, "status 0x50 (search) right after command");
    check(dut->mode == 4, "mode SEARCH");
    check(dut->video_on == 0, "video squelched while seeking");
    send(0xFF);
    check(dut->status == 0xD0, "no-entry sets ready bit -> 0xD0 (same as MAME HLE)");
    run_fields(14);
    show("after seek");
    check(dut->frame == 1234, "landed on frame 1234");
    check(dut->mode == 5 && dut->status == 0xD0, "still frame, status 0xD0 (search finish)");
    check(dut->target_bcd == 0x01234, "target shown as BCD 01234");

    printf("play\n");
    key(0xFD);
    check(dut->status == 0x64, "status 0x64 (play)");
    send(0xFF);
    check(dut->status == 0xE4, "after no-entry 0xE4");
    unsigned f0 = dut->frame;
    run_fields(60);
    show("after 60 fields");
    check(dut->frame - f0 == 30, "30 frames per 60 fields");
    check(dut->audio_on_l && dut->audio_on_r && dut->video_on, "audio + video on at 1x");
    run_fields(2);
    printf("  (status strobe fell %lld us after field start)\n", (long long)strobe_after_field);
    check(strobe_after_field >= 500 && strobe_after_field <= 502, "playing: strobe ~500 us after field start");

    printf("repeat key without no-entry is ignored\n");
    send(0xFB);                      // stop, accepted (ready was set)
    unsigned fs = dut->frame;
    check(dut->status == 0x65 && dut->mode == 5, "STOP accepted -> 0x65 still");
    send(0xFD);                      // play without no-entry first
    check(dut->mode == 5, "PLAY without no-entry ignored");
    run_fields(10);
    check(dut->frame == fs, "frame frozen while stopped");

    printf("timed stop resumes play\n");
    key(0xFD);
    number("15");                    // 1.5 s
    key(0xFB);
    show("after STOP 1.5s");
    check(dut->mode == 5, "stopped");
    run_us(1400000);
    check(dut->mode == 5, "still stopped at 1.4 s");
    run_us(200000);
    show("at 1.6 s");
    check(dut->mode == 1, "playing again at 1.6 s");

    printf("autostop\n");
    unsigned now = dut->frame;
    char buf[8]; snprintf(buf, sizeof buf, "%u", now + 40);
    number(buf);
    key(0xF3);
    check(dut->status == 0x54, "status 0x54 (autostop)");
    run_fields(120);
    show("after autostop");
    check(dut->frame == now + 40 && dut->mode == 5, "stopped exactly on target");

    printf("step / audio / reject\n");
    unsigned s0 = dut->frame;
    key(0xF6);
    check(dut->frame == s0 + 1, "step forward +1");
    key(0xFE);
    check(dut->frame == s0, "step reverse -1");
    key(0xF4);
    key(0xFD);
    check(!dut->audio_on_l && dut->audio_on_r, "AUDIO1 toggles left channel off");
    key(0xF9);
    check(dut->mode == 0 && dut->status == 0x7C, "REJECT parks the disc");

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures,
           failures == 1 ? "" : "s");
    delete dut;
    return failures ? 1 : 0;
}
