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
    output logic [1:0]               mul_issue_thread_id,
    
    output logic                     div_issue_valid,
    output logic [63:0]              div_issue_uop,
    output logic [5:0]               div_issue_rob_id,
    output logic [1:0]               div_issue_thread_id,
    
    output logic [NUM_FPU-1:0]  fpu_issue_valid,
    output logic [128-1:0]      fpu_issue_uop,        // 2 × 64 bits flattened
    output logic [12-1:0]       fpu_issue_rob_id,     // 2 × 6 bits flattened
    output logic [4-1:0]        fpu_issue_thread_id,  // 2 × 2 bits flattened
    
    // Wakeup from execution units (flattened for synthesis)
    input  logic [2:0]     eu_wakeup_valid,
    input  logic [24-1:0]  eu_wakeup_tag,       // 3 × 8 bits flattened
    
    // Performance counters
    output logic [31:0] perf_issue_stalls,
    output logic [31:0] perf_thread_stalls_0,  // Thread 0 stalls
    output logic [31:0] perf_thread_stalls_1   // Thread 1 stalls
);

    // =========================================================================
    // Issue Queue Entry Structure
    // =========================================================================
    
    typedef struct packed {
        logic        valid;           // Entry is valid
        logic        ready;           // Ready to issue (all operands available)
        logic        issued;          // Has been issued
        logic [63:0] uop;            // Micro-operation
        logic [5:0]  rob_id;         // ROB entry ID
        logic [1:0]  thread_id;      // Thread ownership
        logic [3:0]  uop_type;       // Type of operation
        logic [2:0]  exec_unit_type; // Target execution unit type
        logic [7:0]  src1_tag;       // Source operand 1 tag
        logic [7:0]  src2_tag;       // Source operand 2 tag
        logic [7:0]  dst_tag;        // Destination tag
        logic        src1_ready;     // Source 1 operand ready
        logic        src2_ready;     // Source 2 operand ready
        logic [63:0] src1_data;      // Source 1 data
        logic [63:0] src2_data;      // Source 2 data
        logic [31:0] age;            // Age counter for priority
    } iq_entry_t;
    
    // Execution unit types
    localparam EU_ALU = 3'b000;
    localparam EU_AGU = 3'b001;
    localparam EU_MUL = 3'b010;
    localparam EU_DIV = 3'b011;
    localparam EU_FPU = 3'b100;
    
    // =========================================================================
    // Issue Queue Storage
    // =========================================================================
    
    iq_entry_t [IQ_ENTRIES-1:0] iq_entries;
    logic [IQ_ENTRIES-1:0] iq_entry_valid;
    logic [IQ_ENTRIES-1:0] iq_entry_ready;
    logic [4:0] iq_head, iq_tail;
    logic [5:0] iq_count;
    logic       iq_full, iq_empty;
    
    // Thread fairness tracking
    logic [31:0] thread_issue_count [NUM_THREADS];
    logic [1:0]  last_issued_thread;
    logic        thread_priority [NUM_THREADS];
    
    // Age counter for instruction ordering
    logic [31:0] global_age_counter;
    
    // Integer variables for loops (Yosys compatibility)
    integer i, j;
    
    // =========================================================================
    // Allocation Logic
    // =========================================================================
    
    logic [2:0] alloc_valid;
    logic [15-1:0] alloc_iq_idx;  // 3*5 = 15 bits flattened
    logic [4:0] search_idx;
    
    // Variables for allocation logic (moved outside always block)
    logic [31:0] free_mask;
    logic [4:0] first_free, second_free, third_free;
    
    // Find free IQ entries using priority encoder (no while loops for Yosys)
    always @(*) begin
        alloc_valid = 3'b0;
        alloc_iq_idx = 15'b0;  // Initialize flattened array to zeros
        
        // Build mask of free entries
        for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
            free_mask[i] = !iq_entries[i].valid;
        end
        
        // Priority encoder for first free entry
        first_free = 5'b0;
        for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
            if (free_mask[i] && first_free == 5'b0) begin
                first_free = i[4:0];
            end
        end
        
        // Priority encoder for second free entry  
        second_free = 5'b0;
        for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
            if (free_mask[i] && i != first_free && second_free == 5'b0) begin
                second_free = i[4:0];
            end
        end
        
        // Priority encoder for third free entry
        third_free = 5'b0;
        for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
            if (free_mask[i] && i != first_free && i != second_free && third_free == 5'b0) begin
                third_free = i[4:0];
            end
        end
        
        // Allocate uop 0
        if (rob_uop_valid[0] && !iq_full && free_mask[first_free]) begin
            alloc_valid[0] = 1'b1;
            alloc_iq_idx[4:0] = first_free;
        end
        
        // Allocate uop 1  
        if (rob_uop_valid[1] && !iq_full && free_mask[second_free]) begin
            alloc_valid[1] = 1'b1;
            alloc_iq_idx[9:5] = second_free;
        end
        
        // Allocate uop 2
        if (rob_uop_valid[2] && !iq_full && free_mask[third_free]) begin
            alloc_valid[2] = 1'b1;
            alloc_iq_idx[14:10] = third_free;
        end
    end
    
    // =========================================================================
    // Wakeup Logic
    // =========================================================================
    
    // Variables for wakeup logic (moved outside always block)
    logic src1_wakeup, src2_wakeup;
    
    always @(*) begin
        for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
            if (iq_entries[i].valid && !iq_entries[i].ready) begin
                src1_wakeup = iq_entries[i].src1_ready;
                src2_wakeup = iq_entries[i].src2_ready;
                
                // Check if source operands are woken up by completing instructions
                for (j = 0; j < 3; j = j + 1) begin
                    if (eu_wakeup_valid[j]) begin
                        if (iq_entries[i].src1_tag == eu_wakeup_tag[j*8 +: 8])
                            src1_wakeup = 1'b1;
                        if (iq_entries[i].src2_tag == eu_wakeup_tag[j*8 +: 8])
                            src2_wakeup = 1'b1;
                    end
                end
                
                iq_entry_ready[i] = src1_wakeup && src2_wakeup;
            end else begin
                iq_entry_ready[i] = iq_entries[i].ready;
            end
        end
    end
    
    // =========================================================================
    // Selection Logic
    // =========================================================================
    
    // Selection priority: Ready > Thread Fairness > Age
    logic [64-1:0] alu_candidates_flat;  // [NUM_ALU-1:0][IQ_ENTRIES-1:0] = [2-1:0][32-1:0] flattened to [64-1:0]
    logic [IQ_ENTRIES-1:0] agu_candidates;
    logic [IQ_ENTRIES-1:0] mul_candidates;
    logic [IQ_ENTRIES-1:0] div_candidates;
    logic [64-1:0] fpu_candidates_flat;  // [NUM_FPU-1:0][IQ_ENTRIES-1:0] = [2-1:0][32-1:0] flattened to [64-1:0]
    
    // Variables for candidate identification (moved outside always block)
    logic [2:0] current_exec_unit_type;
    
    // Identify candidates for each execution unit
    always @(*) begin
        // Initialize candidates
        alu_candidates_flat = 64'b0;  // Initialize flattened array
        agu_candidates = 32'b0;  // Explicit bit width
        mul_candidates = 32'b0;  // Explicit bit width
        div_candidates = 32'b0;  // Explicit bit width
        fpu_candidates_flat = 64'b0;  // Initialize flattened array
        
        for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
            if (iq_entries[i].valid && iq_entry_ready[i] && !iq_entries[i].issued) begin
                current_exec_unit_type = iq_entries[i].exec_unit_type;  // Extract for width detection
                case (current_exec_unit_type)
                    EU_ALU: begin
                        for (j = 0; j < NUM_ALU; j = j + 1) begin
                            if (!eu_alu_busy[j]) begin
                                alu_candidates_flat[j*32 + i] = 1'b1;  // Flattened indexing
                            end
                        end
                    end
                    
                    EU_AGU: begin
                        if (!eu_alu_busy[2]) begin // AGU is ALU[2]
                            agu_candidates[i] = 1'b1;
                        end
                    end
                    
                    EU_MUL: begin
                        if (!eu_mul_busy) begin
                            mul_candidates[i] = 1'b1;
                        end
                    end
                    
                    EU_DIV: begin
                        if (!eu_div_busy) begin
                            div_candidates[i] = 1'b1;
                        end
                    end
                    
                    EU_FPU: begin
                        for (j = 0; j < NUM_FPU; j = j + 1) begin
                            if (!eu_fpu_busy[j]) begin
                                fpu_candidates_flat[j*32 + i] = 1'b1;  // Flattened indexing
                            end
                        end
                    end
                endcase
            end
        end
    end
    
    // =========================================================================
    // Selection Logic - converted from function to basic Verilog
    // =========================================================================
    // Issue Logic
    // =========================================================================

    logic [10-1:0] selected_alu_flat;  // [NUM_ALU-1:0][4:0] = [2-1:0][4:0] flattened to [10-1:0]
    logic [4:0] selected_agu;
    logic [4:0] selected_mul;
    logic [4:0] selected_div;
    logic [10-1:0] selected_fpu_flat;  // [NUM_FPU-1:0][4:0] = [2-1:0][4:0] flattened to [10-1:0]
    
    // Variables for instruction selection (moved outside always block)
    logic [4:0] selected_idx;
    logic [31:0] oldest_age;
    logic found;
    logic prefer_thread;
    logic [IQ_ENTRIES-1:0] current_candidates;
    
    // Variables for issue signal generation
    logic [4:0] alu_selected_idx;
    logic [4:0] fpu_selected_idx;

    always @(*) begin
        // Select instructions for each execution unit - inline logic for ALU
        // ALU 0
        current_candidates = alu_candidates_flat[0*32 +: 32];
        prefer_thread = thread_priority[0] || thread_priority[1];
        selected_idx = 5'b0;
        oldest_age = 32'hFFFFFFFF;
        found = 1'b0;
        
        // First pass: look for preferred thread
        if (prefer_thread) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && 
                    thread_priority[iq_entries[j].thread_id] &&
                    iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        // Second pass: any thread, oldest first
        if (!found) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        selected_alu_flat[0*5 +: 5] = found ? selected_idx : 5'b11111;
        
        // ALU 1
        current_candidates = alu_candidates_flat[1*32 +: 32];
        prefer_thread = thread_priority[0] || thread_priority[1];
        selected_idx = 5'b0;
        oldest_age = 32'hFFFFFFFF;
        found = 1'b0;
        
        // First pass: look for preferred thread
        if (prefer_thread) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && 
                    thread_priority[iq_entries[j].thread_id] &&
                    iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        // Second pass: any thread, oldest first
        if (!found) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        selected_alu_flat[1*5 +: 5] = found ? selected_idx : 5'b11111;
        
        // Inline selection logic for AGU
        current_candidates = agu_candidates;
        prefer_thread = thread_priority[0] || thread_priority[1];
        selected_idx = 5'b0;
        oldest_age = 32'hFFFFFFFF;
        found = 1'b0;
        
        if (prefer_thread) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && 
                    thread_priority[iq_entries[j].thread_id] &&
                    iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        if (!found) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        selected_agu = found ? selected_idx : 5'b11111;
        
        // Inline selection logic for MUL
        current_candidates = mul_candidates;
        prefer_thread = thread_priority[0] || thread_priority[1];
        selected_idx = 5'b0;
        oldest_age = 32'hFFFFFFFF;
        found = 1'b0;
        
        if (prefer_thread) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && 
                    thread_priority[iq_entries[j].thread_id] &&
                    iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        if (!found) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        selected_mul = found ? selected_idx : 5'b11111;
        
        // Inline selection logic for DIV
        current_candidates = div_candidates;
        prefer_thread = thread_priority[0] || thread_priority[1];
        selected_idx = 5'b0;
        oldest_age = 32'hFFFFFFFF;
        found = 1'b0;
        
        if (prefer_thread) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && 
                    thread_priority[iq_entries[j].thread_id] &&
                    iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        if (!found) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        selected_div = found ? selected_idx : 5'b11111;
        
        // Inline selection logic for FPU units
        // FPU 0
        current_candidates = fpu_candidates_flat[0*32 +: 32];
        prefer_thread = thread_priority[0] || thread_priority[1];
        selected_idx = 5'b0;
        oldest_age = 32'hFFFFFFFF;
        found = 1'b0;
        
        if (prefer_thread) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && 
                    thread_priority[iq_entries[j].thread_id] &&
                    iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        if (!found) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        selected_fpu_flat[0*5 +: 5] = found ? selected_idx : 5'b11111;
        
        // FPU 1
        current_candidates = fpu_candidates_flat[1*32 +: 32];
        prefer_thread = thread_priority[0] || thread_priority[1];
        selected_idx = 5'b0;
        oldest_age = 32'hFFFFFFFF;
        found = 1'b0;
        
        if (prefer_thread) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && 
                    thread_priority[iq_entries[j].thread_id] &&
                    iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        if (!found) begin
            for (j = 0; j < IQ_ENTRIES; j = j + 1) begin
                if (current_candidates[j] && iq_entries[j].age < oldest_age) begin
                    selected_idx = j[4:0];
                    oldest_age = iq_entries[j].age;
                    found = 1'b1;
                end
            end
        end
        
        selected_fpu_flat[1*5 +: 5] = found ? selected_idx : 5'b11111;
        
        // Generate issue signals with flattened array indexing
        // ALU 0
        alu_selected_idx = selected_alu_flat[0*5 +: 5];
        alu_issue_valid[0] = (alu_selected_idx != 5'b11111);
        if (alu_issue_valid[0]) begin
            // Use case statement to avoid dynamic indexing
            case (alu_selected_idx)
                5'd0:  begin alu_issue_uop[0*64 +: 64] = iq_entries[0].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[0].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[0].thread_id; end
                5'd1:  begin alu_issue_uop[0*64 +: 64] = iq_entries[1].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[1].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[1].thread_id; end
                5'd2:  begin alu_issue_uop[0*64 +: 64] = iq_entries[2].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[2].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[2].thread_id; end
                5'd3:  begin alu_issue_uop[0*64 +: 64] = iq_entries[3].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[3].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[3].thread_id; end
                5'd4:  begin alu_issue_uop[0*64 +: 64] = iq_entries[4].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[4].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[4].thread_id; end
                5'd5:  begin alu_issue_uop[0*64 +: 64] = iq_entries[5].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[5].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[5].thread_id; end
                5'd6:  begin alu_issue_uop[0*64 +: 64] = iq_entries[6].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[6].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[6].thread_id; end
                5'd7:  begin alu_issue_uop[0*64 +: 64] = iq_entries[7].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[7].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[7].thread_id; end
                5'd8:  begin alu_issue_uop[0*64 +: 64] = iq_entries[8].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[8].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[8].thread_id; end
                5'd9:  begin alu_issue_uop[0*64 +: 64] = iq_entries[9].uop;  alu_issue_rob_id[0*6 +: 6] = iq_entries[9].rob_id;  alu_issue_thread_id[0*2 +: 2] = iq_entries[9].thread_id; end
                5'd10: begin alu_issue_uop[0*64 +: 64] = iq_entries[10].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[10].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[10].thread_id; end
                5'd11: begin alu_issue_uop[0*64 +: 64] = iq_entries[11].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[11].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[11].thread_id; end
                5'd12: begin alu_issue_uop[0*64 +: 64] = iq_entries[12].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[12].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[12].thread_id; end
                5'd13: begin alu_issue_uop[0*64 +: 64] = iq_entries[13].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[13].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[13].thread_id; end
                5'd14: begin alu_issue_uop[0*64 +: 64] = iq_entries[14].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[14].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[14].thread_id; end
                5'd15: begin alu_issue_uop[0*64 +: 64] = iq_entries[15].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[15].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[15].thread_id; end
                5'd16: begin alu_issue_uop[0*64 +: 64] = iq_entries[16].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[16].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[16].thread_id; end
                5'd17: begin alu_issue_uop[0*64 +: 64] = iq_entries[17].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[17].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[17].thread_id; end
                5'd18: begin alu_issue_uop[0*64 +: 64] = iq_entries[18].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[18].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[18].thread_id; end
                5'd19: begin alu_issue_uop[0*64 +: 64] = iq_entries[19].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[19].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[19].thread_id; end
                5'd20: begin alu_issue_uop[0*64 +: 64] = iq_entries[20].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[20].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[20].thread_id; end
                5'd21: begin alu_issue_uop[0*64 +: 64] = iq_entries[21].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[21].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[21].thread_id; end
                5'd22: begin alu_issue_uop[0*64 +: 64] = iq_entries[22].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[22].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[22].thread_id; end
                5'd23: begin alu_issue_uop[0*64 +: 64] = iq_entries[23].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[23].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[23].thread_id; end
                5'd24: begin alu_issue_uop[0*64 +: 64] = iq_entries[24].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[24].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[24].thread_id; end
                5'd25: begin alu_issue_uop[0*64 +: 64] = iq_entries[25].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[25].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[25].thread_id; end
                5'd26: begin alu_issue_uop[0*64 +: 64] = iq_entries[26].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[26].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[26].thread_id; end
                5'd27: begin alu_issue_uop[0*64 +: 64] = iq_entries[27].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[27].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[27].thread_id; end
                5'd28: begin alu_issue_uop[0*64 +: 64] = iq_entries[28].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[28].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[28].thread_id; end
                5'd29: begin alu_issue_uop[0*64 +: 64] = iq_entries[29].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[29].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[29].thread_id; end
                5'd30: begin alu_issue_uop[0*64 +: 64] = iq_entries[30].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[30].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[30].thread_id; end
                5'd31: begin alu_issue_uop[0*64 +: 64] = iq_entries[31].uop; alu_issue_rob_id[0*6 +: 6] = iq_entries[31].rob_id; alu_issue_thread_id[0*2 +: 2] = iq_entries[31].thread_id; end
                default: begin alu_issue_uop[0*64 +: 64] = 64'b0; alu_issue_rob_id[0*6 +: 6] = 6'b0; alu_issue_thread_id[0*2 +: 2] = 2'b0; end
            endcase
        end else begin
            alu_issue_uop[0*64 +: 64] = 64'b0;
            alu_issue_rob_id[0*6 +: 6] = 6'b0;
            alu_issue_thread_id[0*2 +: 2] = 2'b0;
        end
        
        // ALU 1
        alu_selected_idx = selected_alu_flat[1*5 +: 5];
        alu_issue_valid[1] = (alu_selected_idx != 5'b11111);
        if (alu_issue_valid[1]) begin
            // Use case statement to avoid dynamic indexing
            case (alu_selected_idx)
                5'd0:  begin alu_issue_uop[1*64 +: 64] = iq_entries[0].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[0].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[0].thread_id; end
                5'd1:  begin alu_issue_uop[1*64 +: 64] = iq_entries[1].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[1].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[1].thread_id; end
                5'd2:  begin alu_issue_uop[1*64 +: 64] = iq_entries[2].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[2].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[2].thread_id; end
                5'd3:  begin alu_issue_uop[1*64 +: 64] = iq_entries[3].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[3].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[3].thread_id; end
                5'd4:  begin alu_issue_uop[1*64 +: 64] = iq_entries[4].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[4].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[4].thread_id; end
                5'd5:  begin alu_issue_uop[1*64 +: 64] = iq_entries[5].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[5].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[5].thread_id; end
                5'd6:  begin alu_issue_uop[1*64 +: 64] = iq_entries[6].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[6].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[6].thread_id; end
                5'd7:  begin alu_issue_uop[1*64 +: 64] = iq_entries[7].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[7].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[7].thread_id; end
                5'd8:  begin alu_issue_uop[1*64 +: 64] = iq_entries[8].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[8].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[8].thread_id; end
                5'd9:  begin alu_issue_uop[1*64 +: 64] = iq_entries[9].uop;  alu_issue_rob_id[1*6 +: 6] = iq_entries[9].rob_id;  alu_issue_thread_id[1*2 +: 2] = iq_entries[9].thread_id; end
                5'd10: begin alu_issue_uop[1*64 +: 64] = iq_entries[10].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[10].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[10].thread_id; end
                5'd11: begin alu_issue_uop[1*64 +: 64] = iq_entries[11].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[11].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[11].thread_id; end
                5'd12: begin alu_issue_uop[1*64 +: 64] = iq_entries[12].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[12].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[12].thread_id; end
                5'd13: begin alu_issue_uop[1*64 +: 64] = iq_entries[13].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[13].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[13].thread_id; end
                5'd14: begin alu_issue_uop[1*64 +: 64] = iq_entries[14].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[14].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[14].thread_id; end
                5'd15: begin alu_issue_uop[1*64 +: 64] = iq_entries[15].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[15].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[15].thread_id; end
                5'd16: begin alu_issue_uop[1*64 +: 64] = iq_entries[16].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[16].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[16].thread_id; end
                5'd17: begin alu_issue_uop[1*64 +: 64] = iq_entries[17].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[17].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[17].thread_id; end
                5'd18: begin alu_issue_uop[1*64 +: 64] = iq_entries[18].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[18].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[18].thread_id; end
                5'd19: begin alu_issue_uop[1*64 +: 64] = iq_entries[19].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[19].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[19].thread_id; end
                5'd20: begin alu_issue_uop[1*64 +: 64] = iq_entries[20].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[20].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[20].thread_id; end
                5'd21: begin alu_issue_uop[1*64 +: 64] = iq_entries[21].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[21].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[21].thread_id; end
                5'd22: begin alu_issue_uop[1*64 +: 64] = iq_entries[22].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[22].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[22].thread_id; end
                5'd23: begin alu_issue_uop[1*64 +: 64] = iq_entries[23].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[23].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[23].thread_id; end
                5'd24: begin alu_issue_uop[1*64 +: 64] = iq_entries[24].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[24].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[24].thread_id; end
                5'd25: begin alu_issue_uop[1*64 +: 64] = iq_entries[25].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[25].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[25].thread_id; end
                5'd26: begin alu_issue_uop[1*64 +: 64] = iq_entries[26].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[26].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[26].thread_id; end
                5'd27: begin alu_issue_uop[1*64 +: 64] = iq_entries[27].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[27].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[27].thread_id; end
                5'd28: begin alu_issue_uop[1*64 +: 64] = iq_entries[28].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[28].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[28].thread_id; end
                5'd29: begin alu_issue_uop[1*64 +: 64] = iq_entries[29].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[29].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[29].thread_id; end
                5'd30: begin alu_issue_uop[1*64 +: 64] = iq_entries[30].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[30].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[30].thread_id; end
                5'd31: begin alu_issue_uop[1*64 +: 64] = iq_entries[31].uop; alu_issue_rob_id[1*6 +: 6] = iq_entries[31].rob_id; alu_issue_thread_id[1*2 +: 2] = iq_entries[31].thread_id; end
                default: begin alu_issue_uop[1*64 +: 64] = 64'b0; alu_issue_rob_id[1*6 +: 6] = 6'b0; alu_issue_thread_id[1*2 +: 2] = 2'b0; end
            endcase
        end else begin
            alu_issue_uop[1*64 +: 64] = 64'b0;
            alu_issue_rob_id[1*6 +: 6] = 6'b0;
            alu_issue_thread_id[1*2 +: 2] = 2'b0;
        end
        
        agu_issue_valid = (selected_agu != 5'b11111);
        if (agu_issue_valid) begin
            case (selected_agu)
                5'd0:  begin agu_issue_uop = iq_entries[0].uop;  agu_issue_rob_id = iq_entries[0].rob_id;  agu_issue_thread_id = iq_entries[0].thread_id; end
                5'd1:  begin agu_issue_uop = iq_entries[1].uop;  agu_issue_rob_id = iq_entries[1].rob_id;  agu_issue_thread_id = iq_entries[1].thread_id; end
                5'd2:  begin agu_issue_uop = iq_entries[2].uop;  agu_issue_rob_id = iq_entries[2].rob_id;  agu_issue_thread_id = iq_entries[2].thread_id; end
                5'd3:  begin agu_issue_uop = iq_entries[3].uop;  agu_issue_rob_id = iq_entries[3].rob_id;  agu_issue_thread_id = iq_entries[3].thread_id; end
                5'd4:  begin agu_issue_uop = iq_entries[4].uop;  agu_issue_rob_id = iq_entries[4].rob_id;  agu_issue_thread_id = iq_entries[4].thread_id; end
                5'd5:  begin agu_issue_uop = iq_entries[5].uop;  agu_issue_rob_id = iq_entries[5].rob_id;  agu_issue_thread_id = iq_entries[5].thread_id; end
                5'd6:  begin agu_issue_uop = iq_entries[6].uop;  agu_issue_rob_id = iq_entries[6].rob_id;  agu_issue_thread_id = iq_entries[6].thread_id; end
                5'd7:  begin agu_issue_uop = iq_entries[7].uop;  agu_issue_rob_id = iq_entries[7].rob_id;  agu_issue_thread_id = iq_entries[7].thread_id; end
                5'd8:  begin agu_issue_uop = iq_entries[8].uop;  agu_issue_rob_id = iq_entries[8].rob_id;  agu_issue_thread_id = iq_entries[8].thread_id; end
                5'd9:  begin agu_issue_uop = iq_entries[9].uop;  agu_issue_rob_id = iq_entries[9].rob_id;  agu_issue_thread_id = iq_entries[9].thread_id; end
                5'd10: begin agu_issue_uop = iq_entries[10].uop; agu_issue_rob_id = iq_entries[10].rob_id; agu_issue_thread_id = iq_entries[10].thread_id; end
                5'd11: begin agu_issue_uop = iq_entries[11].uop; agu_issue_rob_id = iq_entries[11].rob_id; agu_issue_thread_id = iq_entries[11].thread_id; end
                5'd12: begin agu_issue_uop = iq_entries[12].uop; agu_issue_rob_id = iq_entries[12].rob_id; agu_issue_thread_id = iq_entries[12].thread_id; end
                5'd13: begin agu_issue_uop = iq_entries[13].uop; agu_issue_rob_id = iq_entries[13].rob_id; agu_issue_thread_id = iq_entries[13].thread_id; end
                5'd14: begin agu_issue_uop = iq_entries[14].uop; agu_issue_rob_id = iq_entries[14].rob_id; agu_issue_thread_id = iq_entries[14].thread_id; end
                5'd15: begin agu_issue_uop = iq_entries[15].uop; agu_issue_rob_id = iq_entries[15].rob_id; agu_issue_thread_id = iq_entries[15].thread_id; end
                5'd16: begin agu_issue_uop = iq_entries[16].uop; agu_issue_rob_id = iq_entries[16].rob_id; agu_issue_thread_id = iq_entries[16].thread_id; end
                5'd17: begin agu_issue_uop = iq_entries[17].uop; agu_issue_rob_id = iq_entries[17].rob_id; agu_issue_thread_id = iq_entries[17].thread_id; end
                5'd18: begin agu_issue_uop = iq_entries[18].uop; agu_issue_rob_id = iq_entries[18].rob_id; agu_issue_thread_id = iq_entries[18].thread_id; end
                5'd19: begin agu_issue_uop = iq_entries[19].uop; agu_issue_rob_id = iq_entries[19].rob_id; agu_issue_thread_id = iq_entries[19].thread_id; end
                5'd20: begin agu_issue_uop = iq_entries[20].uop; agu_issue_rob_id = iq_entries[20].rob_id; agu_issue_thread_id = iq_entries[20].thread_id; end
                5'd21: begin agu_issue_uop = iq_entries[21].uop; agu_issue_rob_id = iq_entries[21].rob_id; agu_issue_thread_id = iq_entries[21].thread_id; end
                5'd22: begin agu_issue_uop = iq_entries[22].uop; agu_issue_rob_id = iq_entries[22].rob_id; agu_issue_thread_id = iq_entries[22].thread_id; end
                5'd23: begin agu_issue_uop = iq_entries[23].uop; agu_issue_rob_id = iq_entries[23].rob_id; agu_issue_thread_id = iq_entries[23].thread_id; end
                5'd24: begin agu_issue_uop = iq_entries[24].uop; agu_issue_rob_id = iq_entries[24].rob_id; agu_issue_thread_id = iq_entries[24].thread_id; end
                5'd25: begin agu_issue_uop = iq_entries[25].uop; agu_issue_rob_id = iq_entries[25].rob_id; agu_issue_thread_id = iq_entries[25].thread_id; end
                5'd26: begin agu_issue_uop = iq_entries[26].uop; agu_issue_rob_id = iq_entries[26].rob_id; agu_issue_thread_id = iq_entries[26].thread_id; end
                5'd27: begin agu_issue_uop = iq_entries[27].uop; agu_issue_rob_id = iq_entries[27].rob_id; agu_issue_thread_id = iq_entries[27].thread_id; end
                5'd28: begin agu_issue_uop = iq_entries[28].uop; agu_issue_rob_id = iq_entries[28].rob_id; agu_issue_thread_id = iq_entries[28].thread_id; end
                5'd29: begin agu_issue_uop = iq_entries[29].uop; agu_issue_rob_id = iq_entries[29].rob_id; agu_issue_thread_id = iq_entries[29].thread_id; end
                5'd30: begin agu_issue_uop = iq_entries[30].uop; agu_issue_rob_id = iq_entries[30].rob_id; agu_issue_thread_id = iq_entries[30].thread_id; end
                5'd31: begin agu_issue_uop = iq_entries[31].uop; agu_issue_rob_id = iq_entries[31].rob_id; agu_issue_thread_id = iq_entries[31].thread_id; end
                default: begin agu_issue_uop = 64'b0; agu_issue_rob_id = 6'b0; agu_issue_thread_id = 2'b0; end
            endcase
        end else begin
            agu_issue_uop = 64'b0;
            agu_issue_rob_id = 6'b0;
            agu_issue_thread_id = 2'b0;
        end
        
        mul_issue_valid = (selected_mul != 5'b11111);
        if (mul_issue_valid) begin
            case (selected_mul)
                5'd0:  begin mul_issue_uop = iq_entries[0].uop;  mul_issue_rob_id = iq_entries[0].rob_id;  mul_issue_thread_id = iq_entries[0].thread_id; end
                5'd1:  begin mul_issue_uop = iq_entries[1].uop;  mul_issue_rob_id = iq_entries[1].rob_id;  mul_issue_thread_id = iq_entries[1].thread_id; end
                5'd2:  begin mul_issue_uop = iq_entries[2].uop;  mul_issue_rob_id = iq_entries[2].rob_id;  mul_issue_thread_id = iq_entries[2].thread_id; end
                5'd3:  begin mul_issue_uop = iq_entries[3].uop;  mul_issue_rob_id = iq_entries[3].rob_id;  mul_issue_thread_id = iq_entries[3].thread_id; end
                5'd4:  begin mul_issue_uop = iq_entries[4].uop;  mul_issue_rob_id = iq_entries[4].rob_id;  mul_issue_thread_id = iq_entries[4].thread_id; end
                5'd5:  begin mul_issue_uop = iq_entries[5].uop;  mul_issue_rob_id = iq_entries[5].rob_id;  mul_issue_thread_id = iq_entries[5].thread_id; end
                5'd6:  begin mul_issue_uop = iq_entries[6].uop;  mul_issue_rob_id = iq_entries[6].rob_id;  mul_issue_thread_id = iq_entries[6].thread_id; end
                5'd7:  begin mul_issue_uop = iq_entries[7].uop;  mul_issue_rob_id = iq_entries[7].rob_id;  mul_issue_thread_id = iq_entries[7].thread_id; end
                5'd8:  begin mul_issue_uop = iq_entries[8].uop;  mul_issue_rob_id = iq_entries[8].rob_id;  mul_issue_thread_id = iq_entries[8].thread_id; end
                5'd9:  begin mul_issue_uop = iq_entries[9].uop;  mul_issue_rob_id = iq_entries[9].rob_id;  mul_issue_thread_id = iq_entries[9].thread_id; end
                5'd10: begin mul_issue_uop = iq_entries[10].uop; mul_issue_rob_id = iq_entries[10].rob_id; mul_issue_thread_id = iq_entries[10].thread_id; end
                5'd11: begin mul_issue_uop = iq_entries[11].uop; mul_issue_rob_id = iq_entries[11].rob_id; mul_issue_thread_id = iq_entries[11].thread_id; end
                5'd12: begin mul_issue_uop = iq_entries[12].uop; mul_issue_rob_id = iq_entries[12].rob_id; mul_issue_thread_id = iq_entries[12].thread_id; end
                5'd13: begin mul_issue_uop = iq_entries[13].uop; mul_issue_rob_id = iq_entries[13].rob_id; mul_issue_thread_id = iq_entries[13].thread_id; end
                5'd14: begin mul_issue_uop = iq_entries[14].uop; mul_issue_rob_id = iq_entries[14].rob_id; mul_issue_thread_id = iq_entries[14].thread_id; end
                5'd15: begin mul_issue_uop = iq_entries[15].uop; mul_issue_rob_id = iq_entries[15].rob_id; mul_issue_thread_id = iq_entries[15].thread_id; end
                5'd16: begin mul_issue_uop = iq_entries[16].uop; mul_issue_rob_id = iq_entries[16].rob_id; mul_issue_thread_id = iq_entries[16].thread_id; end
                5'd17: begin mul_issue_uop = iq_entries[17].uop; mul_issue_rob_id = iq_entries[17].rob_id; mul_issue_thread_id = iq_entries[17].thread_id; end
                5'd18: begin mul_issue_uop = iq_entries[18].uop; mul_issue_rob_id = iq_entries[18].rob_id; mul_issue_thread_id = iq_entries[18].thread_id; end
                5'd19: begin mul_issue_uop = iq_entries[19].uop; mul_issue_rob_id = iq_entries[19].rob_id; mul_issue_thread_id = iq_entries[19].thread_id; end
                5'd20: begin mul_issue_uop = iq_entries[20].uop; mul_issue_rob_id = iq_entries[20].rob_id; mul_issue_thread_id = iq_entries[20].thread_id; end
                5'd21: begin mul_issue_uop = iq_entries[21].uop; mul_issue_rob_id = iq_entries[21].rob_id; mul_issue_thread_id = iq_entries[21].thread_id; end
                5'd22: begin mul_issue_uop = iq_entries[22].uop; mul_issue_rob_id = iq_entries[22].rob_id; mul_issue_thread_id = iq_entries[22].thread_id; end
                5'd23: begin mul_issue_uop = iq_entries[23].uop; mul_issue_rob_id = iq_entries[23].rob_id; mul_issue_thread_id = iq_entries[23].thread_id; end
                5'd24: begin mul_issue_uop = iq_entries[24].uop; mul_issue_rob_id = iq_entries[24].rob_id; mul_issue_thread_id = iq_entries[24].thread_id; end
                5'd25: begin mul_issue_uop = iq_entries[25].uop; mul_issue_rob_id = iq_entries[25].rob_id; mul_issue_thread_id = iq_entries[25].thread_id; end
                5'd26: begin mul_issue_uop = iq_entries[26].uop; mul_issue_rob_id = iq_entries[26].rob_id; mul_issue_thread_id = iq_entries[26].thread_id; end
                5'd27: begin mul_issue_uop = iq_entries[27].uop; mul_issue_rob_id = iq_entries[27].rob_id; mul_issue_thread_id = iq_entries[27].thread_id; end
                5'd28: begin mul_issue_uop = iq_entries[28].uop; mul_issue_rob_id = iq_entries[28].rob_id; mul_issue_thread_id = iq_entries[28].thread_id; end
                5'd29: begin mul_issue_uop = iq_entries[29].uop; mul_issue_rob_id = iq_entries[29].rob_id; mul_issue_thread_id = iq_entries[29].thread_id; end
                5'd30: begin mul_issue_uop = iq_entries[30].uop; mul_issue_rob_id = iq_entries[30].rob_id; mul_issue_thread_id = iq_entries[30].thread_id; end
                5'd31: begin mul_issue_uop = iq_entries[31].uop; mul_issue_rob_id = iq_entries[31].rob_id; mul_issue_thread_id = iq_entries[31].thread_id; end
                default: begin mul_issue_uop = 64'b0; mul_issue_rob_id = 6'b0; mul_issue_thread_id = 2'b0; end
            endcase
        end else begin
            mul_issue_uop = 64'b0;
            mul_issue_rob_id = 6'b0;
            mul_issue_thread_id = 2'b0;
        end
        
        div_issue_valid = (selected_div != 5'b11111);
        if (div_issue_valid) begin
            case (selected_div)
                5'd0:  begin div_issue_uop = iq_entries[0].uop;  div_issue_rob_id = iq_entries[0].rob_id;  div_issue_thread_id = iq_entries[0].thread_id; end
                5'd1:  begin div_issue_uop = iq_entries[1].uop;  div_issue_rob_id = iq_entries[1].rob_id;  div_issue_thread_id = iq_entries[1].thread_id; end
                5'd2:  begin div_issue_uop = iq_entries[2].uop;  div_issue_rob_id = iq_entries[2].rob_id;  div_issue_thread_id = iq_entries[2].thread_id; end
                5'd3:  begin div_issue_uop = iq_entries[3].uop;  div_issue_rob_id = iq_entries[3].rob_id;  div_issue_thread_id = iq_entries[3].thread_id; end
                5'd4:  begin div_issue_uop = iq_entries[4].uop;  div_issue_rob_id = iq_entries[4].rob_id;  div_issue_thread_id = iq_entries[4].thread_id; end
                5'd5:  begin div_issue_uop = iq_entries[5].uop;  div_issue_rob_id = iq_entries[5].rob_id;  div_issue_thread_id = iq_entries[5].thread_id; end
                5'd6:  begin div_issue_uop = iq_entries[6].uop;  div_issue_rob_id = iq_entries[6].rob_id;  div_issue_thread_id = iq_entries[6].thread_id; end
                5'd7:  begin div_issue_uop = iq_entries[7].uop;  div_issue_rob_id = iq_entries[7].rob_id;  div_issue_thread_id = iq_entries[7].thread_id; end
                5'd8:  begin div_issue_uop = iq_entries[8].uop;  div_issue_rob_id = iq_entries[8].rob_id;  div_issue_thread_id = iq_entries[8].thread_id; end
                5'd9:  begin div_issue_uop = iq_entries[9].uop;  div_issue_rob_id = iq_entries[9].rob_id;  div_issue_thread_id = iq_entries[9].thread_id; end
                5'd10: begin div_issue_uop = iq_entries[10].uop; div_issue_rob_id = iq_entries[10].rob_id; div_issue_thread_id = iq_entries[10].thread_id; end
                5'd11: begin div_issue_uop = iq_entries[11].uop; div_issue_rob_id = iq_entries[11].rob_id; div_issue_thread_id = iq_entries[11].thread_id; end
                5'd12: begin div_issue_uop = iq_entries[12].uop; div_issue_rob_id = iq_entries[12].rob_id; div_issue_thread_id = iq_entries[12].thread_id; end
                5'd13: begin div_issue_uop = iq_entries[13].uop; div_issue_rob_id = iq_entries[13].rob_id; div_issue_thread_id = iq_entries[13].thread_id; end
                5'd14: begin div_issue_uop = iq_entries[14].uop; div_issue_rob_id = iq_entries[14].rob_id; div_issue_thread_id = iq_entries[14].thread_id; end
                5'd15: begin div_issue_uop = iq_entries[15].uop; div_issue_rob_id = iq_entries[15].rob_id; div_issue_thread_id = iq_entries[15].thread_id; end
                5'd16: begin div_issue_uop = iq_entries[16].uop; div_issue_rob_id = iq_entries[16].rob_id; div_issue_thread_id = iq_entries[16].thread_id; end
                5'd17: begin div_issue_uop = iq_entries[17].uop; div_issue_rob_id = iq_entries[17].rob_id; div_issue_thread_id = iq_entries[17].thread_id; end
                5'd18: begin div_issue_uop = iq_entries[18].uop; div_issue_rob_id = iq_entries[18].rob_id; div_issue_thread_id = iq_entries[18].thread_id; end
                5'd19: begin div_issue_uop = iq_entries[19].uop; div_issue_rob_id = iq_entries[19].rob_id; div_issue_thread_id = iq_entries[19].thread_id; end
                5'd20: begin div_issue_uop = iq_entries[20].uop; div_issue_rob_id = iq_entries[20].rob_id; div_issue_thread_id = iq_entries[20].thread_id; end
                5'd21: begin div_issue_uop = iq_entries[21].uop; div_issue_rob_id = iq_entries[21].rob_id; div_issue_thread_id = iq_entries[21].thread_id; end
                5'd22: begin div_issue_uop = iq_entries[22].uop; div_issue_rob_id = iq_entries[22].rob_id; div_issue_thread_id = iq_entries[22].thread_id; end
                5'd23: begin div_issue_uop = iq_entries[23].uop; div_issue_rob_id = iq_entries[23].rob_id; div_issue_thread_id = iq_entries[23].thread_id; end
                5'd24: begin div_issue_uop = iq_entries[24].uop; div_issue_rob_id = iq_entries[24].rob_id; div_issue_thread_id = iq_entries[24].thread_id; end
                5'd25: begin div_issue_uop = iq_entries[25].uop; div_issue_rob_id = iq_entries[25].rob_id; div_issue_thread_id = iq_entries[25].thread_id; end
                5'd26: begin div_issue_uop = iq_entries[26].uop; div_issue_rob_id = iq_entries[26].rob_id; div_issue_thread_id = iq_entries[26].thread_id; end
                5'd27: begin div_issue_uop = iq_entries[27].uop; div_issue_rob_id = iq_entries[27].rob_id; div_issue_thread_id = iq_entries[27].thread_id; end
                5'd28: begin div_issue_uop = iq_entries[28].uop; div_issue_rob_id = iq_entries[28].rob_id; div_issue_thread_id = iq_entries[28].thread_id; end
                5'd29: begin div_issue_uop = iq_entries[29].uop; div_issue_rob_id = iq_entries[29].rob_id; div_issue_thread_id = iq_entries[29].thread_id; end
                5'd30: begin div_issue_uop = iq_entries[30].uop; div_issue_rob_id = iq_entries[30].rob_id; div_issue_thread_id = iq_entries[30].thread_id; end
                5'd31: begin div_issue_uop = iq_entries[31].uop; div_issue_rob_id = iq_entries[31].rob_id; div_issue_thread_id = iq_entries[31].thread_id; end
                default: begin div_issue_uop = 64'b0; div_issue_rob_id = 6'b0; div_issue_thread_id = 2'b0; end
            endcase
        end else begin
            div_issue_uop = 64'b0;
            div_issue_rob_id = 6'b0;
            div_issue_thread_id = 2'b0;
        end
        
        // FPU 0
        fpu_selected_idx = selected_fpu_flat[0*5 +: 5];
        fpu_issue_valid[0] = (fpu_selected_idx != 5'b11111);
        if (fpu_issue_valid[0]) begin
            case (fpu_selected_idx)
                5'd0:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[0].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[0].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[0].thread_id; end
                5'd1:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[1].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[1].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[1].thread_id; end
                5'd2:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[2].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[2].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[2].thread_id; end
                5'd3:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[3].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[3].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[3].thread_id; end
                5'd4:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[4].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[4].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[4].thread_id; end
                5'd5:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[5].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[5].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[5].thread_id; end
                5'd6:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[6].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[6].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[6].thread_id; end
                5'd7:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[7].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[7].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[7].thread_id; end
                5'd8:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[8].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[8].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[8].thread_id; end
                5'd9:  begin fpu_issue_uop[0*64 +: 64] = iq_entries[9].uop;  fpu_issue_rob_id[0*6 +: 6] = iq_entries[9].rob_id;  fpu_issue_thread_id[0*2 +: 2] = iq_entries[9].thread_id; end
                5'd10: begin fpu_issue_uop[0*64 +: 64] = iq_entries[10].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[10].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[10].thread_id; end
                5'd11: begin fpu_issue_uop[0*64 +: 64] = iq_entries[11].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[11].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[11].thread_id; end
                5'd12: begin fpu_issue_uop[0*64 +: 64] = iq_entries[12].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[12].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[12].thread_id; end
                5'd13: begin fpu_issue_uop[0*64 +: 64] = iq_entries[13].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[13].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[13].thread_id; end
                5'd14: begin fpu_issue_uop[0*64 +: 64] = iq_entries[14].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[14].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[14].thread_id; end
                5'd15: begin fpu_issue_uop[0*64 +: 64] = iq_entries[15].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[15].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[15].thread_id; end
                5'd16: begin fpu_issue_uop[0*64 +: 64] = iq_entries[16].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[16].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[16].thread_id; end
                5'd17: begin fpu_issue_uop[0*64 +: 64] = iq_entries[17].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[17].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[17].thread_id; end
                5'd18: begin fpu_issue_uop[0*64 +: 64] = iq_entries[18].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[18].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[18].thread_id; end
                5'd19: begin fpu_issue_uop[0*64 +: 64] = iq_entries[19].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[19].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[19].thread_id; end
                5'd20: begin fpu_issue_uop[0*64 +: 64] = iq_entries[20].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[20].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[20].thread_id; end
                5'd21: begin fpu_issue_uop[0*64 +: 64] = iq_entries[21].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[21].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[21].thread_id; end
                5'd22: begin fpu_issue_uop[0*64 +: 64] = iq_entries[22].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[22].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[22].thread_id; end
                5'd23: begin fpu_issue_uop[0*64 +: 64] = iq_entries[23].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[23].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[23].thread_id; end
                5'd24: begin fpu_issue_uop[0*64 +: 64] = iq_entries[24].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[24].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[24].thread_id; end
                5'd25: begin fpu_issue_uop[0*64 +: 64] = iq_entries[25].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[25].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[25].thread_id; end
                5'd26: begin fpu_issue_uop[0*64 +: 64] = iq_entries[26].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[26].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[26].thread_id; end
                5'd27: begin fpu_issue_uop[0*64 +: 64] = iq_entries[27].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[27].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[27].thread_id; end
                5'd28: begin fpu_issue_uop[0*64 +: 64] = iq_entries[28].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[28].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[28].thread_id; end
                5'd29: begin fpu_issue_uop[0*64 +: 64] = iq_entries[29].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[29].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[29].thread_id; end
                5'd30: begin fpu_issue_uop[0*64 +: 64] = iq_entries[30].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[30].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[30].thread_id; end
                5'd31: begin fpu_issue_uop[0*64 +: 64] = iq_entries[31].uop; fpu_issue_rob_id[0*6 +: 6] = iq_entries[31].rob_id; fpu_issue_thread_id[0*2 +: 2] = iq_entries[31].thread_id; end
                default: begin fpu_issue_uop[0*64 +: 64] = 64'b0; fpu_issue_rob_id[0*6 +: 6] = 6'b0; fpu_issue_thread_id[0*2 +: 2] = 2'b0; end
            endcase
        end else begin
            fpu_issue_uop[0*64 +: 64] = 64'b0;
            fpu_issue_rob_id[0*6 +: 6] = 6'b0;
            fpu_issue_thread_id[0*2 +: 2] = 2'b0;
        end
        
        // FPU 1
        fpu_selected_idx = selected_fpu_flat[1*5 +: 5];
        fpu_issue_valid[1] = (fpu_selected_idx != 5'b11111);
        if (fpu_issue_valid[1]) begin
            case (fpu_selected_idx)
                5'd0:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[0].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[0].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[0].thread_id; end
                5'd1:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[1].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[1].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[1].thread_id; end
                5'd2:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[2].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[2].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[2].thread_id; end
                5'd3:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[3].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[3].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[3].thread_id; end
                5'd4:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[4].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[4].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[4].thread_id; end
                5'd5:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[5].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[5].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[5].thread_id; end
                5'd6:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[6].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[6].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[6].thread_id; end
                5'd7:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[7].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[7].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[7].thread_id; end
                5'd8:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[8].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[8].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[8].thread_id; end
                5'd9:  begin fpu_issue_uop[1*64 +: 64] = iq_entries[9].uop;  fpu_issue_rob_id[1*6 +: 6] = iq_entries[9].rob_id;  fpu_issue_thread_id[1*2 +: 2] = iq_entries[9].thread_id; end
                5'd10: begin fpu_issue_uop[1*64 +: 64] = iq_entries[10].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[10].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[10].thread_id; end
                5'd11: begin fpu_issue_uop[1*64 +: 64] = iq_entries[11].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[11].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[11].thread_id; end
                5'd12: begin fpu_issue_uop[1*64 +: 64] = iq_entries[12].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[12].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[12].thread_id; end
                5'd13: begin fpu_issue_uop[1*64 +: 64] = iq_entries[13].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[13].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[13].thread_id; end
                5'd14: begin fpu_issue_uop[1*64 +: 64] = iq_entries[14].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[14].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[14].thread_id; end
                5'd15: begin fpu_issue_uop[1*64 +: 64] = iq_entries[15].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[15].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[15].thread_id; end
                5'd16: begin fpu_issue_uop[1*64 +: 64] = iq_entries[16].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[16].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[16].thread_id; end
                5'd17: begin fpu_issue_uop[1*64 +: 64] = iq_entries[17].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[17].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[17].thread_id; end
                5'd18: begin fpu_issue_uop[1*64 +: 64] = iq_entries[18].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[18].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[18].thread_id; end
                5'd19: begin fpu_issue_uop[1*64 +: 64] = iq_entries[19].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[19].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[19].thread_id; end
                5'd20: begin fpu_issue_uop[1*64 +: 64] = iq_entries[20].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[20].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[20].thread_id; end
                5'd21: begin fpu_issue_uop[1*64 +: 64] = iq_entries[21].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[21].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[21].thread_id; end
                5'd22: begin fpu_issue_uop[1*64 +: 64] = iq_entries[22].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[22].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[22].thread_id; end
                5'd23: begin fpu_issue_uop[1*64 +: 64] = iq_entries[23].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[23].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[23].thread_id; end
                5'd24: begin fpu_issue_uop[1*64 +: 64] = iq_entries[24].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[24].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[24].thread_id; end
                5'd25: begin fpu_issue_uop[1*64 +: 64] = iq_entries[25].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[25].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[25].thread_id; end
                5'd26: begin fpu_issue_uop[1*64 +: 64] = iq_entries[26].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[26].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[26].thread_id; end
                5'd27: begin fpu_issue_uop[1*64 +: 64] = iq_entries[27].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[27].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[27].thread_id; end
                5'd28: begin fpu_issue_uop[1*64 +: 64] = iq_entries[28].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[28].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[28].thread_id; end
                5'd29: begin fpu_issue_uop[1*64 +: 64] = iq_entries[29].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[29].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[29].thread_id; end
                5'd30: begin fpu_issue_uop[1*64 +: 64] = iq_entries[30].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[30].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[30].thread_id; end
                5'd31: begin fpu_issue_uop[1*64 +: 64] = iq_entries[31].uop; fpu_issue_rob_id[1*6 +: 6] = iq_entries[31].rob_id; fpu_issue_thread_id[1*2 +: 2] = iq_entries[31].thread_id; end
                default: begin fpu_issue_uop[1*64 +: 64] = 64'b0; fpu_issue_rob_id[1*6 +: 6] = 6'b0; fpu_issue_thread_id[1*2 +: 2] = 2'b0; end
            endcase
        end else begin
            fpu_issue_uop[1*64 +: 64] = 64'b0;
            fpu_issue_rob_id[1*6 +: 6] = 6'b0;
            fpu_issue_thread_id[1*2 +: 2] = 2'b0;
        end
    end
    
    // =========================================================================
    // Issue Queue Management
    // =========================================================================
    
    logic [1:0] issued_this_cycle;
    logic [31:0] thread_diff;
    
    // Variables for issue queue management (moved outside always block)
    logic [4:0] idx;                  // For allocation indexing
    logic [3:0] uop_type;             // For UOP type extraction
    logic [4:0] alu_issued_idx;       // For ALU issue marking
    logic [4:0] fpu_issued_idx;       // For FPU issue marking
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize all IQ entries to zero
            for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
                iq_entries[i].valid <= 1'b0;
                iq_entries[i].ready <= 1'b0;
                iq_entries[i].issued <= 1'b0;
                iq_entries[i].uop <= 64'b0;
                iq_entries[i].rob_id <= 6'b0;
                iq_entries[i].thread_id <= 2'b0;
                iq_entries[i].uop_type <= 4'b0;
                iq_entries[i].exec_unit_type <= 3'b0;
                iq_entries[i].age <= 32'b0;
                iq_entries[i].src1_ready <= 1'b0;
                iq_entries[i].src2_ready <= 1'b0;
                iq_entries[i].src1_tag <= 8'b0;
                iq_entries[i].src2_tag <= 8'b0;
            end
            iq_entry_valid <= 32'b0;  // Explicit bit width
            iq_head <= 5'b0;
            iq_tail <= 5'b0;
            iq_count <= 6'b0;
            global_age_counter <= 32'b0;
            // Initialize thread counters
            for (j = 0; j < NUM_THREADS; j = j + 1) begin
                thread_issue_count[j] <= 32'b0;
            end
            last_issued_thread <= 2'b0;
            // Initialize thread priority array
            for (i = 0; i < NUM_THREADS; i = i + 1) begin
                thread_priority[i] <= 1'b0;
            end
            perf_issue_stalls <= 32'b0;
            perf_thread_stalls_0 <= 32'b0;
            perf_thread_stalls_1 <= 32'b0;
        end else begin
            
            global_age_counter <= global_age_counter + 1;
            
            // =============================================
            // Allocation Phase
            // =============================================
            
            // Allocation 0
            if (alloc_valid[0]) begin
                idx = alloc_iq_idx[0*5 +: 5];      // Flattened indexing
                uop_type = rob_uops[0*64 +: 4];    // Fixed flattened indexing
                
                case (idx)
                    5'd0:  begin iq_entries[0].valid <= 1'b1; iq_entries[0].ready <= 1'b0; iq_entries[0].issued <= 1'b0; iq_entries[0].uop <= rob_uops[0*64 +: 64]; iq_entries[0].rob_id <= rob_id[0*6 +: 6]; iq_entries[0].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[0].uop_type <= uop_type; iq_entries[0].age <= global_age_counter; end
                    5'd1:  begin iq_entries[1].valid <= 1'b1; iq_entries[1].ready <= 1'b0; iq_entries[1].issued <= 1'b0; iq_entries[1].uop <= rob_uops[0*64 +: 64]; iq_entries[1].rob_id <= rob_id[0*6 +: 6]; iq_entries[1].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[1].uop_type <= uop_type; iq_entries[1].age <= global_age_counter; end
                    5'd2:  begin iq_entries[2].valid <= 1'b1; iq_entries[2].ready <= 1'b0; iq_entries[2].issued <= 1'b0; iq_entries[2].uop <= rob_uops[0*64 +: 64]; iq_entries[2].rob_id <= rob_id[0*6 +: 6]; iq_entries[2].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[2].uop_type <= uop_type; iq_entries[2].age <= global_age_counter; end
                    5'd3:  begin iq_entries[3].valid <= 1'b1; iq_entries[3].ready <= 1'b0; iq_entries[3].issued <= 1'b0; iq_entries[3].uop <= rob_uops[0*64 +: 64]; iq_entries[3].rob_id <= rob_id[0*6 +: 6]; iq_entries[3].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[3].uop_type <= uop_type; iq_entries[3].age <= global_age_counter; end
                    5'd4:  begin iq_entries[4].valid <= 1'b1; iq_entries[4].ready <= 1'b0; iq_entries[4].issued <= 1'b0; iq_entries[4].uop <= rob_uops[0*64 +: 64]; iq_entries[4].rob_id <= rob_id[0*6 +: 6]; iq_entries[4].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[4].uop_type <= uop_type; iq_entries[4].age <= global_age_counter; end
                    5'd5:  begin iq_entries[5].valid <= 1'b1; iq_entries[5].ready <= 1'b0; iq_entries[5].issued <= 1'b0; iq_entries[5].uop <= rob_uops[0*64 +: 64]; iq_entries[5].rob_id <= rob_id[0*6 +: 6]; iq_entries[5].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[5].uop_type <= uop_type; iq_entries[5].age <= global_age_counter; end
                    5'd6:  begin iq_entries[6].valid <= 1'b1; iq_entries[6].ready <= 1'b0; iq_entries[6].issued <= 1'b0; iq_entries[6].uop <= rob_uops[0*64 +: 64]; iq_entries[6].rob_id <= rob_id[0*6 +: 6]; iq_entries[6].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[6].uop_type <= uop_type; iq_entries[6].age <= global_age_counter; end
                    5'd7:  begin iq_entries[7].valid <= 1'b1; iq_entries[7].ready <= 1'b0; iq_entries[7].issued <= 1'b0; iq_entries[7].uop <= rob_uops[0*64 +: 64]; iq_entries[7].rob_id <= rob_id[0*6 +: 6]; iq_entries[7].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[7].uop_type <= uop_type; iq_entries[7].age <= global_age_counter; end
                    5'd8:  begin iq_entries[8].valid <= 1'b1; iq_entries[8].ready <= 1'b0; iq_entries[8].issued <= 1'b0; iq_entries[8].uop <= rob_uops[0*64 +: 64]; iq_entries[8].rob_id <= rob_id[0*6 +: 6]; iq_entries[8].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[8].uop_type <= uop_type; iq_entries[8].age <= global_age_counter; end
                    5'd9:  begin iq_entries[9].valid <= 1'b1; iq_entries[9].ready <= 1'b0; iq_entries[9].issued <= 1'b0; iq_entries[9].uop <= rob_uops[0*64 +: 64]; iq_entries[9].rob_id <= rob_id[0*6 +: 6]; iq_entries[9].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[9].uop_type <= uop_type; iq_entries[9].age <= global_age_counter; end
                    5'd10: begin iq_entries[10].valid <= 1'b1; iq_entries[10].ready <= 1'b0; iq_entries[10].issued <= 1'b0; iq_entries[10].uop <= rob_uops[0*64 +: 64]; iq_entries[10].rob_id <= rob_id[0*6 +: 6]; iq_entries[10].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[10].uop_type <= uop_type; iq_entries[10].age <= global_age_counter; end
                    5'd11: begin iq_entries[11].valid <= 1'b1; iq_entries[11].ready <= 1'b0; iq_entries[11].issued <= 1'b0; iq_entries[11].uop <= rob_uops[0*64 +: 64]; iq_entries[11].rob_id <= rob_id[0*6 +: 6]; iq_entries[11].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[11].uop_type <= uop_type; iq_entries[11].age <= global_age_counter; end
                    5'd12: begin iq_entries[12].valid <= 1'b1; iq_entries[12].ready <= 1'b0; iq_entries[12].issued <= 1'b0; iq_entries[12].uop <= rob_uops[0*64 +: 64]; iq_entries[12].rob_id <= rob_id[0*6 +: 6]; iq_entries[12].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[12].uop_type <= uop_type; iq_entries[12].age <= global_age_counter; end
                    5'd13: begin iq_entries[13].valid <= 1'b1; iq_entries[13].ready <= 1'b0; iq_entries[13].issued <= 1'b0; iq_entries[13].uop <= rob_uops[0*64 +: 64]; iq_entries[13].rob_id <= rob_id[0*6 +: 6]; iq_entries[13].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[13].uop_type <= uop_type; iq_entries[13].age <= global_age_counter; end
                    5'd14: begin iq_entries[14].valid <= 1'b1; iq_entries[14].ready <= 1'b0; iq_entries[14].issued <= 1'b0; iq_entries[14].uop <= rob_uops[0*64 +: 64]; iq_entries[14].rob_id <= rob_id[0*6 +: 6]; iq_entries[14].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[14].uop_type <= uop_type; iq_entries[14].age <= global_age_counter; end
                    5'd15: begin iq_entries[15].valid <= 1'b1; iq_entries[15].ready <= 1'b0; iq_entries[15].issued <= 1'b0; iq_entries[15].uop <= rob_uops[0*64 +: 64]; iq_entries[15].rob_id <= rob_id[0*6 +: 6]; iq_entries[15].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[15].uop_type <= uop_type; iq_entries[15].age <= global_age_counter; end
                    5'd16: begin iq_entries[16].valid <= 1'b1; iq_entries[16].ready <= 1'b0; iq_entries[16].issued <= 1'b0; iq_entries[16].uop <= rob_uops[0*64 +: 64]; iq_entries[16].rob_id <= rob_id[0*6 +: 6]; iq_entries[16].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[16].uop_type <= uop_type; iq_entries[16].age <= global_age_counter; end
                    5'd17: begin iq_entries[17].valid <= 1'b1; iq_entries[17].ready <= 1'b0; iq_entries[17].issued <= 1'b0; iq_entries[17].uop <= rob_uops[0*64 +: 64]; iq_entries[17].rob_id <= rob_id[0*6 +: 6]; iq_entries[17].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[17].uop_type <= uop_type; iq_entries[17].age <= global_age_counter; end
                    5'd18: begin iq_entries[18].valid <= 1'b1; iq_entries[18].ready <= 1'b0; iq_entries[18].issued <= 1'b0; iq_entries[18].uop <= rob_uops[0*64 +: 64]; iq_entries[18].rob_id <= rob_id[0*6 +: 6]; iq_entries[18].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[18].uop_type <= uop_type; iq_entries[18].age <= global_age_counter; end
                    5'd19: begin iq_entries[19].valid <= 1'b1; iq_entries[19].ready <= 1'b0; iq_entries[19].issued <= 1'b0; iq_entries[19].uop <= rob_uops[0*64 +: 64]; iq_entries[19].rob_id <= rob_id[0*6 +: 6]; iq_entries[19].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[19].uop_type <= uop_type; iq_entries[19].age <= global_age_counter; end
                    5'd20: begin iq_entries[20].valid <= 1'b1; iq_entries[20].ready <= 1'b0; iq_entries[20].issued <= 1'b0; iq_entries[20].uop <= rob_uops[0*64 +: 64]; iq_entries[20].rob_id <= rob_id[0*6 +: 6]; iq_entries[20].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[20].uop_type <= uop_type; iq_entries[20].age <= global_age_counter; end
                    5'd21: begin iq_entries[21].valid <= 1'b1; iq_entries[21].ready <= 1'b0; iq_entries[21].issued <= 1'b0; iq_entries[21].uop <= rob_uops[0*64 +: 64]; iq_entries[21].rob_id <= rob_id[0*6 +: 6]; iq_entries[21].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[21].uop_type <= uop_type; iq_entries[21].age <= global_age_counter; end
                    5'd22: begin iq_entries[22].valid <= 1'b1; iq_entries[22].ready <= 1'b0; iq_entries[22].issued <= 1'b0; iq_entries[22].uop <= rob_uops[0*64 +: 64]; iq_entries[22].rob_id <= rob_id[0*6 +: 6]; iq_entries[22].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[22].uop_type <= uop_type; iq_entries[22].age <= global_age_counter; end
                    5'd23: begin iq_entries[23].valid <= 1'b1; iq_entries[23].ready <= 1'b0; iq_entries[23].issued <= 1'b0; iq_entries[23].uop <= rob_uops[0*64 +: 64]; iq_entries[23].rob_id <= rob_id[0*6 +: 6]; iq_entries[23].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[23].uop_type <= uop_type; iq_entries[23].age <= global_age_counter; end
                    5'd24: begin iq_entries[24].valid <= 1'b1; iq_entries[24].ready <= 1'b0; iq_entries[24].issued <= 1'b0; iq_entries[24].uop <= rob_uops[0*64 +: 64]; iq_entries[24].rob_id <= rob_id[0*6 +: 6]; iq_entries[24].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[24].uop_type <= uop_type; iq_entries[24].age <= global_age_counter; end
                    5'd25: begin iq_entries[25].valid <= 1'b1; iq_entries[25].ready <= 1'b0; iq_entries[25].issued <= 1'b0; iq_entries[25].uop <= rob_uops[0*64 +: 64]; iq_entries[25].rob_id <= rob_id[0*6 +: 6]; iq_entries[25].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[25].uop_type <= uop_type; iq_entries[25].age <= global_age_counter; end
                    5'd26: begin iq_entries[26].valid <= 1'b1; iq_entries[26].ready <= 1'b0; iq_entries[26].issued <= 1'b0; iq_entries[26].uop <= rob_uops[0*64 +: 64]; iq_entries[26].rob_id <= rob_id[0*6 +: 6]; iq_entries[26].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[26].uop_type <= uop_type; iq_entries[26].age <= global_age_counter; end
                    5'd27: begin iq_entries[27].valid <= 1'b1; iq_entries[27].ready <= 1'b0; iq_entries[27].issued <= 1'b0; iq_entries[27].uop <= rob_uops[0*64 +: 64]; iq_entries[27].rob_id <= rob_id[0*6 +: 6]; iq_entries[27].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[27].uop_type <= uop_type; iq_entries[27].age <= global_age_counter; end
                    5'd28: begin iq_entries[28].valid <= 1'b1; iq_entries[28].ready <= 1'b0; iq_entries[28].issued <= 1'b0; iq_entries[28].uop <= rob_uops[0*64 +: 64]; iq_entries[28].rob_id <= rob_id[0*6 +: 6]; iq_entries[28].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[28].uop_type <= uop_type; iq_entries[28].age <= global_age_counter; end
                    5'd29: begin iq_entries[29].valid <= 1'b1; iq_entries[29].ready <= 1'b0; iq_entries[29].issued <= 1'b0; iq_entries[29].uop <= rob_uops[0*64 +: 64]; iq_entries[29].rob_id <= rob_id[0*6 +: 6]; iq_entries[29].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[29].uop_type <= uop_type; iq_entries[29].age <= global_age_counter; end
                    5'd30: begin iq_entries[30].valid <= 1'b1; iq_entries[30].ready <= 1'b0; iq_entries[30].issued <= 1'b0; iq_entries[30].uop <= rob_uops[0*64 +: 64]; iq_entries[30].rob_id <= rob_id[0*6 +: 6]; iq_entries[30].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[30].uop_type <= uop_type; iq_entries[30].age <= global_age_counter; end
                    5'd31: begin iq_entries[31].valid <= 1'b1; iq_entries[31].ready <= 1'b0; iq_entries[31].issued <= 1'b0; iq_entries[31].uop <= rob_uops[0*64 +: 64]; iq_entries[31].rob_id <= rob_id[0*6 +: 6]; iq_entries[31].thread_id <= rob_thread_id[0*2 +: 2]; iq_entries[31].uop_type <= uop_type; iq_entries[31].age <= global_age_counter; end
                endcase
                
                // Determine execution unit type
                case (uop_type)
                    4'b0001: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                    4'b0010: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                    4'b0011: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_AGU; 5'd1: iq_entries[1].exec_unit_type <= EU_AGU; 5'd2: iq_entries[2].exec_unit_type <= EU_AGU; 5'd3: iq_entries[3].exec_unit_type <= EU_AGU; 5'd4: iq_entries[4].exec_unit_type <= EU_AGU; 5'd5: iq_entries[5].exec_unit_type <= EU_AGU; 5'd6: iq_entries[6].exec_unit_type <= EU_AGU; 5'd7: iq_entries[7].exec_unit_type <= EU_AGU; 5'd8: iq_entries[8].exec_unit_type <= EU_AGU; 5'd9: iq_entries[9].exec_unit_type <= EU_AGU; 5'd10: iq_entries[10].exec_unit_type <= EU_AGU; 5'd11: iq_entries[11].exec_unit_type <= EU_AGU; 5'd12: iq_entries[12].exec_unit_type <= EU_AGU; 5'd13: iq_entries[13].exec_unit_type <= EU_AGU; 5'd14: iq_entries[14].exec_unit_type <= EU_AGU; 5'd15: iq_entries[15].exec_unit_type <= EU_AGU; 5'd16: iq_entries[16].exec_unit_type <= EU_AGU; 5'd17: iq_entries[17].exec_unit_type <= EU_AGU; 5'd18: iq_entries[18].exec_unit_type <= EU_AGU; 5'd19: iq_entries[19].exec_unit_type <= EU_AGU; 5'd20: iq_entries[20].exec_unit_type <= EU_AGU; 5'd21: iq_entries[21].exec_unit_type <= EU_AGU; 5'd22: iq_entries[22].exec_unit_type <= EU_AGU; 5'd23: iq_entries[23].exec_unit_type <= EU_AGU; 5'd24: iq_entries[24].exec_unit_type <= EU_AGU; 5'd25: iq_entries[25].exec_unit_type <= EU_AGU; 5'd26: iq_entries[26].exec_unit_type <= EU_AGU; 5'd27: iq_entries[27].exec_unit_type <= EU_AGU; 5'd28: iq_entries[28].exec_unit_type <= EU_AGU; 5'd29: iq_entries[29].exec_unit_type <= EU_AGU; 5'd30: iq_entries[30].exec_unit_type <= EU_AGU; 5'd31: iq_entries[31].exec_unit_type <= EU_AGU;
                    endcase
                    4'b0100: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                    4'b0101: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_MUL; 5'd1: iq_entries[1].exec_unit_type <= EU_MUL; 5'd2: iq_entries[2].exec_unit_type <= EU_MUL; 5'd3: iq_entries[3].exec_unit_type <= EU_MUL; 5'd4: iq_entries[4].exec_unit_type <= EU_MUL; 5'd5: iq_entries[5].exec_unit_type <= EU_MUL; 5'd6: iq_entries[6].exec_unit_type <= EU_MUL; 5'd7: iq_entries[7].exec_unit_type <= EU_MUL; 5'd8: iq_entries[8].exec_unit_type <= EU_MUL; 5'd9: iq_entries[9].exec_unit_type <= EU_MUL; 5'd10: iq_entries[10].exec_unit_type <= EU_MUL; 5'd11: iq_entries[11].exec_unit_type <= EU_MUL; 5'd12: iq_entries[12].exec_unit_type <= EU_MUL; 5'd13: iq_entries[13].exec_unit_type <= EU_MUL; 5'd14: iq_entries[14].exec_unit_type <= EU_MUL; 5'd15: iq_entries[15].exec_unit_type <= EU_MUL; 5'd16: iq_entries[16].exec_unit_type <= EU_MUL; 5'd17: iq_entries[17].exec_unit_type <= EU_MUL; 5'd18: iq_entries[18].exec_unit_type <= EU_MUL; 5'd19: iq_entries[19].exec_unit_type <= EU_MUL; 5'd20: iq_entries[20].exec_unit_type <= EU_MUL; 5'd21: iq_entries[21].exec_unit_type <= EU_MUL; 5'd22: iq_entries[22].exec_unit_type <= EU_MUL; 5'd23: iq_entries[23].exec_unit_type <= EU_MUL; 5'd24: iq_entries[24].exec_unit_type <= EU_MUL; 5'd25: iq_entries[25].exec_unit_type <= EU_MUL; 5'd26: iq_entries[26].exec_unit_type <= EU_MUL; 5'd27: iq_entries[27].exec_unit_type <= EU_MUL; 5'd28: iq_entries[28].exec_unit_type <= EU_MUL; 5'd29: iq_entries[29].exec_unit_type <= EU_MUL; 5'd30: iq_entries[30].exec_unit_type <= EU_MUL; 5'd31: iq_entries[31].exec_unit_type <= EU_MUL;
                    endcase
                    4'b0110: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_DIV; 5'd1: iq_entries[1].exec_unit_type <= EU_DIV; 5'd2: iq_entries[2].exec_unit_type <= EU_DIV; 5'd3: iq_entries[3].exec_unit_type <= EU_DIV; 5'd4: iq_entries[4].exec_unit_type <= EU_DIV; 5'd5: iq_entries[5].exec_unit_type <= EU_DIV; 5'd6: iq_entries[6].exec_unit_type <= EU_DIV; 5'd7: iq_entries[7].exec_unit_type <= EU_DIV; 5'd8: iq_entries[8].exec_unit_type <= EU_DIV; 5'd9: iq_entries[9].exec_unit_type <= EU_DIV; 5'd10: iq_entries[10].exec_unit_type <= EU_DIV; 5'd11: iq_entries[11].exec_unit_type <= EU_DIV; 5'd12: iq_entries[12].exec_unit_type <= EU_DIV; 5'd13: iq_entries[13].exec_unit_type <= EU_DIV; 5'd14: iq_entries[14].exec_unit_type <= EU_DIV; 5'd15: iq_entries[15].exec_unit_type <= EU_DIV; 5'd16: iq_entries[16].exec_unit_type <= EU_DIV; 5'd17: iq_entries[17].exec_unit_type <= EU_DIV; 5'd18: iq_entries[18].exec_unit_type <= EU_DIV; 5'd19: iq_entries[19].exec_unit_type <= EU_DIV; 5'd20: iq_entries[20].exec_unit_type <= EU_DIV; 5'd21: iq_entries[21].exec_unit_type <= EU_DIV; 5'd22: iq_entries[22].exec_unit_type <= EU_DIV; 5'd23: iq_entries[23].exec_unit_type <= EU_DIV; 5'd24: iq_entries[24].exec_unit_type <= EU_DIV; 5'd25: iq_entries[25].exec_unit_type <= EU_DIV; 5'd26: iq_entries[26].exec_unit_type <= EU_DIV; 5'd27: iq_entries[27].exec_unit_type <= EU_DIV; 5'd28: iq_entries[28].exec_unit_type <= EU_DIV; 5'd29: iq_entries[29].exec_unit_type <= EU_DIV; 5'd30: iq_entries[30].exec_unit_type <= EU_DIV; 5'd31: iq_entries[31].exec_unit_type <= EU_DIV;
                    endcase
                    4'b0111: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_FPU; 5'd1: iq_entries[1].exec_unit_type <= EU_FPU; 5'd2: iq_entries[2].exec_unit_type <= EU_FPU; 5'd3: iq_entries[3].exec_unit_type <= EU_FPU; 5'd4: iq_entries[4].exec_unit_type <= EU_FPU; 5'd5: iq_entries[5].exec_unit_type <= EU_FPU; 5'd6: iq_entries[6].exec_unit_type <= EU_FPU; 5'd7: iq_entries[7].exec_unit_type <= EU_FPU; 5'd8: iq_entries[8].exec_unit_type <= EU_FPU; 5'd9: iq_entries[9].exec_unit_type <= EU_FPU; 5'd10: iq_entries[10].exec_unit_type <= EU_FPU; 5'd11: iq_entries[11].exec_unit_type <= EU_FPU; 5'd12: iq_entries[12].exec_unit_type <= EU_FPU; 5'd13: iq_entries[13].exec_unit_type <= EU_FPU; 5'd14: iq_entries[14].exec_unit_type <= EU_FPU; 5'd15: iq_entries[15].exec_unit_type <= EU_FPU; 5'd16: iq_entries[16].exec_unit_type <= EU_FPU; 5'd17: iq_entries[17].exec_unit_type <= EU_FPU; 5'd18: iq_entries[18].exec_unit_type <= EU_FPU; 5'd19: iq_entries[19].exec_unit_type <= EU_FPU; 5'd20: iq_entries[20].exec_unit_type <= EU_FPU; 5'd21: iq_entries[21].exec_unit_type <= EU_FPU; 5'd22: iq_entries[22].exec_unit_type <= EU_FPU; 5'd23: iq_entries[23].exec_unit_type <= EU_FPU; 5'd24: iq_entries[24].exec_unit_type <= EU_FPU; 5'd25: iq_entries[25].exec_unit_type <= EU_FPU; 5'd26: iq_entries[26].exec_unit_type <= EU_FPU; 5'd27: iq_entries[27].exec_unit_type <= EU_FPU; 5'd28: iq_entries[28].exec_unit_type <= EU_FPU; 5'd29: iq_entries[29].exec_unit_type <= EU_FPU; 5'd30: iq_entries[30].exec_unit_type <= EU_FPU; 5'd31: iq_entries[31].exec_unit_type <= EU_FPU;
                    endcase
                    4'b1000: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_FPU; 5'd1: iq_entries[1].exec_unit_type <= EU_FPU; 5'd2: iq_entries[2].exec_unit_type <= EU_FPU; 5'd3: iq_entries[3].exec_unit_type <= EU_FPU; 5'd4: iq_entries[4].exec_unit_type <= EU_FPU; 5'd5: iq_entries[5].exec_unit_type <= EU_FPU; 5'd6: iq_entries[6].exec_unit_type <= EU_FPU; 5'd7: iq_entries[7].exec_unit_type <= EU_FPU; 5'd8: iq_entries[8].exec_unit_type <= EU_FPU; 5'd9: iq_entries[9].exec_unit_type <= EU_FPU; 5'd10: iq_entries[10].exec_unit_type <= EU_FPU; 5'd11: iq_entries[11].exec_unit_type <= EU_FPU; 5'd12: iq_entries[12].exec_unit_type <= EU_FPU; 5'd13: iq_entries[13].exec_unit_type <= EU_FPU; 5'd14: iq_entries[14].exec_unit_type <= EU_FPU; 5'd15: iq_entries[15].exec_unit_type <= EU_FPU; 5'd16: iq_entries[16].exec_unit_type <= EU_FPU; 5'd17: iq_entries[17].exec_unit_type <= EU_FPU; 5'd18: iq_entries[18].exec_unit_type <= EU_FPU; 5'd19: iq_entries[19].exec_unit_type <= EU_FPU; 5'd20: iq_entries[20].exec_unit_type <= EU_FPU; 5'd21: iq_entries[21].exec_unit_type <= EU_FPU; 5'd22: iq_entries[22].exec_unit_type <= EU_FPU; 5'd23: iq_entries[23].exec_unit_type <= EU_FPU; 5'd24: iq_entries[24].exec_unit_type <= EU_FPU; 5'd25: iq_entries[25].exec_unit_type <= EU_FPU; 5'd26: iq_entries[26].exec_unit_type <= EU_FPU; 5'd27: iq_entries[27].exec_unit_type <= EU_FPU; 5'd28: iq_entries[28].exec_unit_type <= EU_FPU; 5'd29: iq_entries[29].exec_unit_type <= EU_FPU; 5'd30: iq_entries[30].exec_unit_type <= EU_FPU; 5'd31: iq_entries[31].exec_unit_type <= EU_FPU;
                    endcase
                    default: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                endcase
                
                iq_count <= iq_count + 1;
            end
            
            // Allocation 1
            if (alloc_valid[1]) begin
                idx = alloc_iq_idx[1*5 +: 5];
                uop_type = rob_uops[1*64 +: 4];
                
                case (idx)
                    5'd0:  begin iq_entries[0].valid <= 1'b1; iq_entries[0].ready <= 1'b0; iq_entries[0].issued <= 1'b0; iq_entries[0].uop <= rob_uops[1*64 +: 64]; iq_entries[0].rob_id <= rob_id[1*6 +: 6]; iq_entries[0].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[0].uop_type <= uop_type; iq_entries[0].age <= global_age_counter; end
                    5'd1:  begin iq_entries[1].valid <= 1'b1; iq_entries[1].ready <= 1'b0; iq_entries[1].issued <= 1'b0; iq_entries[1].uop <= rob_uops[1*64 +: 64]; iq_entries[1].rob_id <= rob_id[1*6 +: 6]; iq_entries[1].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[1].uop_type <= uop_type; iq_entries[1].age <= global_age_counter; end
                    5'd2:  begin iq_entries[2].valid <= 1'b1; iq_entries[2].ready <= 1'b0; iq_entries[2].issued <= 1'b0; iq_entries[2].uop <= rob_uops[1*64 +: 64]; iq_entries[2].rob_id <= rob_id[1*6 +: 6]; iq_entries[2].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[2].uop_type <= uop_type; iq_entries[2].age <= global_age_counter; end
                    5'd3:  begin iq_entries[3].valid <= 1'b1; iq_entries[3].ready <= 1'b0; iq_entries[3].issued <= 1'b0; iq_entries[3].uop <= rob_uops[1*64 +: 64]; iq_entries[3].rob_id <= rob_id[1*6 +: 6]; iq_entries[3].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[3].uop_type <= uop_type; iq_entries[3].age <= global_age_counter; end
                    5'd4:  begin iq_entries[4].valid <= 1'b1; iq_entries[4].ready <= 1'b0; iq_entries[4].issued <= 1'b0; iq_entries[4].uop <= rob_uops[1*64 +: 64]; iq_entries[4].rob_id <= rob_id[1*6 +: 6]; iq_entries[4].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[4].uop_type <= uop_type; iq_entries[4].age <= global_age_counter; end
                    5'd5:  begin iq_entries[5].valid <= 1'b1; iq_entries[5].ready <= 1'b0; iq_entries[5].issued <= 1'b0; iq_entries[5].uop <= rob_uops[1*64 +: 64]; iq_entries[5].rob_id <= rob_id[1*6 +: 6]; iq_entries[5].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[5].uop_type <= uop_type; iq_entries[5].age <= global_age_counter; end
                    5'd6:  begin iq_entries[6].valid <= 1'b1; iq_entries[6].ready <= 1'b0; iq_entries[6].issued <= 1'b0; iq_entries[6].uop <= rob_uops[1*64 +: 64]; iq_entries[6].rob_id <= rob_id[1*6 +: 6]; iq_entries[6].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[6].uop_type <= uop_type; iq_entries[6].age <= global_age_counter; end
                    5'd7:  begin iq_entries[7].valid <= 1'b1; iq_entries[7].ready <= 1'b0; iq_entries[7].issued <= 1'b0; iq_entries[7].uop <= rob_uops[1*64 +: 64]; iq_entries[7].rob_id <= rob_id[1*6 +: 6]; iq_entries[7].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[7].uop_type <= uop_type; iq_entries[7].age <= global_age_counter; end
                    5'd8:  begin iq_entries[8].valid <= 1'b1; iq_entries[8].ready <= 1'b0; iq_entries[8].issued <= 1'b0; iq_entries[8].uop <= rob_uops[1*64 +: 64]; iq_entries[8].rob_id <= rob_id[1*6 +: 6]; iq_entries[8].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[8].uop_type <= uop_type; iq_entries[8].age <= global_age_counter; end
                    5'd9:  begin iq_entries[9].valid <= 1'b1; iq_entries[9].ready <= 1'b0; iq_entries[9].issued <= 1'b0; iq_entries[9].uop <= rob_uops[1*64 +: 64]; iq_entries[9].rob_id <= rob_id[1*6 +: 6]; iq_entries[9].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[9].uop_type <= uop_type; iq_entries[9].age <= global_age_counter; end
                    5'd10: begin iq_entries[10].valid <= 1'b1; iq_entries[10].ready <= 1'b0; iq_entries[10].issued <= 1'b0; iq_entries[10].uop <= rob_uops[1*64 +: 64]; iq_entries[10].rob_id <= rob_id[1*6 +: 6]; iq_entries[10].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[10].uop_type <= uop_type; iq_entries[10].age <= global_age_counter; end
                    5'd11: begin iq_entries[11].valid <= 1'b1; iq_entries[11].ready <= 1'b0; iq_entries[11].issued <= 1'b0; iq_entries[11].uop <= rob_uops[1*64 +: 64]; iq_entries[11].rob_id <= rob_id[1*6 +: 6]; iq_entries[11].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[11].uop_type <= uop_type; iq_entries[11].age <= global_age_counter; end
                    5'd12: begin iq_entries[12].valid <= 1'b1; iq_entries[12].ready <= 1'b0; iq_entries[12].issued <= 1'b0; iq_entries[12].uop <= rob_uops[1*64 +: 64]; iq_entries[12].rob_id <= rob_id[1*6 +: 6]; iq_entries[12].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[12].uop_type <= uop_type; iq_entries[12].age <= global_age_counter; end
                    5'd13: begin iq_entries[13].valid <= 1'b1; iq_entries[13].ready <= 1'b0; iq_entries[13].issued <= 1'b0; iq_entries[13].uop <= rob_uops[1*64 +: 64]; iq_entries[13].rob_id <= rob_id[1*6 +: 6]; iq_entries[13].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[13].uop_type <= uop_type; iq_entries[13].age <= global_age_counter; end
                    5'd14: begin iq_entries[14].valid <= 1'b1; iq_entries[14].ready <= 1'b0; iq_entries[14].issued <= 1'b0; iq_entries[14].uop <= rob_uops[1*64 +: 64]; iq_entries[14].rob_id <= rob_id[1*6 +: 6]; iq_entries[14].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[14].uop_type <= uop_type; iq_entries[14].age <= global_age_counter; end
                    5'd15: begin iq_entries[15].valid <= 1'b1; iq_entries[15].ready <= 1'b0; iq_entries[15].issued <= 1'b0; iq_entries[15].uop <= rob_uops[1*64 +: 64]; iq_entries[15].rob_id <= rob_id[1*6 +: 6]; iq_entries[15].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[15].uop_type <= uop_type; iq_entries[15].age <= global_age_counter; end
                    5'd16: begin iq_entries[16].valid <= 1'b1; iq_entries[16].ready <= 1'b0; iq_entries[16].issued <= 1'b0; iq_entries[16].uop <= rob_uops[1*64 +: 64]; iq_entries[16].rob_id <= rob_id[1*6 +: 6]; iq_entries[16].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[16].uop_type <= uop_type; iq_entries[16].age <= global_age_counter; end
                    5'd17: begin iq_entries[17].valid <= 1'b1; iq_entries[17].ready <= 1'b0; iq_entries[17].issued <= 1'b0; iq_entries[17].uop <= rob_uops[1*64 +: 64]; iq_entries[17].rob_id <= rob_id[1*6 +: 6]; iq_entries[17].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[17].uop_type <= uop_type; iq_entries[17].age <= global_age_counter; end
                    5'd18: begin iq_entries[18].valid <= 1'b1; iq_entries[18].ready <= 1'b0; iq_entries[18].issued <= 1'b0; iq_entries[18].uop <= rob_uops[1*64 +: 64]; iq_entries[18].rob_id <= rob_id[1*6 +: 6]; iq_entries[18].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[18].uop_type <= uop_type; iq_entries[18].age <= global_age_counter; end
                    5'd19: begin iq_entries[19].valid <= 1'b1; iq_entries[19].ready <= 1'b0; iq_entries[19].issued <= 1'b0; iq_entries[19].uop <= rob_uops[1*64 +: 64]; iq_entries[19].rob_id <= rob_id[1*6 +: 6]; iq_entries[19].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[19].uop_type <= uop_type; iq_entries[19].age <= global_age_counter; end
                    5'd20: begin iq_entries[20].valid <= 1'b1; iq_entries[20].ready <= 1'b0; iq_entries[20].issued <= 1'b0; iq_entries[20].uop <= rob_uops[1*64 +: 64]; iq_entries[20].rob_id <= rob_id[1*6 +: 6]; iq_entries[20].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[20].uop_type <= uop_type; iq_entries[20].age <= global_age_counter; end
                    5'd21: begin iq_entries[21].valid <= 1'b1; iq_entries[21].ready <= 1'b0; iq_entries[21].issued <= 1'b0; iq_entries[21].uop <= rob_uops[1*64 +: 64]; iq_entries[21].rob_id <= rob_id[1*6 +: 6]; iq_entries[21].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[21].uop_type <= uop_type; iq_entries[21].age <= global_age_counter; end
                    5'd22: begin iq_entries[22].valid <= 1'b1; iq_entries[22].ready <= 1'b0; iq_entries[22].issued <= 1'b0; iq_entries[22].uop <= rob_uops[1*64 +: 64]; iq_entries[22].rob_id <= rob_id[1*6 +: 6]; iq_entries[22].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[22].uop_type <= uop_type; iq_entries[22].age <= global_age_counter; end
                    5'd23: begin iq_entries[23].valid <= 1'b1; iq_entries[23].ready <= 1'b0; iq_entries[23].issued <= 1'b0; iq_entries[23].uop <= rob_uops[1*64 +: 64]; iq_entries[23].rob_id <= rob_id[1*6 +: 6]; iq_entries[23].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[23].uop_type <= uop_type; iq_entries[23].age <= global_age_counter; end
                    5'd24: begin iq_entries[24].valid <= 1'b1; iq_entries[24].ready <= 1'b0; iq_entries[24].issued <= 1'b0; iq_entries[24].uop <= rob_uops[1*64 +: 64]; iq_entries[24].rob_id <= rob_id[1*6 +: 6]; iq_entries[24].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[24].uop_type <= uop_type; iq_entries[24].age <= global_age_counter; end
                    5'd25: begin iq_entries[25].valid <= 1'b1; iq_entries[25].ready <= 1'b0; iq_entries[25].issued <= 1'b0; iq_entries[25].uop <= rob_uops[1*64 +: 64]; iq_entries[25].rob_id <= rob_id[1*6 +: 6]; iq_entries[25].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[25].uop_type <= uop_type; iq_entries[25].age <= global_age_counter; end
                    5'd26: begin iq_entries[26].valid <= 1'b1; iq_entries[26].ready <= 1'b0; iq_entries[26].issued <= 1'b0; iq_entries[26].uop <= rob_uops[1*64 +: 64]; iq_entries[26].rob_id <= rob_id[1*6 +: 6]; iq_entries[26].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[26].uop_type <= uop_type; iq_entries[26].age <= global_age_counter; end
                    5'd27: begin iq_entries[27].valid <= 1'b1; iq_entries[27].ready <= 1'b0; iq_entries[27].issued <= 1'b0; iq_entries[27].uop <= rob_uops[1*64 +: 64]; iq_entries[27].rob_id <= rob_id[1*6 +: 6]; iq_entries[27].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[27].uop_type <= uop_type; iq_entries[27].age <= global_age_counter; end
                    5'd28: begin iq_entries[28].valid <= 1'b1; iq_entries[28].ready <= 1'b0; iq_entries[28].issued <= 1'b0; iq_entries[28].uop <= rob_uops[1*64 +: 64]; iq_entries[28].rob_id <= rob_id[1*6 +: 6]; iq_entries[28].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[28].uop_type <= uop_type; iq_entries[28].age <= global_age_counter; end
                    5'd29: begin iq_entries[29].valid <= 1'b1; iq_entries[29].ready <= 1'b0; iq_entries[29].issued <= 1'b0; iq_entries[29].uop <= rob_uops[1*64 +: 64]; iq_entries[29].rob_id <= rob_id[1*6 +: 6]; iq_entries[29].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[29].uop_type <= uop_type; iq_entries[29].age <= global_age_counter; end
                    5'd30: begin iq_entries[30].valid <= 1'b1; iq_entries[30].ready <= 1'b0; iq_entries[30].issued <= 1'b0; iq_entries[30].uop <= rob_uops[1*64 +: 64]; iq_entries[30].rob_id <= rob_id[1*6 +: 6]; iq_entries[30].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[30].uop_type <= uop_type; iq_entries[30].age <= global_age_counter; end
                    5'd31: begin iq_entries[31].valid <= 1'b1; iq_entries[31].ready <= 1'b0; iq_entries[31].issued <= 1'b0; iq_entries[31].uop <= rob_uops[1*64 +: 64]; iq_entries[31].rob_id <= rob_id[1*6 +: 6]; iq_entries[31].thread_id <= rob_thread_id[1*2 +: 2]; iq_entries[31].uop_type <= uop_type; iq_entries[31].age <= global_age_counter; end
                endcase
                
                case (uop_type)
                    4'b0001, 4'b0010, 4'b0100: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                    4'b0011: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_AGU; 5'd1: iq_entries[1].exec_unit_type <= EU_AGU; 5'd2: iq_entries[2].exec_unit_type <= EU_AGU; 5'd3: iq_entries[3].exec_unit_type <= EU_AGU; 5'd4: iq_entries[4].exec_unit_type <= EU_AGU; 5'd5: iq_entries[5].exec_unit_type <= EU_AGU; 5'd6: iq_entries[6].exec_unit_type <= EU_AGU; 5'd7: iq_entries[7].exec_unit_type <= EU_AGU; 5'd8: iq_entries[8].exec_unit_type <= EU_AGU; 5'd9: iq_entries[9].exec_unit_type <= EU_AGU; 5'd10: iq_entries[10].exec_unit_type <= EU_AGU; 5'd11: iq_entries[11].exec_unit_type <= EU_AGU; 5'd12: iq_entries[12].exec_unit_type <= EU_AGU; 5'd13: iq_entries[13].exec_unit_type <= EU_AGU; 5'd14: iq_entries[14].exec_unit_type <= EU_AGU; 5'd15: iq_entries[15].exec_unit_type <= EU_AGU; 5'd16: iq_entries[16].exec_unit_type <= EU_AGU; 5'd17: iq_entries[17].exec_unit_type <= EU_AGU; 5'd18: iq_entries[18].exec_unit_type <= EU_AGU; 5'd19: iq_entries[19].exec_unit_type <= EU_AGU; 5'd20: iq_entries[20].exec_unit_type <= EU_AGU; 5'd21: iq_entries[21].exec_unit_type <= EU_AGU; 5'd22: iq_entries[22].exec_unit_type <= EU_AGU; 5'd23: iq_entries[23].exec_unit_type <= EU_AGU; 5'd24: iq_entries[24].exec_unit_type <= EU_AGU; 5'd25: iq_entries[25].exec_unit_type <= EU_AGU; 5'd26: iq_entries[26].exec_unit_type <= EU_AGU; 5'd27: iq_entries[27].exec_unit_type <= EU_AGU; 5'd28: iq_entries[28].exec_unit_type <= EU_AGU; 5'd29: iq_entries[29].exec_unit_type <= EU_AGU; 5'd30: iq_entries[30].exec_unit_type <= EU_AGU; 5'd31: iq_entries[31].exec_unit_type <= EU_AGU;
                    endcase
                    4'b0101: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_MUL; 5'd1: iq_entries[1].exec_unit_type <= EU_MUL; 5'd2: iq_entries[2].exec_unit_type <= EU_MUL; 5'd3: iq_entries[3].exec_unit_type <= EU_MUL; 5'd4: iq_entries[4].exec_unit_type <= EU_MUL; 5'd5: iq_entries[5].exec_unit_type <= EU_MUL; 5'd6: iq_entries[6].exec_unit_type <= EU_MUL; 5'd7: iq_entries[7].exec_unit_type <= EU_MUL; 5'd8: iq_entries[8].exec_unit_type <= EU_MUL; 5'd9: iq_entries[9].exec_unit_type <= EU_MUL; 5'd10: iq_entries[10].exec_unit_type <= EU_MUL; 5'd11: iq_entries[11].exec_unit_type <= EU_MUL; 5'd12: iq_entries[12].exec_unit_type <= EU_MUL; 5'd13: iq_entries[13].exec_unit_type <= EU_MUL; 5'd14: iq_entries[14].exec_unit_type <= EU_MUL; 5'd15: iq_entries[15].exec_unit_type <= EU_MUL; 5'd16: iq_entries[16].exec_unit_type <= EU_MUL; 5'd17: iq_entries[17].exec_unit_type <= EU_MUL; 5'd18: iq_entries[18].exec_unit_type <= EU_MUL; 5'd19: iq_entries[19].exec_unit_type <= EU_MUL; 5'd20: iq_entries[20].exec_unit_type <= EU_MUL; 5'd21: iq_entries[21].exec_unit_type <= EU_MUL; 5'd22: iq_entries[22].exec_unit_type <= EU_MUL; 5'd23: iq_entries[23].exec_unit_type <= EU_MUL; 5'd24: iq_entries[24].exec_unit_type <= EU_MUL; 5'd25: iq_entries[25].exec_unit_type <= EU_MUL; 5'd26: iq_entries[26].exec_unit_type <= EU_MUL; 5'd27: iq_entries[27].exec_unit_type <= EU_MUL; 5'd28: iq_entries[28].exec_unit_type <= EU_MUL; 5'd29: iq_entries[29].exec_unit_type <= EU_MUL; 5'd30: iq_entries[30].exec_unit_type <= EU_MUL; 5'd31: iq_entries[31].exec_unit_type <= EU_MUL;
                    endcase
                    4'b0110: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_DIV; 5'd1: iq_entries[1].exec_unit_type <= EU_DIV; 5'd2: iq_entries[2].exec_unit_type <= EU_DIV; 5'd3: iq_entries[3].exec_unit_type <= EU_DIV; 5'd4: iq_entries[4].exec_unit_type <= EU_DIV; 5'd5: iq_entries[5].exec_unit_type <= EU_DIV; 5'd6: iq_entries[6].exec_unit_type <= EU_DIV; 5'd7: iq_entries[7].exec_unit_type <= EU_DIV; 5'd8: iq_entries[8].exec_unit_type <= EU_DIV; 5'd9: iq_entries[9].exec_unit_type <= EU_DIV; 5'd10: iq_entries[10].exec_unit_type <= EU_DIV; 5'd11: iq_entries[11].exec_unit_type <= EU_DIV; 5'd12: iq_entries[12].exec_unit_type <= EU_DIV; 5'd13: iq_entries[13].exec_unit_type <= EU_DIV; 5'd14: iq_entries[14].exec_unit_type <= EU_DIV; 5'd15: iq_entries[15].exec_unit_type <= EU_DIV; 5'd16: iq_entries[16].exec_unit_type <= EU_DIV; 5'd17: iq_entries[17].exec_unit_type <= EU_DIV; 5'd18: iq_entries[18].exec_unit_type <= EU_DIV; 5'd19: iq_entries[19].exec_unit_type <= EU_DIV; 5'd20: iq_entries[20].exec_unit_type <= EU_DIV; 5'd21: iq_entries[21].exec_unit_type <= EU_DIV; 5'd22: iq_entries[22].exec_unit_type <= EU_DIV; 5'd23: iq_entries[23].exec_unit_type <= EU_DIV; 5'd24: iq_entries[24].exec_unit_type <= EU_DIV; 5'd25: iq_entries[25].exec_unit_type <= EU_DIV; 5'd26: iq_entries[26].exec_unit_type <= EU_DIV; 5'd27: iq_entries[27].exec_unit_type <= EU_DIV; 5'd28: iq_entries[28].exec_unit_type <= EU_DIV; 5'd29: iq_entries[29].exec_unit_type <= EU_DIV; 5'd30: iq_entries[30].exec_unit_type <= EU_DIV; 5'd31: iq_entries[31].exec_unit_type <= EU_DIV;
                    endcase
                    4'b0111, 4'b1000: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_FPU; 5'd1: iq_entries[1].exec_unit_type <= EU_FPU; 5'd2: iq_entries[2].exec_unit_type <= EU_FPU; 5'd3: iq_entries[3].exec_unit_type <= EU_FPU; 5'd4: iq_entries[4].exec_unit_type <= EU_FPU; 5'd5: iq_entries[5].exec_unit_type <= EU_FPU; 5'd6: iq_entries[6].exec_unit_type <= EU_FPU; 5'd7: iq_entries[7].exec_unit_type <= EU_FPU; 5'd8: iq_entries[8].exec_unit_type <= EU_FPU; 5'd9: iq_entries[9].exec_unit_type <= EU_FPU; 5'd10: iq_entries[10].exec_unit_type <= EU_FPU; 5'd11: iq_entries[11].exec_unit_type <= EU_FPU; 5'd12: iq_entries[12].exec_unit_type <= EU_FPU; 5'd13: iq_entries[13].exec_unit_type <= EU_FPU; 5'd14: iq_entries[14].exec_unit_type <= EU_FPU; 5'd15: iq_entries[15].exec_unit_type <= EU_FPU; 5'd16: iq_entries[16].exec_unit_type <= EU_FPU; 5'd17: iq_entries[17].exec_unit_type <= EU_FPU; 5'd18: iq_entries[18].exec_unit_type <= EU_FPU; 5'd19: iq_entries[19].exec_unit_type <= EU_FPU; 5'd20: iq_entries[20].exec_unit_type <= EU_FPU; 5'd21: iq_entries[21].exec_unit_type <= EU_FPU; 5'd22: iq_entries[22].exec_unit_type <= EU_FPU; 5'd23: iq_entries[23].exec_unit_type <= EU_FPU; 5'd24: iq_entries[24].exec_unit_type <= EU_FPU; 5'd25: iq_entries[25].exec_unit_type <= EU_FPU; 5'd26: iq_entries[26].exec_unit_type <= EU_FPU; 5'd27: iq_entries[27].exec_unit_type <= EU_FPU; 5'd28: iq_entries[28].exec_unit_type <= EU_FPU; 5'd29: iq_entries[29].exec_unit_type <= EU_FPU; 5'd30: iq_entries[30].exec_unit_type <= EU_FPU; 5'd31: iq_entries[31].exec_unit_type <= EU_FPU;
                    endcase
                    default: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                endcase
                
                iq_count <= iq_count + 1;
            end
            
            // Allocation 2
            if (alloc_valid[2]) begin
                idx = alloc_iq_idx[2*5 +: 5];
                uop_type = rob_uops[2*64 +: 4];
                
                case (idx)
                    5'd0:  begin iq_entries[0].valid <= 1'b1; iq_entries[0].ready <= 1'b0; iq_entries[0].issued <= 1'b0; iq_entries[0].uop <= rob_uops[2*64 +: 64]; iq_entries[0].rob_id <= rob_id[2*6 +: 6]; iq_entries[0].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[0].uop_type <= uop_type; iq_entries[0].age <= global_age_counter; end
                    5'd1:  begin iq_entries[1].valid <= 1'b1; iq_entries[1].ready <= 1'b0; iq_entries[1].issued <= 1'b0; iq_entries[1].uop <= rob_uops[2*64 +: 64]; iq_entries[1].rob_id <= rob_id[2*6 +: 6]; iq_entries[1].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[1].uop_type <= uop_type; iq_entries[1].age <= global_age_counter; end
                    5'd2:  begin iq_entries[2].valid <= 1'b1; iq_entries[2].ready <= 1'b0; iq_entries[2].issued <= 1'b0; iq_entries[2].uop <= rob_uops[2*64 +: 64]; iq_entries[2].rob_id <= rob_id[2*6 +: 6]; iq_entries[2].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[2].uop_type <= uop_type; iq_entries[2].age <= global_age_counter; end
                    5'd3:  begin iq_entries[3].valid <= 1'b1; iq_entries[3].ready <= 1'b0; iq_entries[3].issued <= 1'b0; iq_entries[3].uop <= rob_uops[2*64 +: 64]; iq_entries[3].rob_id <= rob_id[2*6 +: 6]; iq_entries[3].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[3].uop_type <= uop_type; iq_entries[3].age <= global_age_counter; end
                    5'd4:  begin iq_entries[4].valid <= 1'b1; iq_entries[4].ready <= 1'b0; iq_entries[4].issued <= 1'b0; iq_entries[4].uop <= rob_uops[2*64 +: 64]; iq_entries[4].rob_id <= rob_id[2*6 +: 6]; iq_entries[4].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[4].uop_type <= uop_type; iq_entries[4].age <= global_age_counter; end
                    5'd5:  begin iq_entries[5].valid <= 1'b1; iq_entries[5].ready <= 1'b0; iq_entries[5].issued <= 1'b0; iq_entries[5].uop <= rob_uops[2*64 +: 64]; iq_entries[5].rob_id <= rob_id[2*6 +: 6]; iq_entries[5].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[5].uop_type <= uop_type; iq_entries[5].age <= global_age_counter; end
                    5'd6:  begin iq_entries[6].valid <= 1'b1; iq_entries[6].ready <= 1'b0; iq_entries[6].issued <= 1'b0; iq_entries[6].uop <= rob_uops[2*64 +: 64]; iq_entries[6].rob_id <= rob_id[2*6 +: 6]; iq_entries[6].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[6].uop_type <= uop_type; iq_entries[6].age <= global_age_counter; end
                    5'd7:  begin iq_entries[7].valid <= 1'b1; iq_entries[7].ready <= 1'b0; iq_entries[7].issued <= 1'b0; iq_entries[7].uop <= rob_uops[2*64 +: 64]; iq_entries[7].rob_id <= rob_id[2*6 +: 6]; iq_entries[7].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[7].uop_type <= uop_type; iq_entries[7].age <= global_age_counter; end
                    5'd8:  begin iq_entries[8].valid <= 1'b1; iq_entries[8].ready <= 1'b0; iq_entries[8].issued <= 1'b0; iq_entries[8].uop <= rob_uops[2*64 +: 64]; iq_entries[8].rob_id <= rob_id[2*6 +: 6]; iq_entries[8].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[8].uop_type <= uop_type; iq_entries[8].age <= global_age_counter; end
                    5'd9:  begin iq_entries[9].valid <= 1'b1; iq_entries[9].ready <= 1'b0; iq_entries[9].issued <= 1'b0; iq_entries[9].uop <= rob_uops[2*64 +: 64]; iq_entries[9].rob_id <= rob_id[2*6 +: 6]; iq_entries[9].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[9].uop_type <= uop_type; iq_entries[9].age <= global_age_counter; end
                    5'd10: begin iq_entries[10].valid <= 1'b1; iq_entries[10].ready <= 1'b0; iq_entries[10].issued <= 1'b0; iq_entries[10].uop <= rob_uops[2*64 +: 64]; iq_entries[10].rob_id <= rob_id[2*6 +: 6]; iq_entries[10].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[10].uop_type <= uop_type; iq_entries[10].age <= global_age_counter; end
                    5'd11: begin iq_entries[11].valid <= 1'b1; iq_entries[11].ready <= 1'b0; iq_entries[11].issued <= 1'b0; iq_entries[11].uop <= rob_uops[2*64 +: 64]; iq_entries[11].rob_id <= rob_id[2*6 +: 6]; iq_entries[11].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[11].uop_type <= uop_type; iq_entries[11].age <= global_age_counter; end
                    5'd12: begin iq_entries[12].valid <= 1'b1; iq_entries[12].ready <= 1'b0; iq_entries[12].issued <= 1'b0; iq_entries[12].uop <= rob_uops[2*64 +: 64]; iq_entries[12].rob_id <= rob_id[2*6 +: 6]; iq_entries[12].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[12].uop_type <= uop_type; iq_entries[12].age <= global_age_counter; end
                    5'd13: begin iq_entries[13].valid <= 1'b1; iq_entries[13].ready <= 1'b0; iq_entries[13].issued <= 1'b0; iq_entries[13].uop <= rob_uops[2*64 +: 64]; iq_entries[13].rob_id <= rob_id[2*6 +: 6]; iq_entries[13].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[13].uop_type <= uop_type; iq_entries[13].age <= global_age_counter; end
                    5'd14: begin iq_entries[14].valid <= 1'b1; iq_entries[14].ready <= 1'b0; iq_entries[14].issued <= 1'b0; iq_entries[14].uop <= rob_uops[2*64 +: 64]; iq_entries[14].rob_id <= rob_id[2*6 +: 6]; iq_entries[14].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[14].uop_type <= uop_type; iq_entries[14].age <= global_age_counter; end
                    5'd15: begin iq_entries[15].valid <= 1'b1; iq_entries[15].ready <= 1'b0; iq_entries[15].issued <= 1'b0; iq_entries[15].uop <= rob_uops[2*64 +: 64]; iq_entries[15].rob_id <= rob_id[2*6 +: 6]; iq_entries[15].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[15].uop_type <= uop_type; iq_entries[15].age <= global_age_counter; end
                    5'd16: begin iq_entries[16].valid <= 1'b1; iq_entries[16].ready <= 1'b0; iq_entries[16].issued <= 1'b0; iq_entries[16].uop <= rob_uops[2*64 +: 64]; iq_entries[16].rob_id <= rob_id[2*6 +: 6]; iq_entries[16].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[16].uop_type <= uop_type; iq_entries[16].age <= global_age_counter; end
                    5'd17: begin iq_entries[17].valid <= 1'b1; iq_entries[17].ready <= 1'b0; iq_entries[17].issued <= 1'b0; iq_entries[17].uop <= rob_uops[2*64 +: 64]; iq_entries[17].rob_id <= rob_id[2*6 +: 6]; iq_entries[17].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[17].uop_type <= uop_type; iq_entries[17].age <= global_age_counter; end
                    5'd18: begin iq_entries[18].valid <= 1'b1; iq_entries[18].ready <= 1'b0; iq_entries[18].issued <= 1'b0; iq_entries[18].uop <= rob_uops[2*64 +: 64]; iq_entries[18].rob_id <= rob_id[2*6 +: 6]; iq_entries[18].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[18].uop_type <= uop_type; iq_entries[18].age <= global_age_counter; end
                    5'd19: begin iq_entries[19].valid <= 1'b1; iq_entries[19].ready <= 1'b0; iq_entries[19].issued <= 1'b0; iq_entries[19].uop <= rob_uops[2*64 +: 64]; iq_entries[19].rob_id <= rob_id[2*6 +: 6]; iq_entries[19].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[19].uop_type <= uop_type; iq_entries[19].age <= global_age_counter; end
                    5'd20: begin iq_entries[20].valid <= 1'b1; iq_entries[20].ready <= 1'b0; iq_entries[20].issued <= 1'b0; iq_entries[20].uop <= rob_uops[2*64 +: 64]; iq_entries[20].rob_id <= rob_id[2*6 +: 6]; iq_entries[20].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[20].uop_type <= uop_type; iq_entries[20].age <= global_age_counter; end
                    5'd21: begin iq_entries[21].valid <= 1'b1; iq_entries[21].ready <= 1'b0; iq_entries[21].issued <= 1'b0; iq_entries[21].uop <= rob_uops[2*64 +: 64]; iq_entries[21].rob_id <= rob_id[2*6 +: 6]; iq_entries[21].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[21].uop_type <= uop_type; iq_entries[21].age <= global_age_counter; end
                    5'd22: begin iq_entries[22].valid <= 1'b1; iq_entries[22].ready <= 1'b0; iq_entries[22].issued <= 1'b0; iq_entries[22].uop <= rob_uops[2*64 +: 64]; iq_entries[22].rob_id <= rob_id[2*6 +: 6]; iq_entries[22].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[22].uop_type <= uop_type; iq_entries[22].age <= global_age_counter; end
                    5'd23: begin iq_entries[23].valid <= 1'b1; iq_entries[23].ready <= 1'b0; iq_entries[23].issued <= 1'b0; iq_entries[23].uop <= rob_uops[2*64 +: 64]; iq_entries[23].rob_id <= rob_id[2*6 +: 6]; iq_entries[23].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[23].uop_type <= uop_type; iq_entries[23].age <= global_age_counter; end
                    5'd24: begin iq_entries[24].valid <= 1'b1; iq_entries[24].ready <= 1'b0; iq_entries[24].issued <= 1'b0; iq_entries[24].uop <= rob_uops[2*64 +: 64]; iq_entries[24].rob_id <= rob_id[2*6 +: 6]; iq_entries[24].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[24].uop_type <= uop_type; iq_entries[24].age <= global_age_counter; end
                    5'd25: begin iq_entries[25].valid <= 1'b1; iq_entries[25].ready <= 1'b0; iq_entries[25].issued <= 1'b0; iq_entries[25].uop <= rob_uops[2*64 +: 64]; iq_entries[25].rob_id <= rob_id[2*6 +: 6]; iq_entries[25].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[25].uop_type <= uop_type; iq_entries[25].age <= global_age_counter; end
                    5'd26: begin iq_entries[26].valid <= 1'b1; iq_entries[26].ready <= 1'b0; iq_entries[26].issued <= 1'b0; iq_entries[26].uop <= rob_uops[2*64 +: 64]; iq_entries[26].rob_id <= rob_id[2*6 +: 6]; iq_entries[26].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[26].uop_type <= uop_type; iq_entries[26].age <= global_age_counter; end
                    5'd27: begin iq_entries[27].valid <= 1'b1; iq_entries[27].ready <= 1'b0; iq_entries[27].issued <= 1'b0; iq_entries[27].uop <= rob_uops[2*64 +: 64]; iq_entries[27].rob_id <= rob_id[2*6 +: 6]; iq_entries[27].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[27].uop_type <= uop_type; iq_entries[27].age <= global_age_counter; end
                    5'd28: begin iq_entries[28].valid <= 1'b1; iq_entries[28].ready <= 1'b0; iq_entries[28].issued <= 1'b0; iq_entries[28].uop <= rob_uops[2*64 +: 64]; iq_entries[28].rob_id <= rob_id[2*6 +: 6]; iq_entries[28].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[28].uop_type <= uop_type; iq_entries[28].age <= global_age_counter; end
                    5'd29: begin iq_entries[29].valid <= 1'b1; iq_entries[29].ready <= 1'b0; iq_entries[29].issued <= 1'b0; iq_entries[29].uop <= rob_uops[2*64 +: 64]; iq_entries[29].rob_id <= rob_id[2*6 +: 6]; iq_entries[29].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[29].uop_type <= uop_type; iq_entries[29].age <= global_age_counter; end
                    5'd30: begin iq_entries[30].valid <= 1'b1; iq_entries[30].ready <= 1'b0; iq_entries[30].issued <= 1'b0; iq_entries[30].uop <= rob_uops[2*64 +: 64]; iq_entries[30].rob_id <= rob_id[2*6 +: 6]; iq_entries[30].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[30].uop_type <= uop_type; iq_entries[30].age <= global_age_counter; end
                    5'd31: begin iq_entries[31].valid <= 1'b1; iq_entries[31].ready <= 1'b0; iq_entries[31].issued <= 1'b0; iq_entries[31].uop <= rob_uops[2*64 +: 64]; iq_entries[31].rob_id <= rob_id[2*6 +: 6]; iq_entries[31].thread_id <= rob_thread_id[2*2 +: 2]; iq_entries[31].uop_type <= uop_type; iq_entries[31].age <= global_age_counter; end
                endcase
                
                case (uop_type)
                    4'b0001, 4'b0010, 4'b0100: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                    4'b0011: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_AGU; 5'd1: iq_entries[1].exec_unit_type <= EU_AGU; 5'd2: iq_entries[2].exec_unit_type <= EU_AGU; 5'd3: iq_entries[3].exec_unit_type <= EU_AGU; 5'd4: iq_entries[4].exec_unit_type <= EU_AGU; 5'd5: iq_entries[5].exec_unit_type <= EU_AGU; 5'd6: iq_entries[6].exec_unit_type <= EU_AGU; 5'd7: iq_entries[7].exec_unit_type <= EU_AGU; 5'd8: iq_entries[8].exec_unit_type <= EU_AGU; 5'd9: iq_entries[9].exec_unit_type <= EU_AGU; 5'd10: iq_entries[10].exec_unit_type <= EU_AGU; 5'd11: iq_entries[11].exec_unit_type <= EU_AGU; 5'd12: iq_entries[12].exec_unit_type <= EU_AGU; 5'd13: iq_entries[13].exec_unit_type <= EU_AGU; 5'd14: iq_entries[14].exec_unit_type <= EU_AGU; 5'd15: iq_entries[15].exec_unit_type <= EU_AGU; 5'd16: iq_entries[16].exec_unit_type <= EU_AGU; 5'd17: iq_entries[17].exec_unit_type <= EU_AGU; 5'd18: iq_entries[18].exec_unit_type <= EU_AGU; 5'd19: iq_entries[19].exec_unit_type <= EU_AGU; 5'd20: iq_entries[20].exec_unit_type <= EU_AGU; 5'd21: iq_entries[21].exec_unit_type <= EU_AGU; 5'd22: iq_entries[22].exec_unit_type <= EU_AGU; 5'd23: iq_entries[23].exec_unit_type <= EU_AGU; 5'd24: iq_entries[24].exec_unit_type <= EU_AGU; 5'd25: iq_entries[25].exec_unit_type <= EU_AGU; 5'd26: iq_entries[26].exec_unit_type <= EU_AGU; 5'd27: iq_entries[27].exec_unit_type <= EU_AGU; 5'd28: iq_entries[28].exec_unit_type <= EU_AGU; 5'd29: iq_entries[29].exec_unit_type <= EU_AGU; 5'd30: iq_entries[30].exec_unit_type <= EU_AGU; 5'd31: iq_entries[31].exec_unit_type <= EU_AGU;
                    endcase
                    4'b0101: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_MUL; 5'd1: iq_entries[1].exec_unit_type <= EU_MUL; 5'd2: iq_entries[2].exec_unit_type <= EU_MUL; 5'd3: iq_entries[3].exec_unit_type <= EU_MUL; 5'd4: iq_entries[4].exec_unit_type <= EU_MUL; 5'd5: iq_entries[5].exec_unit_type <= EU_MUL; 5'd6: iq_entries[6].exec_unit_type <= EU_MUL; 5'd7: iq_entries[7].exec_unit_type <= EU_MUL; 5'd8: iq_entries[8].exec_unit_type <= EU_MUL; 5'd9: iq_entries[9].exec_unit_type <= EU_MUL; 5'd10: iq_entries[10].exec_unit_type <= EU_MUL; 5'd11: iq_entries[11].exec_unit_type <= EU_MUL; 5'd12: iq_entries[12].exec_unit_type <= EU_MUL; 5'd13: iq_entries[13].exec_unit_type <= EU_MUL; 5'd14: iq_entries[14].exec_unit_type <= EU_MUL; 5'd15: iq_entries[15].exec_unit_type <= EU_MUL; 5'd16: iq_entries[16].exec_unit_type <= EU_MUL; 5'd17: iq_entries[17].exec_unit_type <= EU_MUL; 5'd18: iq_entries[18].exec_unit_type <= EU_MUL; 5'd19: iq_entries[19].exec_unit_type <= EU_MUL; 5'd20: iq_entries[20].exec_unit_type <= EU_MUL; 5'd21: iq_entries[21].exec_unit_type <= EU_MUL; 5'd22: iq_entries[22].exec_unit_type <= EU_MUL; 5'd23: iq_entries[23].exec_unit_type <= EU_MUL; 5'd24: iq_entries[24].exec_unit_type <= EU_MUL; 5'd25: iq_entries[25].exec_unit_type <= EU_MUL; 5'd26: iq_entries[26].exec_unit_type <= EU_MUL; 5'd27: iq_entries[27].exec_unit_type <= EU_MUL; 5'd28: iq_entries[28].exec_unit_type <= EU_MUL; 5'd29: iq_entries[29].exec_unit_type <= EU_MUL; 5'd30: iq_entries[30].exec_unit_type <= EU_MUL; 5'd31: iq_entries[31].exec_unit_type <= EU_MUL;
                    endcase
                    4'b0110: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_DIV; 5'd1: iq_entries[1].exec_unit_type <= EU_DIV; 5'd2: iq_entries[2].exec_unit_type <= EU_DIV; 5'd3: iq_entries[3].exec_unit_type <= EU_DIV; 5'd4: iq_entries[4].exec_unit_type <= EU_DIV; 5'd5: iq_entries[5].exec_unit_type <= EU_DIV; 5'd6: iq_entries[6].exec_unit_type <= EU_DIV; 5'd7: iq_entries[7].exec_unit_type <= EU_DIV; 5'd8: iq_entries[8].exec_unit_type <= EU_DIV; 5'd9: iq_entries[9].exec_unit_type <= EU_DIV; 5'd10: iq_entries[10].exec_unit_type <= EU_DIV; 5'd11: iq_entries[11].exec_unit_type <= EU_DIV; 5'd12: iq_entries[12].exec_unit_type <= EU_DIV; 5'd13: iq_entries[13].exec_unit_type <= EU_DIV; 5'd14: iq_entries[14].exec_unit_type <= EU_DIV; 5'd15: iq_entries[15].exec_unit_type <= EU_DIV; 5'd16: iq_entries[16].exec_unit_type <= EU_DIV; 5'd17: iq_entries[17].exec_unit_type <= EU_DIV; 5'd18: iq_entries[18].exec_unit_type <= EU_DIV; 5'd19: iq_entries[19].exec_unit_type <= EU_DIV; 5'd20: iq_entries[20].exec_unit_type <= EU_DIV; 5'd21: iq_entries[21].exec_unit_type <= EU_DIV; 5'd22: iq_entries[22].exec_unit_type <= EU_DIV; 5'd23: iq_entries[23].exec_unit_type <= EU_DIV; 5'd24: iq_entries[24].exec_unit_type <= EU_DIV; 5'd25: iq_entries[25].exec_unit_type <= EU_DIV; 5'd26: iq_entries[26].exec_unit_type <= EU_DIV; 5'd27: iq_entries[27].exec_unit_type <= EU_DIV; 5'd28: iq_entries[28].exec_unit_type <= EU_DIV; 5'd29: iq_entries[29].exec_unit_type <= EU_DIV; 5'd30: iq_entries[30].exec_unit_type <= EU_DIV; 5'd31: iq_entries[31].exec_unit_type <= EU_DIV;
                    endcase
                    4'b0111, 4'b1000: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_FPU; 5'd1: iq_entries[1].exec_unit_type <= EU_FPU; 5'd2: iq_entries[2].exec_unit_type <= EU_FPU; 5'd3: iq_entries[3].exec_unit_type <= EU_FPU; 5'd4: iq_entries[4].exec_unit_type <= EU_FPU; 5'd5: iq_entries[5].exec_unit_type <= EU_FPU; 5'd6: iq_entries[6].exec_unit_type <= EU_FPU; 5'd7: iq_entries[7].exec_unit_type <= EU_FPU; 5'd8: iq_entries[8].exec_unit_type <= EU_FPU; 5'd9: iq_entries[9].exec_unit_type <= EU_FPU; 5'd10: iq_entries[10].exec_unit_type <= EU_FPU; 5'd11: iq_entries[11].exec_unit_type <= EU_FPU; 5'd12: iq_entries[12].exec_unit_type <= EU_FPU; 5'd13: iq_entries[13].exec_unit_type <= EU_FPU; 5'd14: iq_entries[14].exec_unit_type <= EU_FPU; 5'd15: iq_entries[15].exec_unit_type <= EU_FPU; 5'd16: iq_entries[16].exec_unit_type <= EU_FPU; 5'd17: iq_entries[17].exec_unit_type <= EU_FPU; 5'd18: iq_entries[18].exec_unit_type <= EU_FPU; 5'd19: iq_entries[19].exec_unit_type <= EU_FPU; 5'd20: iq_entries[20].exec_unit_type <= EU_FPU; 5'd21: iq_entries[21].exec_unit_type <= EU_FPU; 5'd22: iq_entries[22].exec_unit_type <= EU_FPU; 5'd23: iq_entries[23].exec_unit_type <= EU_FPU; 5'd24: iq_entries[24].exec_unit_type <= EU_FPU; 5'd25: iq_entries[25].exec_unit_type <= EU_FPU; 5'd26: iq_entries[26].exec_unit_type <= EU_FPU; 5'd27: iq_entries[27].exec_unit_type <= EU_FPU; 5'd28: iq_entries[28].exec_unit_type <= EU_FPU; 5'd29: iq_entries[29].exec_unit_type <= EU_FPU; 5'd30: iq_entries[30].exec_unit_type <= EU_FPU; 5'd31: iq_entries[31].exec_unit_type <= EU_FPU;
                    endcase
                    default: case (idx)
                        5'd0: iq_entries[0].exec_unit_type <= EU_ALU; 5'd1: iq_entries[1].exec_unit_type <= EU_ALU; 5'd2: iq_entries[2].exec_unit_type <= EU_ALU; 5'd3: iq_entries[3].exec_unit_type <= EU_ALU; 5'd4: iq_entries[4].exec_unit_type <= EU_ALU; 5'd5: iq_entries[5].exec_unit_type <= EU_ALU; 5'd6: iq_entries[6].exec_unit_type <= EU_ALU; 5'd7: iq_entries[7].exec_unit_type <= EU_ALU; 5'd8: iq_entries[8].exec_unit_type <= EU_ALU; 5'd9: iq_entries[9].exec_unit_type <= EU_ALU; 5'd10: iq_entries[10].exec_unit_type <= EU_ALU; 5'd11: iq_entries[11].exec_unit_type <= EU_ALU; 5'd12: iq_entries[12].exec_unit_type <= EU_ALU; 5'd13: iq_entries[13].exec_unit_type <= EU_ALU; 5'd14: iq_entries[14].exec_unit_type <= EU_ALU; 5'd15: iq_entries[15].exec_unit_type <= EU_ALU; 5'd16: iq_entries[16].exec_unit_type <= EU_ALU; 5'd17: iq_entries[17].exec_unit_type <= EU_ALU; 5'd18: iq_entries[18].exec_unit_type <= EU_ALU; 5'd19: iq_entries[19].exec_unit_type <= EU_ALU; 5'd20: iq_entries[20].exec_unit_type <= EU_ALU; 5'd21: iq_entries[21].exec_unit_type <= EU_ALU; 5'd22: iq_entries[22].exec_unit_type <= EU_ALU; 5'd23: iq_entries[23].exec_unit_type <= EU_ALU; 5'd24: iq_entries[24].exec_unit_type <= EU_ALU; 5'd25: iq_entries[25].exec_unit_type <= EU_ALU; 5'd26: iq_entries[26].exec_unit_type <= EU_ALU; 5'd27: iq_entries[27].exec_unit_type <= EU_ALU; 5'd28: iq_entries[28].exec_unit_type <= EU_ALU; 5'd29: iq_entries[29].exec_unit_type <= EU_ALU; 5'd30: iq_entries[30].exec_unit_type <= EU_ALU; 5'd31: iq_entries[31].exec_unit_type <= EU_ALU;
                    endcase
                endcase
                
                iq_count <= iq_count + 1;
            end
            
            // =============================================
            // Wakeup Phase
            // =============================================
            
            for (i = 0; i < IQ_ENTRIES; i = i + 1) begin
                if (iq_entries[i].valid) begin
                    iq_entries[i].ready <= iq_entry_ready[i];
                end
            end
            
            // =============================================
            // Issue Phase
            // =============================================
            
            issued_this_cycle = 2'b0;
            
            // Mark issued instructions
            // ALU 0
            if (alu_issue_valid[0]) begin
                alu_issued_idx = selected_alu_flat[0*5 +: 5];
                case (alu_issued_idx)
                    5'd0:  iq_entries[0].issued <= 1'b1;
                    5'd1:  iq_entries[1].issued <= 1'b1;
                    5'd2:  iq_entries[2].issued <= 1'b1;
                    5'd3:  iq_entries[3].issued <= 1'b1;
                    5'd4:  iq_entries[4].issued <= 1'b1;
                    5'd5:  iq_entries[5].issued <= 1'b1;
                    5'd6:  iq_entries[6].issued <= 1'b1;
                    5'd7:  iq_entries[7].issued <= 1'b1;
                    5'd8:  iq_entries[8].issued <= 1'b1;
                    5'd9:  iq_entries[9].issued <= 1'b1;
                    5'd10: iq_entries[10].issued <= 1'b1;
                    5'd11: iq_entries[11].issued <= 1'b1;
                    5'd12: iq_entries[12].issued <= 1'b1;
                    5'd13: iq_entries[13].issued <= 1'b1;
                    5'd14: iq_entries[14].issued <= 1'b1;
                    5'd15: iq_entries[15].issued <= 1'b1;
                    5'd16: iq_entries[16].issued <= 1'b1;
                    5'd17: iq_entries[17].issued <= 1'b1;
                    5'd18: iq_entries[18].issued <= 1'b1;
                    5'd19: iq_entries[19].issued <= 1'b1;
                    5'd20: iq_entries[20].issued <= 1'b1;
                    5'd21: iq_entries[21].issued <= 1'b1;
                    5'd22: iq_entries[22].issued <= 1'b1;
                    5'd23: iq_entries[23].issued <= 1'b1;
                    5'd24: iq_entries[24].issued <= 1'b1;
                    5'd25: iq_entries[25].issued <= 1'b1;
                    5'd26: iq_entries[26].issued <= 1'b1;
                    5'd27: iq_entries[27].issued <= 1'b1;
                    5'd28: iq_entries[28].issued <= 1'b1;
                    5'd29: iq_entries[29].issued <= 1'b1;
                    5'd30: iq_entries[30].issued <= 1'b1;
                    5'd31: iq_entries[31].issued <= 1'b1;
                endcase
                thread_issue_count[alu_issue_thread_id[0*2 +: 2]] <= 
                    thread_issue_count[alu_issue_thread_id[0*2 +: 2]] + 1;
                issued_this_cycle <= issued_this_cycle + 1;
            end
            
            // ALU 1
            if (alu_issue_valid[1]) begin
                alu_issued_idx = selected_alu_flat[1*5 +: 5];
                case (alu_issued_idx)
                    5'd0:  iq_entries[0].issued <= 1'b1;
                    5'd1:  iq_entries[1].issued <= 1'b1;
                    5'd2:  iq_entries[2].issued <= 1'b1;
                    5'd3:  iq_entries[3].issued <= 1'b1;
                    5'd4:  iq_entries[4].issued <= 1'b1;
                    5'd5:  iq_entries[5].issued <= 1'b1;
                    5'd6:  iq_entries[6].issued <= 1'b1;
                    5'd7:  iq_entries[7].issued <= 1'b1;
                    5'd8:  iq_entries[8].issued <= 1'b1;
                    5'd9:  iq_entries[9].issued <= 1'b1;
                    5'd10: iq_entries[10].issued <= 1'b1;
                    5'd11: iq_entries[11].issued <= 1'b1;
                    5'd12: iq_entries[12].issued <= 1'b1;
                    5'd13: iq_entries[13].issued <= 1'b1;
                    5'd14: iq_entries[14].issued <= 1'b1;
                    5'd15: iq_entries[15].issued <= 1'b1;
                    5'd16: iq_entries[16].issued <= 1'b1;
                    5'd17: iq_entries[17].issued <= 1'b1;
                    5'd18: iq_entries[18].issued <= 1'b1;
                    5'd19: iq_entries[19].issued <= 1'b1;
                    5'd20: iq_entries[20].issued <= 1'b1;
                    5'd21: iq_entries[21].issued <= 1'b1;
                    5'd22: iq_entries[22].issued <= 1'b1;
                    5'd23: iq_entries[23].issued <= 1'b1;
                    5'd24: iq_entries[24].issued <= 1'b1;
                    5'd25: iq_entries[25].issued <= 1'b1;
                    5'd26: iq_entries[26].issued <= 1'b1;
                    5'd27: iq_entries[27].issued <= 1'b1;
                    5'd28: iq_entries[28].issued <= 1'b1;
                    5'd29: iq_entries[29].issued <= 1'b1;
                    5'd30: iq_entries[30].issued <= 1'b1;
                    5'd31: iq_entries[31].issued <= 1'b1;
                endcase
                thread_issue_count[alu_issue_thread_id[1*2 +: 2]] <= 
                    thread_issue_count[alu_issue_thread_id[1*2 +: 2]] + 1;
                issued_this_cycle <= issued_this_cycle + 1;
            end
            
            if (agu_issue_valid) begin
                case (selected_agu)
                    5'd0:  iq_entries[0].issued <= 1'b1;
                    5'd1:  iq_entries[1].issued <= 1'b1;
                    5'd2:  iq_entries[2].issued <= 1'b1;
                    5'd3:  iq_entries[3].issued <= 1'b1;
                    5'd4:  iq_entries[4].issued <= 1'b1;
                    5'd5:  iq_entries[5].issued <= 1'b1;
                    5'd6:  iq_entries[6].issued <= 1'b1;
                    5'd7:  iq_entries[7].issued <= 1'b1;
                    5'd8:  iq_entries[8].issued <= 1'b1;
                    5'd9:  iq_entries[9].issued <= 1'b1;
                    5'd10: iq_entries[10].issued <= 1'b1;
                    5'd11: iq_entries[11].issued <= 1'b1;
                    5'd12: iq_entries[12].issued <= 1'b1;
                    5'd13: iq_entries[13].issued <= 1'b1;
                    5'd14: iq_entries[14].issued <= 1'b1;
                    5'd15: iq_entries[15].issued <= 1'b1;
                    5'd16: iq_entries[16].issued <= 1'b1;
                    5'd17: iq_entries[17].issued <= 1'b1;
                    5'd18: iq_entries[18].issued <= 1'b1;
                    5'd19: iq_entries[19].issued <= 1'b1;
                    5'd20: iq_entries[20].issued <= 1'b1;
                    5'd21: iq_entries[21].issued <= 1'b1;
                    5'd22: iq_entries[22].issued <= 1'b1;
                    5'd23: iq_entries[23].issued <= 1'b1;
                    5'd24: iq_entries[24].issued <= 1'b1;
                    5'd25: iq_entries[25].issued <= 1'b1;
                    5'd26: iq_entries[26].issued <= 1'b1;
                    5'd27: iq_entries[27].issued <= 1'b1;
                    5'd28: iq_entries[28].issued <= 1'b1;
                    5'd29: iq_entries[29].issued <= 1'b1;
                    5'd30: iq_entries[30].issued <= 1'b1;
                    5'd31: iq_entries[31].issued <= 1'b1;
                endcase
                thread_issue_count[agu_issue_thread_id] <= 
                    thread_issue_count[agu_issue_thread_id] + 1;
                issued_this_cycle <= issued_this_cycle + 1;
            end
            
            if (mul_issue_valid) begin
                case (selected_mul)
                    5'd0:  iq_entries[0].issued <= 1'b1;
                    5'd1:  iq_entries[1].issued <= 1'b1;
                    5'd2:  iq_entries[2].issued <= 1'b1;
                    5'd3:  iq_entries[3].issued <= 1'b1;
                    5'd4:  iq_entries[4].issued <= 1'b1;
                    5'd5:  iq_entries[5].issued <= 1'b1;
                    5'd6:  iq_entries[6].issued <= 1'b1;
                    5'd7:  iq_entries[7].issued <= 1'b1;
                    5'd8:  iq_entries[8].issued <= 1'b1;
                    5'd9:  iq_entries[9].issued <= 1'b1;
                    5'd10: iq_entries[10].issued <= 1'b1;
                    5'd11: iq_entries[11].issued <= 1'b1;
                    5'd12: iq_entries[12].issued <= 1'b1;
                    5'd13: iq_entries[13].issued <= 1'b1;
                    5'd14: iq_entries[14].issued <= 1'b1;
                    5'd15: iq_entries[15].issued <= 1'b1;
                    5'd16: iq_entries[16].issued <= 1'b1;
                    5'd17: iq_entries[17].issued <= 1'b1;
                    5'd18: iq_entries[18].issued <= 1'b1;
                    5'd19: iq_entries[19].issued <= 1'b1;
                    5'd20: iq_entries[20].issued <= 1'b1;
                    5'd21: iq_entries[21].issued <= 1'b1;
                    5'd22: iq_entries[22].issued <= 1'b1;
                    5'd23: iq_entries[23].issued <= 1'b1;
                    5'd24: iq_entries[24].issued <= 1'b1;
                    5'd25: iq_entries[25].issued <= 1'b1;
                    5'd26: iq_entries[26].issued <= 1'b1;
                    5'd27: iq_entries[27].issued <= 1'b1;
                    5'd28: iq_entries[28].issued <= 1'b1;
                    5'd29: iq_entries[29].issued <= 1'b1;
                    5'd30: iq_entries[30].issued <= 1'b1;
                    5'd31: iq_entries[31].issued <= 1'b1;
                endcase
                thread_issue_count[mul_issue_thread_id] <= 
                    thread_issue_count[mul_issue_thread_id] + 1;
                issued_this_cycle <= issued_this_cycle + 1;
            end
            
            if (div_issue_valid) begin
                case (selected_div)
                    5'd0:  iq_entries[0].issued <= 1'b1;
                    5'd1:  iq_entries[1].issued <= 1'b1;
                    5'd2:  iq_entries[2].issued <= 1'b1;
                    5'd3:  iq_entries[3].issued <= 1'b1;
                    5'd4:  iq_entries[4].issued <= 1'b1;
                    5'd5:  iq_entries[5].issued <= 1'b1;
                    5'd6:  iq_entries[6].issued <= 1'b1;
                    5'd7:  iq_entries[7].issued <= 1'b1;
                    5'd8:  iq_entries[8].issued <= 1'b1;
                    5'd9:  iq_entries[9].issued <= 1'b1;
                    5'd10: iq_entries[10].issued <= 1'b1;
                    5'd11: iq_entries[11].issued <= 1'b1;
                    5'd12: iq_entries[12].issued <= 1'b1;
                    5'd13: iq_entries[13].issued <= 1'b1;
                    5'd14: iq_entries[14].issued <= 1'b1;
                    5'd15: iq_entries[15].issued <= 1'b1;
                    5'd16: iq_entries[16].issued <= 1'b1;
                    5'd17: iq_entries[17].issued <= 1'b1;
                    5'd18: iq_entries[18].issued <= 1'b1;
                    5'd19: iq_entries[19].issued <= 1'b1;
                    5'd20: iq_entries[20].issued <= 1'b1;
                    5'd21: iq_entries[21].issued <= 1'b1;
                    5'd22: iq_entries[22].issued <= 1'b1;
                    5'd23: iq_entries[23].issued <= 1'b1;
                    5'd24: iq_entries[24].issued <= 1'b1;
                    5'd25: iq_entries[25].issued <= 1'b1;
                    5'd26: iq_entries[26].issued <= 1'b1;
                    5'd27: iq_entries[27].issued <= 1'b1;
                    5'd28: iq_entries[28].issued <= 1'b1;
                    5'd29: iq_entries[29].issued <= 1'b1;
                    5'd30: iq_entries[30].issued <= 1'b1;
                    5'd31: iq_entries[31].issued <= 1'b1;
                endcase
                thread_issue_count[div_issue_thread_id] <= 
                    thread_issue_count[div_issue_thread_id] + 1;
                issued_this_cycle <= issued_this_cycle + 1;
            end
            
            // FPU 0
            if (fpu_issue_valid[0]) begin
                fpu_issued_idx = selected_fpu_flat[0*5 +: 5];
                case (fpu_issued_idx)
                    5'd0:  iq_entries[0].issued <= 1'b1;
                    5'd1:  iq_entries[1].issued <= 1'b1;
                    5'd2:  iq_entries[2].issued <= 1'b1;
                    5'd3:  iq_entries[3].issued <= 1'b1;
                    5'd4:  iq_entries[4].issued <= 1'b1;
                    5'd5:  iq_entries[5].issued <= 1'b1;
                    5'd6:  iq_entries[6].issued <= 1'b1;
                    5'd7:  iq_entries[7].issued <= 1'b1;
                    5'd8:  iq_entries[8].issued <= 1'b1;
                    5'd9:  iq_entries[9].issued <= 1'b1;
                    5'd10: iq_entries[10].issued <= 1'b1;
                    5'd11: iq_entries[11].issued <= 1'b1;
                    5'd12: iq_entries[12].issued <= 1'b1;
                    5'd13: iq_entries[13].issued <= 1'b1;
                    5'd14: iq_entries[14].issued <= 1'b1;
                    5'd15: iq_entries[15].issued <= 1'b1;
                    5'd16: iq_entries[16].issued <= 1'b1;
                    5'd17: iq_entries[17].issued <= 1'b1;
                    5'd18: iq_entries[18].issued <= 1'b1;
                    5'd19: iq_entries[19].issued <= 1'b1;
                    5'd20: iq_entries[20].issued <= 1'b1;
                    5'd21: iq_entries[21].issued <= 1'b1;
                    5'd22: iq_entries[22].issued <= 1'b1;
                    5'd23: iq_entries[23].issued <= 1'b1;
                    5'd24: iq_entries[24].issued <= 1'b1;
                    5'd25: iq_entries[25].issued <= 1'b1;
                    5'd26: iq_entries[26].issued <= 1'b1;
                    5'd27: iq_entries[27].issued <= 1'b1;
                    5'd28: iq_entries[28].issued <= 1'b1;
                    5'd29: iq_entries[29].issued <= 1'b1;
                    5'd30: iq_entries[30].issued <= 1'b1;
                    5'd31: iq_entries[31].issued <= 1'b1;
                endcase
                thread_issue_count[fpu_issue_thread_id[0*2 +: 2]] <= 
                    thread_issue_count[fpu_issue_thread_id[0*2 +: 2]] + 1;
                issued_this_cycle <= issued_this_cycle + 1;
            end
            
            // FPU 1
            if (fpu_issue_valid[1]) begin
                fpu_issued_idx = selected_fpu_flat[1*5 +: 5];
                case (fpu_issued_idx)
                    5'd0:  iq_entries[0].issued <= 1'b1;
                    5'd1:  iq_entries[1].issued <= 1'b1;
                    5'd2:  iq_entries[2].issued <= 1'b1;
                    5'd3:  iq_entries[3].issued <= 1'b1;
                    5'd4:  iq_entries[4].issued <= 1'b1;
                    5'd5:  iq_entries[5].issued <= 1'b1;
                    5'd6:  iq_entries[6].issued <= 1'b1;
                    5'd7:  iq_entries[7].issued <= 1'b1;
                    5'd8:  iq_entries[8].issued <= 1'b1;
                    5'd9:  iq_entries[9].issued <= 1'b1;
                    5'd10: iq_entries[10].issued <= 1'b1;
                    5'd11: iq_entries[11].issued <= 1'b1;
                    5'd12: iq_entries[12].issued <= 1'b1;
                    5'd13: iq_entries[13].issued <= 1'b1;
                    5'd14: iq_entries[14].issued <= 1'b1;
                    5'd15: iq_entries[15].issued <= 1'b1;
                    5'd16: iq_entries[16].issued <= 1'b1;
                    5'd17: iq_entries[17].issued <= 1'b1;
                    5'd18: iq_entries[18].issued <= 1'b1;
                    5'd19: iq_entries[19].issued <= 1'b1;
                    5'd20: iq_entries[20].issued <= 1'b1;
                    5'd21: iq_entries[21].issued <= 1'b1;
                    5'd22: iq_entries[22].issued <= 1'b1;
                    5'd23: iq_entries[23].issued <= 1'b1;
                    5'd24: iq_entries[24].issued <= 1'b1;
                    5'd25: iq_entries[25].issued <= 1'b1;
                    5'd26: iq_entries[26].issued <= 1'b1;
                    5'd27: iq_entries[27].issued <= 1'b1;
                    5'd28: iq_entries[28].issued <= 1'b1;
                    5'd29: iq_entries[29].issued <= 1'b1;
                    5'd30: iq_entries[30].issued <= 1'b1;
                    5'd31: iq_entries[31].issued <= 1'b1;
                endcase
                thread_issue_count[fpu_issue_thread_id[1*2 +: 2]] <= 
                    thread_issue_count[fpu_issue_thread_id[1*2 +: 2]] + 1;
                issued_this_cycle <= issued_this_cycle + 1;
            end
            
            // =============================================
            // Thread Fairness Management
            // =============================================
            
            // Update thread priority based on issue counts
            thread_diff = thread_issue_count[0] - thread_issue_count[1];
            if (thread_diff > 32'd4) begin
                thread_priority[0] <= 1'b0;
                thread_priority[1] <= 1'b1;
            end else if (thread_diff < -32'd4) begin
                thread_priority[0] <= 1'b1;
                thread_priority[1] <= 1'b0;
            end else begin
                thread_priority[0] <= 1'b1;
                thread_priority[1] <= 1'b1;
            end
            
            // =============================================
            // Performance Counters
            // =============================================
            
            if (issued_this_cycle == 0 && iq_count > 0) begin
                perf_issue_stalls <= perf_issue_stalls + 1;
            end
            
            // Thread-specific stall counting
            if (thread_active[0] && issued_this_cycle == 0) begin
                perf_thread_stalls_0 <= perf_thread_stalls_0 + 1;
            end
            if (thread_active[1] && issued_this_cycle == 0) begin
                perf_thread_stalls_1 <= perf_thread_stalls_1 + 1;
            end
        end
    end
    
    // =========================================================================
    // Status Outputs
    // =========================================================================
    
    assign iq_entry_valid = {iq_entries[31].valid, iq_entries[30].valid, iq_entries[29].valid, iq_entries[28].valid,
                            iq_entries[27].valid, iq_entries[26].valid, iq_entries[25].valid, iq_entries[24].valid,
                            iq_entries[23].valid, iq_entries[22].valid, iq_entries[21].valid, iq_entries[20].valid,
                            iq_entries[19].valid, iq_entries[18].valid, iq_entries[17].valid, iq_entries[16].valid,
                            iq_entries[15].valid, iq_entries[14].valid, iq_entries[13].valid, iq_entries[12].valid,
                            iq_entries[11].valid, iq_entries[10].valid, iq_entries[9].valid,  iq_entries[8].valid,
                            iq_entries[7].valid,  iq_entries[6].valid,  iq_entries[5].valid,  iq_entries[4].valid,
                            iq_entries[3].valid,  iq_entries[2].valid,  iq_entries[1].valid,  iq_entries[0].valid};
    
    assign iq_full = (iq_count >= (IQ_ENTRIES - 4));
    assign iq_empty = (iq_count == 0);

endmodule
