# Vixen Dio Pro Multi-Die Synthesis Strategy

## Overview
Due to memory limitations during synthesis (3.6MB+ of cache memory structures), we've implemented a multi-die package approach similar to Intel's Pentium 4 Extreme Edition.

## Implementation Strategy

### Die 1: CPU Core (Current Synthesis Target)
**Files Modified:**
- `config.tcl` - Updated to use blackbox cache modules
- `rtl/cache/vixen_l1_cache_blackbox.sv` - Blackbox L1 cache implementation
- `rtl/cache/vixen_l2_l3_cache_blackbox.sv` - Blackbox L2/L3 cache implementation  
- `rtl/core/vixen_branch_predictor_blackbox.sv` - Simplified branch predictor

**Core Logic Included:**
- Frontend (fetch, decode)
- Execution units (ALU, FPU, AGU)
- ROB (48 entries) and Issue Queue (32 entries)
- SMT management
- Simplified caches (blackboxed)

**Memory Footprint:** ~500KB (manageable for synthesis)

### Die 2: Cache Subsystem (Future Synthesis)
**Configuration:** `config_cache.tcl`
**Files to be created:**
- `rtl/cache/vixen_cache_subsystem.sv` - Top-level cache module
- `rtl/memory/sram_wrappers.sv` - Memory compiler wrappers

**Cache Logic:**
- Full L1 I-Cache (32KB)
- Full L1 D-Cache (32KB) 
- Full L2 Cache (1MB)
- Full L3 Cache (2MB)
- Memory controllers

## Blackbox Module Functionality

### Cache Blackboxes
- Maintain exact same interface as original modules
- Provide simple pass-through or echo functionality
- Include basic pipeline delays for realism
- Use `/* synthesis syn_black_box */` directive

### Branch Predictor Blackbox
- Simplified 256-entry bimodal predictor
- Maintains interface compatibility
- Provides basic prediction functionality

## Synthesis Process

### Phase 1: Core Synthesis (Current)
```bash
# Use updated config.tcl with blackbox modules
# Should complete synthesis without memory exhaustion
```

### Phase 2: Cache Synthesis (Future)
```bash
# Use config_cache.tcl for cache-specific synthesis
# Utilize memory compilers for large SRAM blocks
```

### Phase 3: Integration
- Package both dies together
- Define inter-die communication protocol
- Implement cache coherency between dies

## Benefits
1. **Memory Management:** Avoids synthesis memory exhaustion
2. **Modular Design:** Separate optimization of core vs cache
3. **Realistic Architecture:** Matches P4 EE multi-die approach
4. **Scalability:** Can independently upgrade either die

## Files Modified
- `config.tcl` - Core synthesis configuration
- `rtl/cache/vixen_l1_cache_blackbox.sv` - L1 cache blackbox
- `rtl/cache/vixen_l2_l3_cache_blackbox.sv` - L2/L3 cache blackbox
- `rtl/core/vixen_branch_predictor_blackbox.sv` - Branch predictor blackbox
- `config_cache.tcl` - Cache synthesis configuration (future use)
- `test_core_synthesis.ys` - Core synthesis test script

## Next Steps
1. Test core synthesis with blackboxed caches
2. Verify core logic functionality
3. Design inter-die communication interface
4. Implement cache subsystem synthesis
