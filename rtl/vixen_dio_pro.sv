// =============================================================================
// Vixen Dio Pro - Intel Pentium 4 Extreme Edition Inspired x86-64 Processor
// =============================================================================
// Top-level module for the Vixen Dio Pro processor
// Target: 130nm process, 3.4 GHz (min 1.1 GHz, absolute min 700 MHz)
// Architecture: 1 physical core, 2 HT threads, 20-stage pipeline, 3-way superscalar
// =============================================================================

module vixen_dio_pro (
    // Clock and Reset
    input  logic        clk,
    input  logic        rst_n,
    
    // External Memory Interface (DDR)
    output logic [63:0] mem_addr,
    output logic [511:0] mem_wdata,
    input  logic [511:0] mem_rdata,
    output logic        mem_we,
    output logic        mem_req,
    input  logic        mem_ack,
    input  logic        mem_ready,
    
    // Interrupt and Exception Handling
    input  logic [7:0]  irq_vector,
    input  logic        nmi,
    input  logic        intr,
    
    // Debug Interface
    input  logic        debug_req,
    output logic        debug_ack,
    output logic [63:0] debug_pc_t0,
    output logic [63:0] debug_pc_t1,
    
    // Performance Counters
    output logic [31:0] perf_cycles,
    output logic [31:0] perf_instructions_t0,
    output logic [31:0] perf_instructions_t1,
    output logic [31:0] perf_cache_misses
);

    // =========================================================================
    // Parameters and Constants
    // =========================================================================
    
    localparam int XLEN = 64;                    // x86-64 architecture
    localparam int NUM_THREADS = 2;              // Hyper-Threading
    localparam int PIPELINE_STAGES = 20;         // Deep pipeline like P4
    localparam int ROB_ENTRIES = 48;             // Reorder buffer size
    localparam int IQ_ENTRIES = 32;              // Issue queue unified
    localparam int ISSUE_WIDTH = 3;              // 3-way superscalar
    
    // Cache parameters
    localparam int L1I_SIZE = 32*1024;           // 32KB L1 I-cache
    localparam int L1D_SIZE = 32*1024;           // 32KB L1 D-cache
    localparam int L2_SIZE = 1024*1024;          // 1MB L2 cache
    localparam int L3_SIZE = 2*1024*1024;        // 2MB L3 cache
    localparam int TRACE_CACHE_SIZE = 8*1024;    // 8KB trace cache
    
    // =========================================================================
    // Internal Signals
    // =========================================================================
    
    // Thread contexts
    logic [63:0] pc_t0, pc_t1;
    logic [NUM_THREADS-1:0] thread_active;
    logic [NUM_THREADS-1:0] thread_stalled;
    
    // Frontend signals
    logic [127:0] fetch_bundle;      // 4x 32-bit x86 instructions max
    logic         fetch_valid;
    logic [1:0]   fetch_thread_id;
    
    // Decode stage  
    logic [191:0] decoded_uops;     // 3 uops * 64 bits each
    logic [2:0]   decoded_valid;
    logic [5:0]   decoded_thread_id; // 3 uops * 2 bits each
    
    // Rename/ROB signals
    logic [47:0] rob_valid;
    logic [47:0] rob_ready;
    logic [5:0] rob_head, rob_tail;
    
    // Issue queue signals
    logic [31:0] iq_valid;
    logic [31:0] iq_ready;
    
    // Execution unit completion signals (stubs)
    logic [2:0] eu_complete;
    logic [17:0] eu_rob_id;    // 3 * 6 bits
    logic [191:0] eu_result;   // 3 * 64 bits
    logic [2:0] eu_wakeup_valid;
    logic [23:0] eu_wakeup_tag;
    
    // Branch resolution signals (stubs)
    logic branch_resolve;
    logic branch_mispredict;
    logic [5:0] branch_rob_id;
    logic [63:0] branch_target;
    
    // Retirement signals (stubs)
    logic [1:0] retire_valid;
    logic [127:0] retire_data;       // 2 * 64 bits
    logic [3:0] retire_thread_id;    // 2 * 2 bits
    
    // Exception signals (stubs)
    logic [1:0] exception_req;
    logic [15:0] exception_vector;   // 2 * 8 bits
    logic [1:0] exception_flush;
    
    // Issue signals (stubs)
    logic [191:0] rob_uops;          // 3 * 64 bits
    logic [2:0] rob_uop_valid;
    logic [5:0] rob_thread_id;       // 3 * 2 bits
    logic [17:0] rob_id;             // 3 * 6 bits
    logic [3:0] alu_issue_valid;
    logic [255:0] alu_issue_uop;         // 4 * 64 bits
    logic [23:0] alu_issue_rob_id;       // 4 * 6 bits
    logic [7:0] alu_issue_thread_id;     // 4 * 2 bits
    logic agu_issue_valid;
    logic [63:0] agu_issue_uop;
    logic [5:0] agu_issue_rob_id;
    logic [1:0] agu_issue_thread_id;
    logic mul_issue_valid;
    logic [63:0] mul_issue_uop;
    logic [5:0] mul_issue_rob_id;
    logic [1:0] mul_issue_thread_id;
    logic div_issue_valid;
    logic [63:0] div_issue_uop;
    logic [5:0] div_issue_rob_id;
    logic [1:0] div_issue_thread_id;
    logic [1:0] fpu_issue_valid;
    logic [127:0] fpu_issue_uop;         // 2 * 64 bits
    logic [11:0] fpu_issue_rob_id;       // 2 * 6 bits
    logic [3:0] fpu_issue_thread_id;     // 2 * 2 bits
    
    // Performance counters (stubs)
    logic [31:0] perf_issue_stalls;
    logic [31:0] perf_thread_stalls_0;  // Thread 0 stalls
    logic [31:0] perf_thread_stalls_1;  // Thread 1 stalls
    logic [31:0] perf_alu_ops;
    logic [31:0] perf_fpu_ops;
    logic [31:0] perf_mem_ops;
    
    // Execution unit busy signals (stubs)
    logic [3:0] eu_alu_busy;
    logic eu_mul_busy;
    logic eu_div_busy;
    logic [1:0] eu_fpu_busy;
    
    // Cache interface signals (stubs)
    logic l1i_hit, l1i_ready;
    logic [63:0] l1i_addr;
    logic [511:0] l1i_data;
    logic l1d_hit, l1d_ready;
    logic [63:0] l1d_addr, l1d_wdata, l1d_rdata;
    logic l1d_we;
    
    // L2 cache signals (stubs)
    logic l2_req, l2_ack;
    logic [63:0] l2_addr, l2_data;
    
    // L3 cache signals (stubs) 
    logic l3_req, l3_ack;
    logic [63:0] l3_addr, l3_wdata, l3_rdata;
    logic l3_we;
    
    // Performance counters for caches (stubs)
    logic [31:0] perf_l1i_hits, perf_l1i_misses;
    logic [31:0] perf_l1d_load_hits, perf_l1d_load_misses;
    logic [31:0] perf_l1d_store_hits, perf_l1d_store_misses;
    logic [31:0] perf_l2_hits, perf_l2_misses, perf_l2_writebacks;
    logic [31:0] perf_l3_hits, perf_l3_misses, perf_l3_writebacks;

    // =========================================================================
    // Stub Assignments for Missing Signals
    // =========================================================================
    
    // Initialize all stub signals to safe defaults
    assign eu_complete = 3'b0;
    assign eu_rob_id = 18'b0;
    assign eu_result = 192'b0;
    assign eu_wakeup_valid = 3'b0;
    assign eu_wakeup_tag = 24'b0;
    assign branch_resolve = 1'b0;
    assign branch_mispredict = 1'b0;
    assign branch_rob_id = 6'b0;
    assign branch_target = 64'b0;
    assign retire_valid = 2'b0;
    assign retire_data = 128'b0;
    assign retire_thread_id = 4'b0;
    assign exception_req = 2'b0;
    assign exception_vector = 16'b0;
    assign exception_flush = 2'b0;
    assign rob_uops = 192'b0;
    assign rob_uop_valid = 3'b0;
    assign rob_thread_id = 6'b0;
    assign rob_id = 18'b0;
    assign alu_issue_valid = 4'b0;
    assign alu_issue_uop = 256'b0;
    assign alu_issue_rob_id = 24'b0;
    assign alu_issue_thread_id = 8'b0;
    assign agu_issue_valid = 1'b0;
    assign agu_issue_uop = 64'b0;
    assign agu_issue_rob_id = 6'b0;
    assign agu_issue_thread_id = 2'b0;
    assign mul_issue_valid = 1'b0;
    assign mul_issue_uop = 64'b0;
    assign mul_issue_rob_id = 6'b0;
    assign mul_issue_thread_id = 2'b0;
    assign div_issue_valid = 1'b0;
    assign div_issue_uop = 64'b0;
    assign div_issue_rob_id = 6'b0;
    assign div_issue_thread_id = 2'b0;
    assign fpu_issue_valid = 2'b0;
    assign fpu_issue_uop = 128'b0;
    assign fpu_issue_rob_id = 12'b0;
    assign fpu_issue_thread_id = 4'b0;
    assign perf_issue_stalls = 32'b0;
    // perf_thread_stalls driven by vixen_issue_queue module
    assign perf_alu_ops = 32'b0;
    assign perf_fpu_ops = 32'b0;
    assign perf_mem_ops = 32'b0;
    assign eu_alu_busy = 4'b0;
    assign eu_mul_busy = 1'b0;
    assign eu_div_busy = 1'b0;
    assign eu_fpu_busy = 2'b0;
    assign thread_active = 2'b11; // Both threads active by default
    assign thread_stalled = 2'b00;
    
    // Stub assignments for high-performance signals
    assign bp_thread_id = 2'b0;
    assign branch_pc = pc_t0; // Connect to thread 0 PC for now
    assign branch_taken = 1'b0;
    assign branch_thread_id = 2'b0;
    assign is_call = 1'b0;
    assign is_return = 1'b0;
    assign uops_valid = 3'b0;
    assign hit_thread_id = 2'b0;
    assign fill_pc = 64'b0;
    assign fill_thread_id = 2'b0;
    assign fill_enable = 1'b0;
    assign flush = 1'b0;
    assign flush_thread_id = 2'b0;
    assign pc_update_t0 = pc_t0;
    assign pc_update_t1 = pc_t1;
    assign pc_update_valid_t0 = 1'b1;
    assign pc_update_valid_t1 = 1'b1;
    // thread_priority driven by vixen_smt_manager module
    // perf_thread_cycles driven by vixen_smt_manager module 
    // perf_thread_instructions driven by vixen_smt_manager module
    assign preferred_thread = 2'b0;
    assign thread_exception = 2'b0;
    assign exception_vector_t0 = 8'b0;
    assign exception_vector_t1 = 8'b0;
    assign thread_flush_t0 = 1'b0;
    assign thread_flush_t1 = 1'b0;
    assign context_switch_req = 1'b0;
    assign context_switch_thread = 2'b0;
    assign context_switch_ack = 1'b0;
    
    // Cache hit signals
    logic l2_hit, l3_hit;
    
    // Trace cache output signals
    logic tc_hit;
    logic [191:0] tc_uops_out;  // 3 * 64 bits
    
    // Add stub assignments for memory interface (only outputs)
    assign mem_addr = 64'b0;
    assign mem_wdata = 512'b0;
    assign mem_we = 1'b0;
    assign mem_req = 1'b0;
    // Note: mem_ack, mem_ready, mem_rdata are inputs - don't assign them
    
    // Add stub assignments for cache signals
    assign l1i_l2_addr = 64'b0;
    assign l1i_l2_data = 512'b0;
    assign l1i_l2_req = 1'b0;
    assign l1i_l2_ack = 1'b1;
    assign l1d_l2_addr = 64'b0;
    assign l1d_l2_wdata = 512'b0;
    assign l1d_l2_we = 1'b0;
    assign l1d_l2_req = 1'b0;
    assign l1d_l2_ack = 1'b1;
    assign l1d_l2_rdata = 512'b0;
    assign l2_l3_addr = 64'b0;
    assign l2_l3_wdata = 512'b0;
    assign l2_l3_we = 1'b0;
    assign l2_l3_req = 1'b0;
    assign l2_l3_ack = 1'b1;
    assign l2_l3_rdata = 512'b0;
    
    // Add stub assignments for additional missing signals  
    assign l1i_addr = pc_t0; // Connect instruction cache to PC
    assign l1d_addr = mem_load_addr;
    assign l1d_wdata = mem_store_data;
    assign l1d_we = mem_store_req;
    
    // =========================================================================
    // Additional High-Performance Signals for Full Complexity
    // =========================================================================
    
    // Branch Predictor Interface Signals
    logic [1:0] bp_thread_id;
    logic [63:0] branch_pc;
    logic branch_taken;
    logic [1:0] branch_thread_id;
    logic is_call;
    logic is_return;
    logic [31:0] perf_predictions;
    logic [31:0] perf_mispredictions;
    logic [31:0] perf_btb_hits;
    logic [31:0] perf_ras_hits;
    
    // Trace Cache Interface Signals
    logic [2:0] uops_valid;
    logic [1:0] hit_thread_id;
    logic [63:0] fill_pc;
    logic [1:0] fill_thread_id;
    logic fill_enable;
    logic flush;
    logic [1:0] flush_thread_id;
    logic [31:0] perf_tc_hits;
    logic [31:0] perf_tc_misses;
    logic [31:0] perf_tc_fills;
    
    // SMT Manager Interface Signals
    logic [63:0] pc_update_t0;
    logic [63:0] pc_update_t1;
    logic pc_update_valid_t0;
    logic pc_update_valid_t1;
    logic [31:0] thread_priority_0;  // Thread 0 priority
    logic [31:0] thread_priority_1;  // Thread 1 priority
    logic [1:0] preferred_thread;
    logic [1:0] thread_exception;
    logic [7:0] exception_vector_t0;
    logic [7:0] exception_vector_t1;
    logic thread_flush_t0;
    logic thread_flush_t1;
    logic context_switch_req;
    logic [1:0] context_switch_thread;
    logic context_switch_ack;
    logic [31:0] perf_thread_cycles_0;  // Thread 0 cycles
    logic [31:0] perf_thread_cycles_1;  // Thread 1 cycles
    logic [31:0] perf_thread_instructions_0;  // Thread 0 instructions
    logic [31:0] perf_thread_instructions_1;  // Thread 1 instructions
    logic [31:0] perf_context_switches;
    logic [31:0] perf_resource_conflicts;
    
    // Extended Cache Interface Signals
    logic [63:0] l1i_l2_addr;
    logic [511:0] l1i_l2_data;
    logic l1i_l2_req;
    logic l1i_l2_ack;
    logic [63:0] l1d_l2_addr;
    logic [511:0] l1d_l2_wdata;
    logic [511:0] l1d_l2_rdata;
    logic l1d_l2_we;
    logic l1d_l2_req;
    logic l1d_l2_ack;
    logic [63:0] l2_l3_addr;
    logic [511:0] l2_l3_wdata;
    logic [511:0] l2_l3_rdata;
    logic l2_l3_we;
    logic l2_l3_req;
    logic l2_l3_ack;
    
    // Branch prediction
    logic [63:0] bp_target;
    logic        bp_taken;
    logic        bp_valid;
    
    // Memory subsystem
    logic [63:0] mem_load_addr, mem_store_addr;
    logic [63:0] mem_load_data, mem_store_data;
    logic        mem_load_req, mem_store_req;
    logic        mem_load_ack, mem_store_ack;
    
    // =========================================================================
    // Core Components Instantiation
    // =========================================================================
    
    // Frontend (Fetch + Decode)
    vixen_frontend u_frontend (
        .clk(clk),
        .rst_n(rst_n),
        .pc_t0(pc_t0),
        .pc_t1(pc_t1),
        .thread_active(thread_active),
        .bp_target(bp_target),
        .bp_taken(bp_taken),
        .bp_valid(bp_valid),
        .l1i_addr(l1i_addr),
        .l1i_data(l1i_data),
        .l1i_hit(l1i_hit),
        .fetch_bundle(fetch_bundle),
        .fetch_valid(fetch_valid),
        .fetch_thread_id(fetch_thread_id),
        .decoded_uops(decoded_uops),
        .decoded_valid(decoded_valid),
        .decoded_thread_id(decoded_thread_id)
    );
    
    // Rename and ROB
    vixen_rename_rob u_rename_rob (
        .clk(clk),
        .rst_n(rst_n),
        .decoded_uops(decoded_uops),
        .decoded_valid(decoded_valid),
        .decoded_thread_id(decoded_thread_id),
        .rob_valid(rob_valid),
        .rob_ready(rob_ready),
        .rob_head(rob_head),
        .rob_tail(rob_tail),
        .iq_valid(iq_valid),
        .iq_ready(iq_ready),
        .eu_complete(eu_complete),
        .eu_rob_id(eu_rob_id),
        .eu_result(eu_result),
        .branch_resolve(branch_resolve),
        .branch_mispredict(branch_mispredict),
        .branch_rob_id(branch_rob_id),
        .branch_target(branch_target),
        .retire_valid(retire_valid),
        .retire_data(retire_data),
        .retire_thread_id(retire_thread_id),
        .exception_req(exception_req),
        .exception_vector(exception_vector),
        .exception_flush(exception_flush)
    );
    
    // Issue Queue and Scheduler
    vixen_issue_queue #(
        .IQ_ENTRIES(32),
        .NUM_THREADS(2),
        .NUM_ALU(2),
        .NUM_AGU(1),
        .NUM_FPU(2)
    ) u_issue_queue (
        .clk(clk),
        .rst_n(rst_n),
        .rob_uops(rob_uops),
        .rob_uop_valid(rob_uop_valid),
        .rob_thread_id(rob_thread_id),
        .rob_id(rob_id),
        .alu_issue_valid(alu_issue_valid),
        .alu_issue_uop(alu_issue_uop),
        .alu_issue_rob_id(alu_issue_rob_id),
        .alu_issue_thread_id(alu_issue_thread_id),
        .agu_issue_valid(agu_issue_valid),
        .agu_issue_uop(agu_issue_uop),
        .agu_issue_rob_id(agu_issue_rob_id),
        .agu_issue_thread_id(agu_issue_thread_id),
        .mul_issue_valid(mul_issue_valid),
        .mul_issue_uop(mul_issue_uop),
        .mul_issue_rob_id(mul_issue_rob_id),
        .mul_issue_thread_id(mul_issue_thread_id),
        .div_issue_valid(div_issue_valid),
        .div_issue_uop(div_issue_uop),
        .div_issue_rob_id(div_issue_rob_id),
        .div_issue_thread_id(div_issue_thread_id),
        .fpu_issue_valid(fpu_issue_valid),
        .fpu_issue_uop(fpu_issue_uop),
        .fpu_issue_rob_id(fpu_issue_rob_id),
        .fpu_issue_thread_id(fpu_issue_thread_id),
        .eu_wakeup_valid(eu_wakeup_valid),
        .eu_wakeup_tag(eu_wakeup_tag),
        .iq_valid(iq_valid),
        .iq_ready(iq_ready),
        .eu_alu_busy(eu_alu_busy),
        .eu_mul_busy(eu_mul_busy),
        .eu_div_busy(eu_div_busy),
        .eu_fpu_busy(eu_fpu_busy),
        .thread_active(thread_active),
        .perf_issue_stalls(perf_issue_stalls),
        .perf_thread_stalls_0(perf_thread_stalls_0),
        .perf_thread_stalls_1(perf_thread_stalls_1)
    );
    
    // Execution Units
    vixen_execution_cluster u_execution_cluster (
        .clk(clk),
        .rst_n(rst_n),
        .alu_issue_valid(alu_issue_valid),
        .alu_issue_uop(alu_issue_uop),
        .alu_issue_rob_id(alu_issue_rob_id),
        .alu_issue_thread_id(alu_issue_thread_id),
        .agu_issue_valid(agu_issue_valid),
        .agu_issue_uop(agu_issue_uop),
        .agu_issue_rob_id(agu_issue_rob_id),
        .agu_issue_thread_id(agu_issue_thread_id),
        .mul_issue_valid(mul_issue_valid),
        .mul_issue_uop(mul_issue_uop),
        .mul_issue_rob_id(mul_issue_rob_id),
        .mul_issue_thread_id(mul_issue_thread_id),
        .div_issue_valid(div_issue_valid),
        .div_issue_uop(div_issue_uop),
        .div_issue_rob_id(div_issue_rob_id),
        .div_issue_thread_id(div_issue_thread_id),
        .fpu_issue_valid(fpu_issue_valid),
        .fpu_issue_uop(fpu_issue_uop),
        .fpu_issue_rob_id(fpu_issue_rob_id),
        .fpu_issue_thread_id(fpu_issue_thread_id),
        .eu_complete(eu_complete),
        .eu_rob_id(eu_rob_id),
        .eu_result(eu_result),
        .eu_wakeup_valid(eu_wakeup_valid),
        .eu_wakeup_tag(eu_wakeup_tag),
        .eu_alu_busy(eu_alu_busy),
        .eu_mul_busy(eu_mul_busy),
        .eu_div_busy(eu_div_busy),
        .eu_fpu_busy(eu_fpu_busy),
        .mem_load_addr(mem_load_addr),
        .mem_store_addr(mem_store_addr),
        .mem_load_data(mem_load_data),
        .mem_store_data(mem_store_data),
        .mem_load_req(mem_load_req),
        .mem_store_req(mem_store_req),
        .mem_load_ack(mem_load_ack),
        .mem_store_ack(mem_store_ack),
        .perf_alu_ops(perf_alu_ops),
        .perf_fpu_ops(perf_fpu_ops),
        .perf_mem_ops(perf_mem_ops)
    );
    
    // L1 Instruction Cache
    vixen_l1_icache u_l1_icache (
        .clk(clk),
        .rst_n(rst_n),
        .addr(l1i_addr),
        .req(1'b1),
        .ready(l1i_ready),
        .data_out(l1i_data),
        .hit(l1i_hit),
        .l2_addr(l1i_l2_addr),
        .l2_data(l1i_l2_data),
        .l2_req(l1i_l2_req),
        .l2_ack(l1i_l2_ack),
        .perf_hits(perf_l1i_hits),
        .perf_misses(perf_l1i_misses)
    );
    
    // L1 Data Cache
    vixen_l1_dcache u_l1_dcache (
        .clk(clk),
        .rst_n(rst_n),
        .load_addr(mem_load_addr),
        .store_addr(mem_store_addr),
        .store_data(mem_store_data),
        .load_data(mem_load_data),
        .load_req(mem_load_req),
        .store_req(mem_store_req),
        .load_ack(mem_load_ack),
        .store_ack(mem_store_ack),
        .hit(l1d_hit),
        .l2_addr(l1d_l2_addr),
        .l2_wdata(l1d_l2_wdata),
        .l2_rdata(l1d_l2_rdata),
        .l2_we(l1d_l2_we),
        .l2_req(l1d_l2_req),
        .l2_ack(l1d_l2_ack),
        .perf_load_hits(perf_l1d_load_hits),
        .perf_load_misses(perf_l1d_load_misses),
        .perf_store_hits(perf_l1d_store_hits),
        .perf_store_misses(perf_l1d_store_misses)
    );
    
    // L2 Cache
    vixen_l2_cache u_l2_cache (
        .clk(clk),
        .rst_n(rst_n),
        .l1i_addr(l1i_l2_addr),
        .l1i_data(l1i_l2_data),
        .l1i_req(l1i_l2_req),
        .l1i_ack(l1i_l2_ack),
        .l1d_addr(l1d_l2_addr),
        .l1d_wdata(l1d_l2_wdata),
        .l1d_we(l1d_l2_we),
        .l1d_rdata(l1d_l2_rdata),
        .l1d_req(l1d_l2_req),
        .l1d_ack(l1d_l2_ack),
        .l3_addr(l2_l3_addr),
        .l3_wdata(l2_l3_wdata),
        .l3_rdata(l2_l3_rdata),
        .l3_we(l2_l3_we),
        .l3_req(l2_l3_req),
        .l3_ack(l2_l3_ack),
        .hit(l2_hit),
        .perf_hits(perf_l2_hits),
        .perf_misses(perf_l2_misses),
        .perf_writebacks(perf_l2_writebacks)
    );
    
    // L3 Cache
    vixen_l3_cache u_l3_cache (
        .clk(clk),
        .rst_n(rst_n),
        .l2_addr(l2_l3_addr),
        .l2_wdata(l2_l3_wdata),
        .l2_we(l2_l3_we),
        .l2_rdata(l2_l3_rdata),
        .l2_req(l2_l3_req),
        .l2_ack(l2_l3_ack),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata),
        .mem_we(mem_we),
        .mem_req(mem_req),
        .mem_ack(mem_ack),
        .mem_ready(mem_ready),
        .hit(l3_hit),
        .perf_hits(perf_l3_hits),
        .perf_misses(perf_l3_misses),
        .perf_writebacks(perf_l3_writebacks)
    );
    
    // Branch Predictor (TAGE-lite)
    vixen_branch_predictor #(
        .TAGE_TABLE_SIZE(16*1024),
        .BTB_ENTRIES(1024),
        .RAS_ENTRIES(8)
    ) u_branch_predictor (
        .clk(clk),
        .rst_n(rst_n),
        .pc_t0(pc_t0),
        .pc_t1(pc_t1),
        .thread_active(thread_active),
        .bp_thread_id(bp_thread_id),
        .bp_target(bp_target),
        .bp_taken(bp_taken),
        .bp_valid(bp_valid),
        .branch_resolve(branch_resolve),
        .branch_pc(branch_pc),
        .branch_target(branch_target),
        .branch_taken(branch_taken),
        .branch_mispredict(branch_mispredict),
        .branch_thread_id(branch_thread_id),
        .is_call(is_call),
        .is_return(is_return),
        .perf_predictions(perf_predictions),
        .perf_mispredictions(perf_mispredictions),
        .perf_btb_hits(perf_btb_hits),
        .perf_ras_hits(perf_ras_hits)
    );
    
    // Trace Cache (for decoded micro-ops)
    vixen_trace_cache #(
        .TRACE_CACHE_SIZE(8*1024),
        .TRACE_LINE_SIZE(64),
        .MAX_UOPS_PER_LINE(6),
        .ASSOCIATIVITY(4)
    ) u_trace_cache (
        .clk(clk),
        .rst_n(rst_n),
        .pc_in({pc_t0, pc_t1}),
        .thread_active(thread_active),
        .uops_in(decoded_uops),
        .valid_in(decoded_valid),
        .uops_valid(uops_valid),
        .hit_thread_id(hit_thread_id),
        .fill_pc(fill_pc),
        .fill_thread_id(fill_thread_id),
        .fill_enable(fill_enable),
        .flush(flush),
        .flush_thread_id(flush_thread_id),
        .hit(tc_hit),
        .uops_out(tc_uops_out),
        .perf_hits(perf_tc_hits),
        .perf_misses(perf_tc_misses),
        .perf_fills(perf_tc_fills)
    );
    
    // SMT Thread Manager
    vixen_smt_manager #(
        .NUM_THREADS(2),
        .NUM_ARCH_REGS(16), 
        .ROB_ENTRIES(48)
    ) u_smt_manager (
        .clk(clk),
        .rst_n(rst_n),
        .pc_update_t0(pc_update_t0),
        .pc_update_t1(pc_update_t1),
        .pc_update_valid_t0(pc_update_valid_t0),
        .pc_update_valid_t1(pc_update_valid_t1),
        .rob_valid(rob_valid),
        .thread_priority_0(thread_priority_0),
        .thread_priority_1(thread_priority_1),
        .preferred_thread(preferred_thread),
        .thread_exception(thread_exception),
        .exception_vector_t0(exception_vector_t0),
        .exception_vector_t1(exception_vector_t1),
        .thread_flush_t0(thread_flush_t0),
        .thread_flush_t1(thread_flush_t1),
        .context_switch_req(context_switch_req),
        .context_switch_thread(context_switch_thread),
        .context_switch_ack(context_switch_ack),
        .thread_active(thread_active),
        .thread_stalled(thread_stalled),
        .pc_t0(pc_t0),
        .pc_t1(pc_t1),
        .rob_head(rob_head),
        .rob_tail(rob_tail),
        .perf_thread_cycles_0(perf_thread_cycles_0),
        .perf_thread_cycles_1(perf_thread_cycles_1),
        .perf_thread_instructions_0(perf_thread_instructions_0),
        .perf_thread_instructions_1(perf_thread_instructions_1),
        .perf_context_switches(perf_context_switches),
        .perf_resource_conflicts(perf_resource_conflicts)
    );
    
    // =========================================================================
    // Performance Counters
    // =========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_cycles <= 32'b0;
            perf_instructions_t0 <= 32'b0;
            perf_instructions_t1 <= 32'b0;
            perf_cache_misses <= 32'b0;
        end else begin
            perf_cycles <= perf_cycles + 1;
            
            // Count retired instructions per thread
            if (thread_active[0] && |decoded_valid)
                perf_instructions_t0 <= perf_instructions_t0 + $countones(decoded_valid);
            
            if (thread_active[1] && |decoded_valid)
                perf_instructions_t1 <= perf_instructions_t1 + $countones(decoded_valid);
            
            // Count cache misses
            if (!l1i_hit || !l1d_hit || !l2_hit || !l3_hit)
                perf_cache_misses <= perf_cache_misses + 1;
        end
    end
    
    // Debug outputs
    assign debug_pc_t0 = pc_t0;
    assign debug_pc_t1 = pc_t1;
    assign debug_ack = debug_req;

endmodule
