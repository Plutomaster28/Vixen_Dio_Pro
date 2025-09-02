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
set DESIGN_NAME "vixen_dio_pro"
set TOP_MODULE "vixen_dio_pro"
set VERILOG_FILES [list \
    "rtl/vixen_dio_pro.sv" \
    "rtl/core/vixen_frontend.sv" \
    "rtl/core/vixen_rename_rob.sv" \
    "rtl/core/vixen_issue_queue.sv" \
    "rtl/core/vixen_branch_predictor.sv" \
    "rtl/core/vixen_trace_cache.sv" \
    "rtl/core/vixen_smt_manager.sv" \
    "rtl/execution/vixen_execution_cluster.sv" \
    "rtl/execution/vixen_agu_mul_div.sv" \
    "rtl/fpu/vixen_fpu.sv" \
    "rtl/cache/vixen_l1_cache.sv" \
    "rtl/cache/vixen_l2_l3_cache.sv" \
]

# Clock Configuration
set CLOCK_PERIOD 0.294  ;# 3.4 GHz target (294 ps)
set CLOCK_PORT "clk"
set CLOCK_UNCERTAINTY 0.05
set CLOCK_TRANSITION 0.1

# Minimum acceptable frequencies
set MIN_CLOCK_PERIOD 0.909   ;# 1.1 GHz minimum (909 ps)
set ABS_MIN_CLOCK_PERIOD 1.43 ;# 700 MHz absolute minimum (1430 ps)

# Die Configuration (targeting ~240 mm² like original Gallatin)
set DIE_AREA "15400 15400"  ;# 15.4mm x 15.4mm = ~237 mm²
set CORE_AREA "14000 14000" ;# Core area with margins

# Utilization targets
set CORE_UTILIZATION 0.65   ;# 65% core utilization
set PLACEMENT_DENSITY 0.70  ;# 70% placement density

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

puts "Vixen Dio Pro OpenROAD configuration loaded successfully"
puts "Target frequency: ${TARGET_FREQUENCY_GHZ} GHz"
puts "Die area: ${DIE_AREA} (targeting ~240 mm²)"
puts "Process: ${PROCESS_NODE}nm"
