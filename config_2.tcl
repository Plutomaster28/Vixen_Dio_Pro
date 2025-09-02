# =============================================================================
# OpenLane Configuration for Vixen Dio Pro - Bare Core
# =============================================================================
# Lightweight configuration for core-only synthesis (no cache)
# Should synthesize much faster and use less memory
# =============================================================================

set ::env(DESIGN_NAME) vixen_core_bare
set ::env(DESIGN_IS_CORE) 0

# Source files - bare core only (no cache modules)
set ::env(VERILOG_FILES) [glob $::env(DESIGN_DIR)/rtl_2/*.sv \
                              $::env(DESIGN_DIR)/rtl_2/core/*.sv \
                              $::env(DESIGN_DIR)/rtl_2/execution/*.sv \
                              $::env(DESIGN_DIR)/rtl_2/fpu/*.sv]

# Clock configuration
set ::env(CLOCK_PORT) "clk"
set ::env(CLOCK_NET) $::env(CLOCK_PORT)
set ::env(CLOCK_PERIOD) "10.0"  # 100 MHz

# Design size - much smaller without cache
set ::env(FP_SIZING) absolute
set ::env(DIE_AREA) "0 0 800 800"   # Smaller die for bare core
set ::env(FP_CORE_UTIL) 40           # Higher utilization since smaller

# Floorplan
set ::env(FP_ASPECT_RATIO) 1
set ::env(FP_CORE_MARGIN) 2
set ::env(FP_IO_MARGIN) 10

# Placement
set ::env(PL_BASIC_PLACEMENT) 1
set ::env(PL_TARGET_DENSITY) 0.45    # Slightly denser for smaller core
set ::env(PL_RANDOM_GLB_PLACEMENT) 1

# Synthesis optimizations for bare core
set ::env(SYNTH_STRATEGY) "AREA 0"
set ::env(SYNTH_BUFFERING) 1
set ::env(SYNTH_SIZING) 1
set ::env(SYNTH_DRIVING_CELL) "sky130_fd_sc_hd__inv_8"

# CTS
set ::env(CTS_TARGET_SKEW) 200
set ::env(CTS_TOLERANCE) 100

# Routing
set ::env(RT_MAX_LAYER) 6
set ::env(ROUTING_CORES) 4

# LVS/DRC
set ::env(RUN_KLAYOUT_XOR) 0
set ::env(RUN_KLAYOUT_DRC) 1

# Magic
set ::env(MAGIC_ZEROIZE_ORIGIN) 0
set ::env(MAGIC_GENERATE_LEF) 1
set ::env(MAGIC_GENERATE_GDS) 1

# PDN
set ::env(FP_PDN_CORE_RING) 1
set ::env(FP_PDN_CORE_RING_VWIDTH) 3.1
set ::env(FP_PDN_CORE_RING_HWIDTH) 3.1
set ::env(FP_PDN_CORE_RING_VOFFSET) 14
set ::env(FP_PDN_CORE_RING_HOFFSET) 14
set ::env(FP_PDN_CORE_RING_VSPACING) 1.7
set ::env(FP_PDN_CORE_RING_HSPACING) 1.7

set ::env(FP_PDN_VWIDTH) 3.1
set ::env(FP_PDN_HWIDTH) 3.1
set ::env(FP_PDN_VOFFSET) 16.65
set ::env(FP_PDN_HOFFSET) 16.65
set ::env(FP_PDN_VPITCH) 153.6
set ::env(FP_PDN_HPITCH) 153.18

# Fill
set ::env(FILL_INSERTION) 1
set ::env(TAP_DECAP_INSERTION) 1

# Meta
set ::env(QUIT_ON_LVS_ERROR) 0
set ::env(QUIT_ON_MAGIC_DRC) 0
set ::env(QUIT_ON_SLEW_VIOLATIONS) 0
set ::env(QUIT_ON_TIMING_VIOLATIONS) 0
