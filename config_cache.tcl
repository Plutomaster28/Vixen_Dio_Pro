# =============================================================================
# Vixen Dio Pro Cache Synthesis Configuration
# =============================================================================
# Separate synthesis configuration for cache modules using memory compilers
# This will be used after core synthesis completes
# =============================================================================

# Design Configuration for Cache Synthesis
set DESIGN_NAME "vixen_cache_subsystem" 
set TOP_MODULE "vixen_cache_subsystem"

# Cache-specific synthesis files (will be created later)
set VERILOG_FILES [list \
    "$::env(DESIGN_DIR)/rtl/cache/vixen_cache_subsystem.sv" \
    "$::env(DESIGN_DIR)/rtl/cache/vixen_l1_cache.sv" \
    "$::env(DESIGN_DIR)/rtl/cache/vixen_l2_l3_cache.sv" \
    "$::env(DESIGN_DIR)/rtl/memory/sram_wrappers.sv" \
]

# OpenLane Environment Variables
set ::env(DESIGN_NAME) $DESIGN_NAME
set ::env(VERILOG_FILES) $VERILOG_FILES

# Cache-optimized clock configuration (can be slower)
set CACHE_CLOCK_PERIOD 0.5  ;# 2 GHz for cache (slower than core)
set ::env(CLOCK_PERIOD) $CACHE_CLOCK_PERIOD
set ::env(CLOCK_PORT) "clk"

# Cache die configuration (smaller area focused on memory)
set CACHE_DIE_AREA "8000 8000"  ;# 8mm x 8mm for cache die
set ::env(DIE_AREA) "0 0 $CACHE_DIE_AREA"
set ::env(FP_CORE_UTIL) 70  ;# Higher utilization for memory-focused design

# Memory-specific optimizations
set ENABLE_MEMORY_COMPILER 1
set USE_SRAM_MACROS 1
set CACHE_MEMORY_TYPE "1RW"  ;# Single-port read/write for caches

# Cache hierarchy layout optimization
set ENABLE_CACHE_HIERARCHY_OPT 1
set CACHE_BANK_PLACEMENT "clustered"

puts "Cache subsystem synthesis configuration loaded"
puts "Target: Separate cache die for multi-die package"
puts "Cache die area: ${CACHE_DIE_AREA}"
