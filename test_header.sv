// =============================================================================
// Vixen Dio Pro Issue Queue and Scheduler
// =============================================================================
// Unified issue queue that schedules micro-ops to execution units
// Supports out-of-order issue with SMT thread fairness
// =============================================================================

module vixen_issue_queue #(
    parameter IQ_ENTRIES = 32,
    parameter NUM_THREADS = 2,
    parameter NUM_ALU = 2,
    parameter NUM_AGU = 1,
    parameter NUM_FPU = 2
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Issue Queue Status
    input  logic [31:0] iq_valid,
    input  logic [31:0] iq_ready,
    
    // Execution Unit Status
    input  logic [2:0]  eu_alu_busy,      // 2 ALUs + 1 AGU
    input  logic        eu_mul_busy,
    input  logic        eu_div_busy,
    input  logic [1:0]  eu_fpu_busy,      // 2 FPU pipelines
    
    // Thread Management
    input  logic [1:0]  thread_active,
    
    // ROB Interface (flattened for synthesis compatibility)
    input  logic [192-1:0] rob_uops,        // 3 × 64 bits flattened
    input  logic [2:0]     rob_uop_valid,
    input  logic [6-1:0]   rob_thread_id,   // 3 × 2 bits flattened  
    input  logic [18-1:0]  rob_id,          // 3 × 6 bits flattened
    
    // Issue Interface to Execution Units (flattened for synthesis)
    output logic [NUM_ALU-1:0]   alu_issue_valid,
    output logic [128-1:0]       alu_issue_uop,        // 2 × 64 bits flattened
    output logic [12-1:0]        alu_issue_rob_id,     // 2 × 6 bits flattened  
    output logic [4-1:0]         alu_issue_thread_id,  // 2 × 2 bits flattened
    
    output logic                     agu_issue_valid,
    output logic [63:0]              agu_issue_uop,
    output logic [5:0]               agu_issue_rob_id,
    output logic [1:0]               agu_issue_thread_id,
    
    output logic                     mul_issue_valid,
    output logic [63:0]              mul_issue_uop,
    output logic [5:0]               mul_issue_rob_id,
