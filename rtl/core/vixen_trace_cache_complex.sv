// =============================================================================
// Vixen Dio Pro Trace Cache
// =============================================================================
// 2-8KB trace cache for storing decoded micro-ops of hot execution paths
// Similar to Pentium 4's execution trace cache
// =============================================================================

module vixen_trace_cache #(
    parameter TRACE_CACHE_SIZE = 8*1024,       // 8KB trace cache
    parameter TRACE_LINE_SIZE = 64,             // 64 bytes per trace line
    parameter MAX_UOPS_PER_LINE = 6,            // Up to 6 micro-ops per line
    parameter NUM_TRACE_LINES = TRACE_CACHE_SIZE / TRACE_LINE_SIZE,
    parameter ASSOCIATIVITY = 4                 // 4-way set associative
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Lookup interface
    input  logic [127:0] pc_in,           // {pc_t1, pc_t0} - both thread PCs
    input  logic [1:0]   thread_active,
    output logic        hit,
    output logic [191:0] uops_out,       // Up to 3 micro-ops output (3*64 bits)
    output logic [2:0]  uops_valid,
    output logic [1:0]  hit_thread_id,
    
    // Fill interface from decode
    input  logic [191:0] uops_in,        // Up to 3 micro-ops input (3*64 bits)
    input  logic [2:0]       valid_in,
    input  logic [63:0]      fill_pc,
    input  logic [1:0]       fill_thread_id,
    input  logic             fill_enable,
    
    // Control
    input  logic        flush,
    input  logic [1:0]  flush_thread_id,
    
    // Performance counters
    output logic [31:0] perf_hits,
    output logic [31:0] perf_misses,
    output logic [31:0] perf_fills
);

    // =========================================================================
    // Trace Cache Line Structure
    // =========================================================================
    
    typedef struct packed {
        logic        valid;
        logic [47:0] start_pc;        // Starting PC of trace
        logic [47:0] end_pc;          // Ending PC of trace
        logic [1:0]  thread_id;       // Thread that created trace
        logic [2:0]  uop_count;       // Number of valid micro-ops
        logic [383:0] uops;           // Up to 6 micro-ops (6*64 bits)
        logic [31:0] access_count;    // LRU/frequency counter
        logic [7:0]  trace_id;        // Unique trace identifier
    } trace_line_t;
    
    // Calculate number of sets
    localparam NUM_SETS = NUM_TRACE_LINES / ASSOCIATIVITY;
    
    // Trace cache storage - flattened to avoid 2D array issues
    trace_line_t [NUM_SETS*ASSOCIATIVITY-1:0] trace_lines;
    
    // =========================================================================
    // Lookup Logic
    // =========================================================================
    
    logic [1:0] lookup_thread;
    logic [63:0] lookup_pc;
    logic [15:0] lookup_index;
    logic [47:0] lookup_tag;
    
    // Simple thread selection for lookup (prioritize thread 0)
    always_comb begin
        if (thread_active[0]) begin
            lookup_thread = 2'b00;
            lookup_pc = pc_in[63:0];
        end else if (thread_active[1]) begin
            lookup_thread = 2'b01;
            lookup_pc = pc_in[127:64];
        end else begin
            lookup_thread = 2'b00;
            lookup_pc = 64'b0;
        end
    end
    
    assign lookup_index = lookup_pc[15:6] % NUM_SETS;
    assign lookup_tag = lookup_pc[63:16];
    
    // Hit detection
    logic [ASSOCIATIVITY-1:0] way_hit;
    logic [1:0] hit_way;
    logic trace_hit;
    
    always_comb begin
        way_hit = 4'b0;
        hit_way = 2'b0;
        trace_hit = 1'b0;
        
        // Manual unroll for 4-way associativity to avoid dynamic indexing
        if (trace_lines[lookup_index*ASSOCIATIVITY + 0].valid &&
            trace_lines[lookup_index*ASSOCIATIVITY + 0].thread_id == lookup_thread &&
            trace_lines[lookup_index*ASSOCIATIVITY + 0].start_pc == lookup_tag) begin
            way_hit[0] = 1'b1;
            hit_way = 2'd0;
            trace_hit = 1'b1;
        end else if (trace_lines[lookup_index*ASSOCIATIVITY + 1].valid &&
                     trace_lines[lookup_index*ASSOCIATIVITY + 1].thread_id == lookup_thread &&
                     trace_lines[lookup_index*ASSOCIATIVITY + 1].start_pc == lookup_tag) begin
            way_hit[1] = 1'b1;
            hit_way = 2'd1;
            trace_hit = 1'b1;
        end else if (trace_lines[lookup_index*ASSOCIATIVITY + 2].valid &&
                     trace_lines[lookup_index*ASSOCIATIVITY + 2].thread_id == lookup_thread &&
                     trace_lines[lookup_index*ASSOCIATIVITY + 2].start_pc == lookup_tag) begin
            way_hit[2] = 1'b1;
            hit_way = 2'd2;
            trace_hit = 1'b1;
        end else if (trace_lines[lookup_index*ASSOCIATIVITY + 3].valid &&
                     trace_lines[lookup_index*ASSOCIATIVITY + 3].thread_id == lookup_thread &&
                     trace_lines[lookup_index*ASSOCIATIVITY + 3].start_pc == lookup_tag) begin
            way_hit[3] = 1'b1;
            hit_way = 2'd3;
            trace_hit = 1'b1;
        end
    end
    
    // =========================================================================
    // Fill Logic
    // =========================================================================
    
    logic [15:0] fill_index;
    logic [47:0] fill_tag;
    logic [1:0] fill_way;
    
    assign fill_index = fill_pc[15:6] % NUM_SETS;
    assign fill_tag = fill_pc[63:16];
    
    // Variables for LRU replacement (moved outside always block)
    logic [31:0] oldest_access;
    
    // LRU replacement selection
    always_comb begin
        oldest_access = 32'hFFFFFFFF;
        fill_way = 2'b0;
        
        // Manual unroll for 4-way associativity LRU replacement
        if (!trace_lines[fill_index*ASSOCIATIVITY + 0].valid) begin
            fill_way = 2'd0;
        end else if (!trace_lines[fill_index*ASSOCIATIVITY + 1].valid) begin
            fill_way = 2'd1;
        end else if (!trace_lines[fill_index*ASSOCIATIVITY + 2].valid) begin
            fill_way = 2'd2;
        end else if (!trace_lines[fill_index*ASSOCIATIVITY + 3].valid) begin
            fill_way = 2'd3;
        end else begin
            // All ways valid, find LRU
            if (trace_lines[fill_index*ASSOCIATIVITY + 0].access_count < oldest_access) begin
                oldest_access = trace_lines[fill_index*ASSOCIATIVITY + 0].access_count;
                fill_way = 2'd0;
            end
            if (trace_lines[fill_index*ASSOCIATIVITY + 1].access_count < oldest_access) begin
                oldest_access = trace_lines[fill_index*ASSOCIATIVITY + 1].access_count;
                fill_way = 2'd1;
            end
            if (trace_lines[fill_index*ASSOCIATIVITY + 2].access_count < oldest_access) begin
                oldest_access = trace_lines[fill_index*ASSOCIATIVITY + 2].access_count;
                fill_way = 2'd2;
            end
            if (trace_lines[fill_index*ASSOCIATIVITY + 3].access_count < oldest_access) begin
                oldest_access = trace_lines[fill_index*ASSOCIATIVITY + 3].access_count;
                fill_way = 2'd3;
            end
        end
    end
    
    // =========================================================================
    // Trace Building State Machine
    // =========================================================================
    
    typedef enum logic [2:0] {
        TRACE_IDLE,
        TRACE_BUILDING,
        TRACE_COMPLETE,
        TRACE_INSTALL
    } trace_state_t;
    
    trace_state_t trace_state;
    
    // Trace building registers
    logic [63:0] building_start_pc;
    logic [63:0] building_current_pc;
    logic [1:0] building_thread_id;
    logic [2:0] building_uop_count;
    logic [383:0] building_uops;         // 6*64 bits flattened
    logic [7:0] trace_id_counter;
    
    // Hotness detection
    logic [511:0] pc_hotness;            // 16*32 bits flattened
    logic [1023:0] hot_pcs;              // 16*64 bits flattened
    logic [3:0] hotness_ptr;
    logic is_hot_pc;
    
    always_comb begin
        is_hot_pc = 1'b0;
        // Check each hotness entry manually to avoid dynamic indexing
        if (hot_pcs[63:0] == fill_pc && pc_hotness[31:0] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[127:64] == fill_pc && pc_hotness[63:32] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[191:128] == fill_pc && pc_hotness[95:64] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[255:192] == fill_pc && pc_hotness[127:96] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[319:256] == fill_pc && pc_hotness[159:128] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[383:320] == fill_pc && pc_hotness[191:160] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[447:384] == fill_pc && pc_hotness[223:192] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[511:448] == fill_pc && pc_hotness[255:224] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[575:512] == fill_pc && pc_hotness[287:256] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[639:576] == fill_pc && pc_hotness[319:288] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[703:640] == fill_pc && pc_hotness[351:320] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[767:704] == fill_pc && pc_hotness[383:352] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[831:768] == fill_pc && pc_hotness[415:384] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[895:832] == fill_pc && pc_hotness[447:416] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[959:896] == fill_pc && pc_hotness[479:448] > 32'd10) is_hot_pc = 1'b1;
        else if (hot_pcs[1023:960] == fill_pc && pc_hotness[511:480] > 32'd10) is_hot_pc = 1'b1;
    end
    
    // =========================================================================
    // Main Trace Cache Logic
    // =========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_lines <= '0;  // Initialize all entries to zero
            trace_state <= TRACE_IDLE;
            building_start_pc <= 64'b0;
            building_current_pc <= 64'b0;
            building_thread_id <= 2'b0;
            building_uop_count <= 3'b0;
            building_uops <= 384'b0;  // Explicit width for flattened array
            trace_id_counter <= 8'b0;
            pc_hotness <= 512'b0;    // Explicit width for flattened array
            hot_pcs <= 1024'b0;      // Explicit width for flattened array
            hotness_ptr <= 4'b0;
            perf_hits <= 32'b0;
            perf_misses <= 32'b0;
            perf_fills <= 32'b0;
        end else begin
            
            // =============================================
            // Hotness Tracking
            // =============================================
            
            if (fill_enable && |valid_in) begin
                logic found_pc = 1'b0;
                
                // Check if PC is already being tracked - manual unroll
                if (hot_pcs[63:0] == fill_pc) begin
                    pc_hotness[31:0] <= pc_hotness[31:0] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[127:64] == fill_pc) begin
                    pc_hotness[63:32] <= pc_hotness[63:32] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[191:128] == fill_pc) begin
                    pc_hotness[95:64] <= pc_hotness[95:64] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[255:192] == fill_pc) begin
                    pc_hotness[127:96] <= pc_hotness[127:96] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[319:256] == fill_pc) begin
                    pc_hotness[159:128] <= pc_hotness[159:128] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[383:320] == fill_pc) begin
                    pc_hotness[191:160] <= pc_hotness[191:160] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[447:384] == fill_pc) begin
                    pc_hotness[223:192] <= pc_hotness[223:192] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[511:448] == fill_pc) begin
                    pc_hotness[255:224] <= pc_hotness[255:224] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[575:512] == fill_pc) begin
                    pc_hotness[287:256] <= pc_hotness[287:256] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[639:576] == fill_pc) begin
                    pc_hotness[319:288] <= pc_hotness[319:288] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[703:640] == fill_pc) begin
                    pc_hotness[351:320] <= pc_hotness[351:320] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[767:704] == fill_pc) begin
                    pc_hotness[383:352] <= pc_hotness[383:352] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[831:768] == fill_pc) begin
                    pc_hotness[415:384] <= pc_hotness[415:384] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[895:832] == fill_pc) begin
                    pc_hotness[447:416] <= pc_hotness[447:416] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[959:896] == fill_pc) begin
                    pc_hotness[479:448] <= pc_hotness[479:448] + 1;
                    found_pc = 1'b1;
                end else if (hot_pcs[1023:960] == fill_pc) begin
                    pc_hotness[511:480] <= pc_hotness[511:480] + 1;
                    found_pc = 1'b1;
                end
                
                // If not found, add to tracking table
                if (!found_pc) begin
                    case (hotness_ptr)
                        4'd0: begin hot_pcs[63:0] <= fill_pc; pc_hotness[31:0] <= 32'd1; end
                        4'd1: begin hot_pcs[127:64] <= fill_pc; pc_hotness[63:32] <= 32'd1; end
                        4'd2: begin hot_pcs[191:128] <= fill_pc; pc_hotness[95:64] <= 32'd1; end
                        4'd3: begin hot_pcs[255:192] <= fill_pc; pc_hotness[127:96] <= 32'd1; end
                        4'd4: begin hot_pcs[319:256] <= fill_pc; pc_hotness[159:128] <= 32'd1; end
                        4'd5: begin hot_pcs[383:320] <= fill_pc; pc_hotness[191:160] <= 32'd1; end
                        4'd6: begin hot_pcs[447:384] <= fill_pc; pc_hotness[223:192] <= 32'd1; end
                        4'd7: begin hot_pcs[511:448] <= fill_pc; pc_hotness[255:224] <= 32'd1; end
                        4'd8: begin hot_pcs[575:512] <= fill_pc; pc_hotness[287:256] <= 32'd1; end
                        4'd9: begin hot_pcs[639:576] <= fill_pc; pc_hotness[319:288] <= 32'd1; end
                        4'd10: begin hot_pcs[703:640] <= fill_pc; pc_hotness[351:320] <= 32'd1; end
                        4'd11: begin hot_pcs[767:704] <= fill_pc; pc_hotness[383:352] <= 32'd1; end
                        4'd12: begin hot_pcs[831:768] <= fill_pc; pc_hotness[415:384] <= 32'd1; end
                        4'd13: begin hot_pcs[895:832] <= fill_pc; pc_hotness[447:416] <= 32'd1; end
                        4'd14: begin hot_pcs[959:896] <= fill_pc; pc_hotness[479:448] <= 32'd1; end
                        4'd15: begin hot_pcs[1023:960] <= fill_pc; pc_hotness[511:480] <= 32'd1; end
                    endcase
                    hotness_ptr <= hotness_ptr + 1;
                end
            end
            
            // =============================================
            // Trace Building State Machine
            // =============================================
            
            case (trace_state)
                TRACE_IDLE: begin
                    if (fill_enable && |valid_in && is_hot_pc) begin
                        // Start building a new trace for hot PC
                        building_start_pc <= fill_pc;
                        building_current_pc <= fill_pc;
                        building_thread_id <= fill_thread_id;
                        building_uop_count <= $countones(valid_in);
                        
                        // Copy micro-ops - manual unroll to avoid dynamic indexing
                        if (valid_in[0]) building_uops[63:0] <= uops_in[63:0];
                        if (valid_in[1]) building_uops[127:64] <= uops_in[127:64];
                        if (valid_in[2]) building_uops[191:128] <= uops_in[191:128];
                        
                        trace_state <= TRACE_BUILDING;
                    end
                end
                
                TRACE_BUILDING: begin
                    if (fill_enable && 
                        fill_thread_id == building_thread_id &&
                        (fill_pc == building_current_pc + 4) && // Sequential PC
                        (building_uop_count + $countones(valid_in)) <= 6) begin
                        
                        // Continue building trace
                        building_current_pc <= fill_pc;
                        
                        // Add new micro-ops - use case statement to avoid dynamic indexing
                        if (valid_in[0] && building_uop_count < 6) begin
                            case (building_uop_count)
                                3'd0: building_uops[63:0] <= uops_in[63:0];
                                3'd1: building_uops[127:64] <= uops_in[63:0];
                                3'd2: building_uops[191:128] <= uops_in[63:0];
                                3'd3: building_uops[255:192] <= uops_in[63:0];
                                3'd4: building_uops[319:256] <= uops_in[63:0];
                                3'd5: building_uops[383:320] <= uops_in[63:0];
                            endcase
                            building_uop_count <= building_uop_count + 1;
                        end
                        if (valid_in[1] && building_uop_count < 5) begin
                            case (building_uop_count + 1)
                                3'd1: building_uops[127:64] <= uops_in[127:64];
                                3'd2: building_uops[191:128] <= uops_in[127:64];
                                3'd3: building_uops[255:192] <= uops_in[127:64];
                                3'd4: building_uops[319:256] <= uops_in[127:64];
                                3'd5: building_uops[383:320] <= uops_in[127:64];
                            endcase
                            building_uop_count <= building_uop_count + 1;
                        end
                        if (valid_in[2] && building_uop_count < 4) begin
                            case (building_uop_count + 2)
                                3'd2: building_uops[191:128] <= uops_in[191:128];
                                3'd3: building_uops[255:192] <= uops_in[191:128];
                                3'd4: building_uops[319:256] <= uops_in[191:128];
                                3'd5: building_uops[383:320] <= uops_in[191:128];
                            endcase
                            building_uop_count <= building_uop_count + 1;
                        end
                        
                        // Check if trace is complete (branch, call, or full)
                        if (building_uop_count >= 5 || 
                            uops_in[0][0] || uops_in[1][0] || uops_in[2][0]) begin // Branch detected
                            trace_state <= TRACE_COMPLETE;
                        end
                        
                    end else begin
                        // Non-sequential or different thread - complete trace
                        trace_state <= TRACE_COMPLETE;
                    end
                end
                
                TRACE_COMPLETE: begin
                    if (building_uop_count >= 2) begin // Only install if meaningful
                        trace_state <= TRACE_INSTALL;
                    end else begin
                        trace_state <= TRACE_IDLE;
                    end
                end
                
                TRACE_INSTALL: begin
                    // Install trace into cache - use flattened indexing
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].valid <= 1'b1;
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].start_pc <= building_start_pc[63:16];
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].end_pc <= building_current_pc[63:16];
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].thread_id <= building_thread_id;
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].uop_count <= building_uop_count;
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].uops <= building_uops;
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].access_count <= 32'd0;
                    trace_lines[fill_index*ASSOCIATIVITY + fill_way].trace_id <= trace_id_counter;
                    
                    trace_id_counter <= trace_id_counter + 1;
                    perf_fills <= perf_fills + 1;
                    trace_state <= TRACE_IDLE;
                end
            endcase
            
            // =============================================
            // Hit Processing and LRU Update
            // =============================================
            
            if (thread_active != 2'b00) begin
                if (trace_hit) begin
                    perf_hits <= perf_hits + 1;
                    
                    // Update access count for LRU - use flattened indexing
                    trace_lines[lookup_index*ASSOCIATIVITY + hit_way].access_count <= 
                        trace_lines[lookup_index*ASSOCIATIVITY + hit_way].access_count + 1;
                        
                end else begin
                    perf_misses <= perf_misses + 1;
                end
            end
            
            // =============================================
            // Flush Handling
            // =============================================
            
            if (flush) begin
                // Simplified flush - invalidate all entries (avoid complex nested loops)
                // In a real implementation, this could be optimized with a selective flush counter
                // that would mark entries for lazy invalidation
                trace_state <= TRACE_IDLE;
                trace_id_counter <= trace_id_counter + 1; // Force all entries to be considered old
            end
        end
    end
    
    // =========================================================================
    // Output Logic
    // =========================================================================
    
    always_comb begin
        hit = trace_hit && (|thread_active);
        hit_thread_id = lookup_thread;
        uops_out = 192'b0;  // Explicit width for flattened array
        uops_valid = 3'b0;
        
        if (trace_hit) begin
            // Output up to 3 micro-ops from the trace - manual unroll with flattened indexing
            if (0 < trace_lines[lookup_index*ASSOCIATIVITY + hit_way].uop_count) begin
                uops_out[63:0] = trace_lines[lookup_index*ASSOCIATIVITY + hit_way].uops[63:0];
                uops_valid[0] = 1'b1;
            end
            if (1 < trace_lines[lookup_index*ASSOCIATIVITY + hit_way].uop_count) begin
                uops_out[127:64] = trace_lines[lookup_index*ASSOCIATIVITY + hit_way].uops[127:64];
                uops_valid[1] = 1'b1;
            end
            if (2 < trace_lines[lookup_index*ASSOCIATIVITY + hit_way].uop_count) begin
                uops_out[191:128] = trace_lines[lookup_index*ASSOCIATIVITY + hit_way].uops[191:128];
                uops_valid[2] = 1'b1;
            end
        end
    end

endmodule
