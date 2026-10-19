#
# Dragon's Lair core constraints
#
# clk_vid / clk_vid_90 / clk_sys all come from one PLL (dl_pll) and are
# related (clk_sys = 4 x clk_vid), so they stay in one group and Quartus
# times the paths between them. Everything else is asynchronous.
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|pll|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk }
