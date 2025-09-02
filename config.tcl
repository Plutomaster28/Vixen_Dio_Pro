# =============================================================================
# Vixen Dio Pro - OpenROAD Configuration File
# =============================================================================
# Configuration for synthesizing the Vixen Dio Pro processor using OpenROAD
# Target: 130nm process technology
# =============================================================================

# Process Technology Configuration
set TECH_LEF "sky130_fd_sc_hd.tlef"
set TECH_LIB "sky130_fd_sc_hd__typical.lib"
set PROCESS_NODE "130"

# Design Configuration  
# Using ultra-minimal bare core design for fast synthesis
# This gives us basic functionality with minimal I/O pins
set DESIGN_NAME "vixen_core_bare"
set TOP_MODULE "vixen_core_bare"
set VERILOG_FILES [list \
    "$::env(DESIGN_DIR)/rtl_2/vixen_core_bare.sv" \
]

# OpenLane Environment Variables (required by OpenLane)
set ::env(DESIGN_NAME) $DESIGN_NAME
set ::env(VERILOG_FILES) $VERILOG_FILES

# Clock Configuration
set CLOCK_PERIOD 0.294  ;# 3.4 GHz target (294 ps)
set CLOCK_PORT "clk"
set CLOCK_UNCERTAINTY 0.05
set CLOCK_TRANSITION 0.1

# OpenLane Clock Configuration
set ::env(CLOCK_PERIOD) $CLOCK_PERIOD
set ::env(CLOCK_PORT) $CLOCK_PORT

# Minimum acceptable frequencies
set MIN_CLOCK_PERIOD 0.909   ;# 1.1 GHz minimum (909 ps)
set ABS_MIN_CLOCK_PERIOD 1.43 ;# 700 MHz absolute minimum (1430 ps)

# Die Configuration (small but adequate for I/O placement)
set DIE_AREA "10000 10000"  ;# 10mm x 10mm = ~100 mm² (minimal but I/O-friendly)
set CORE_AREA "8000 8000"   ;# Core area with margins for I/O ring

# OpenLane Die Configuration
set ::env(DIE_AREA) "0 0 $DIE_AREA"
set ::env(FP_CORE_UTIL) 40  ;# Higher utilization for smaller core

# Utilization targets  
set CORE_UTILIZATION 0.45   ;# 45% core utilization (higher since no cache)
set PLACEMENT_DENSITY 0.60  ;# 60% placement density (denser for core only)

# Power Configuration
set POWER_NETS "VDD"
set GROUND_NETS "VSS"

# I/O Configuration
set IO_CONSTRAINTS "constraints/vixen_dio_pro_io.sdc"

# Floorplan Configuration
set ASPECT_RATIO 1.0
set CORE_MARGIN 100   ;# 100 micron margin around core

# Placement Configuration
set PLACE_DENSITY $PLACEMENT_DENSITY
set GPL_CELL_PADDING 2
set DPL_CELL_PADDING 1

# CTS (Clock Tree Synthesis) Configuration  
set CTS_BUF_CELL "sky130_fd_sc_hd__clkbuf_4"
set CTS_CLOCK_BUFFER_MAX_SLEW 1.5
set CTS_CLOCK_BUFFER_MAX_CAP 0.3

# Routing Configuration
set GLOBAL_ROUTE_GUIDE_FILE ""
set DETAILED_ROUTE_GUIDE_FILE ""
set MIN_ROUTE_LAYER 1
set MAX_ROUTE_LAYER 6

# Liberty and Technology Files
set LIB_FILES [list \
    "lib/sky130_fd_sc_hd__typical.lib" \
    "lib/sky130_fd_sc_hd__slow.lib" \
    "lib/sky130_fd_sc_hd__fast.lib" \
]

set LEF_FILES [list \
    "lef/sky130_fd_sc_hd.tlef" \
    "lef/sky130_fd_sc_hd_merged.lef" \
]

# Design Rule Check (DRC) Configuration
set DRC_EXCLUDE_CELL_LIST ""

# Timing Constraints
set SDC_FILE "constraints/vixen_dio_pro.sdc"

# Power Analysis Configuration  
set ENABLE_POWER_ANALYSIS 1
set POWER_ANALYSIS_MODE "averaged"

# Multi-Threading Configuration for OpenROAD
set NUM_CORES [exec nproc]
set MAX_THREADS [expr min($NUM_CORES, 8)]

# Memory Configuration (for large design)
set MAX_MEMORY "16GB"

# Optimization Targets
set OPTIMIZE_FOR "frequency"  ;# Can be "area", "power", or "frequency"
set TARGET_FREQUENCY_GHZ 3.4

# Advanced Configuration
set ENABLE_MACRO_PLACEMENT 1
set ENABLE_HIERARCHICAL_DESIGN 1

# Cache and Memory Block Configuration
set SRAM_LEF_FILE "memory/sram_cache.lef"
set SRAM_LIB_FILE "memory/sram_cache.lib"

# Verification Configuration
set ENABLE_FORMAL_VERIFICATION 0
set ENABLE_GATE_LEVEL_SIMULATION 1

# Output Configuration
set RESULT_DIR "results"
set LOG_DIR "logs"
set REPORT_DIR "reports"

# Flow Control
set SKIP_GATE_CLONING 0
set SKIP_BUFFER_INSERTION 0
set ENABLE_CLOCK_GATING 1

# Debug Configuration
set DEBUG_LEVEL 1  ;# 0=minimal, 1=normal, 2=verbose
set SAVE_INTERMEDIATE_RESULTS 1

# Pentium 4 Inspired Optimizations
set ENABLE_DEEP_PIPELINE_OPT 1     ;# Optimize for deep 20-stage pipeline
set ENABLE_TRACE_CACHE_OPT 1       ;# Special handling for trace cache
set ENABLE_SMT_AWARE_PLACEMENT 1   ;# SMT-aware placement
set ENABLE_CACHE_HIERARCHY_OPT 1   ;# Optimize cache hierarchy layout

# Process-specific optimizations for 130nm
set ENABLE_130NM_OPTIMIZATIONS 1
set WIRE_DELAY_MODEL "lumped"
set METAL_LAYER_COUNT 6
set VIA_INSERTION_EFFORT "high"

puts "Vixen Dio Pro Ultra-Minimal Core configuration loaded successfully"
puts "Target frequency: ${TARGET_FREQUENCY_GHZ} GHz"
puts "Die area: ${DIE_AREA} (targeting ~100 mm² with I/O friendly layout)"
puts "Process: ${PROCESS_NODE}nm"
puts "Design: Ultra-minimal test core with basic arithmetic (3 I/O pins)"
