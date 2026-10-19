# Verilator tests for the Verilog parts of the core.
#   make -C sim            run everything
#   make -C sim ldv1000    LD-V1000 protocol test
#   make -C sim video      render test-screen frames to PPM
#   make -C sim board      board decode + LD handshake with a scripted bus master
VERILATOR ?= verilator
RTL  := ../src/fpga/rtl
FLAGS := -Wno-WIDTH -Wno-BLKSEQ -Wno-fatal --build -j 0 -O2

all: ldv1000 video board

ldv1000:
	$(VERILATOR) --cc --exe $(FLAGS) --top-module ldv1000_hle \
		--Mdir obj_ldv1000 $(RTL)/ldv1000_hle.v tb_ldv1000.cpp
	./obj_ldv1000/Vldv1000_hle

video:
	$(VERILATOR) --cc --exe $(FLAGS) --top-module ld_testvideo \
		--Mdir obj_video $(RTL)/ld_testvideo.v $(RTL)/dl_text.v $(RTL)/dl_font.v tb_video.cpp
	./obj_video/Vld_testvideo

board:
	$(VERILATOR) --cc --exe $(FLAGS) --public-flat-rw --top-module dlair_top \
		--Mdir obj_board $(RTL)/dlair_top.v $(RTL)/dlair_board.v $(RTL)/ldv1000_hle.v \
		$(RTL)/ld_testvideo.v $(RTL)/dl_text.v $(RTL)/dl_font.v $(RTL)/jt49/*.v \
		stubs/T80s_bfm.v tb_board.cpp
	./obj_board/Vdlair_top

clean:
	rm -rf obj_* *.ppm

.PHONY: all ldv1000 video board clean
