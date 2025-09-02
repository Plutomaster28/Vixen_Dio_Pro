// =============================================================================
// Vixen Dio Pro L1 Cache Blackbox Models
// =============================================================================
// Blackbox implementations for synthesis without memory arrays
// These maintain the same interface but provide dummy functionality
// =============================================================================

module vixen_l1_icache #(
    parameter int CACHE_SIZE = 32*1024,    // 32KB
    parameter int LINE_SIZE = 64,           // 64-byte cache lines
    parameter int ASSOCIATIVITY = 4,        // 4-way set associative
    parameter int NUM_SETS = CACHE_SIZE / (LINE_SIZE * ASSOCIATIVITY)
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // CPU interface
    input  logic [63:0] addr,
    output logic [511:0] data_out,  // 8 cache lines worth for wide fetch
    output logic        hit,
    input  logic        req,
    output logic        ready,
    
    // L2 interface
    output logic        l2_req,
    output logic [63:0] l2_addr,
    input  logic [511:0] l2_data,
    input  logic        l2_ack,
    
    // Performance counters
    output logic [31:0] perf_hits,
    output logic [31:0] perf_misses
) /* synthesis syn_black_box */;

    // Blackbox - synthesis tool will not look inside
    // Dummy assignments to prevent synthesis warnings
    assign data_out = l2_data;
    assign hit = req;  // Always hit for testing
    assign ready = 1'b1;
    assign l2_req = req;
    assign l2_addr = addr;
    assign perf_hits = 32'h0;
    assign perf_misses = 32'h0;

endmodule

// =============================================================================

module vixen_l1_dcache #(
    parameter int CACHE_SIZE = 32*1024,    // 32KB
    parameter int LINE_SIZE = 64,           // 64-byte cache lines
    parameter int ASSOCIATIVITY = 4,        // 4-way set associative
    parameter int NUM_SETS = CACHE_SIZE / (LINE_SIZE * ASSOCIATIVITY)
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Load interface
    input  logic [63:0] load_addr,
    output logic [63:0] load_data,
    input  logic        load_req,
    output logic        load_ack,
    
    // Store interface
    input  logic [63:0] store_addr,
    input  logic [63:0] store_data,
    input  logic        store_req,
    output logic        store_ack,
    
    // Load/Store enable
    input  logic        load_enable,
    input  logic        store_enable,
    
    // Cache status
    output logic        hit,
    
    // L2 interface
    output logic        l2_req,
    output logic [63:0] l2_addr,
    output logic [511:0] l2_wdata,
    input  logic [511:0] l2_rdata,
    output logic        l2_we,
    input  logic        l2_ack,
    
    // Performance counters (split for load/store)
    output logic [31:0] perf_hits,
    output logic [31:0] perf_misses,
    output logic [31:0] perf_load_hits,
    output logic [31:0] perf_load_misses,
    output logic [31:0] perf_store_hits,
    output logic [31:0] perf_store_misses
) /* synthesis syn_black_box */;

    // Blackbox - synthesis tool will not look inside
    // Dummy assignments to prevent synthesis warnings
    assign load_data = {load_addr[63:32], load_addr[31:0]};  // Echo back address as data
    assign load_ack = load_req;
    assign store_ack = store_req;
    assign hit = load_req | store_req;  // Always hit for testing
    assign l2_req = load_req | store_req;
    assign l2_addr = load_req ? load_addr : store_addr;
    assign l2_wdata = {8{store_data}};  // Replicate 64-bit to 512-bit
    assign l2_we = store_req;
    assign perf_hits = 32'h0;
    assign perf_misses = 32'h0;
    assign perf_load_hits = 32'h0;
    assign perf_load_misses = 32'h0;
    assign perf_store_hits = 32'h0;
    assign perf_store_misses = 32'h0;

endmodule
