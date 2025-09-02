// =============================================================================
// Vixen Dio Pro L2 Cache
// =============================================================================
// 1MB, 8-way set associative, 8-12 cycle latency
// Unified cache for both instructions and data
// =============================================================================

module vixen_l2_cache #(
    parameter int CACHE_SIZE = 1024*1024,   // 1MB
    parameter int LINE_SIZE = 64,            // 64-byte cache lines
    parameter int ASSOCIATIVITY = 8,         // 8-way set associative
    parameter int NUM_SETS = CACHE_SIZE / (LINE_SIZE * ASSOCIATIVITY),
    parameter int ACCESS_LATENCY = 10        // 8-12 cycle latency
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // L1 I-cache interface
    input  logic        l1i_req,
    input  logic [63:0] l1i_addr,
    output logic [511:0] l1i_data,
    output logic        l1i_ack,
    
    // L1 D-cache interface
    input  logic        l1d_req,
    input  logic [63:0] l1d_addr,
    input  logic [511:0] l1d_wdata,
    input  logic        l1d_we,
    output logic [511:0] l1d_rdata,
    output logic        l1d_ack,
    
    // Cache status
    output logic        hit,
    
    // L3 interface
    output logic        l3_req,
    output logic [63:0] l3_addr,
    output logic [511:0] l3_wdata,
    input  logic [511:0] l3_rdata,
    output logic        l3_we,
    input  logic        l3_ack,
    
    // Performance counters
    output logic [31:0] perf_hits,
    output logic [31:0] perf_misses,
    output logic [31:0] perf_writebacks
);

    // L2 cache line structure
    // Cache storage - flattened for synthesis  
    logic l2_cache_lines_valid [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic l2_cache_lines_dirty [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [16:0] l2_cache_lines_tag [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [511:0] l2_cache_lines_data [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [2:0] l2_cache_lines_lru_bits [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic l2_cache_lines_l1i_shared [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic l2_cache_lines_l1d_shared [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    
    // Request arbitration between L1I and L1D
    logic        current_req;
    logic [63:0] current_addr;
    logic [511:0] current_wdata;
    logic        current_we;
    logic        req_from_l1i;
    logic        req_from_l1d;
    
    // Simple round-robin arbitration
    logic        arb_priority; // 0 = L1I priority, 1 = L1D priority
    
    always_comb begin
        current_req = 1'b0;
        current_addr = 64'b0;
        current_wdata = 512'b0;
        current_we = 1'b0;
        req_from_l1i = 1'b0;
        req_from_l1d = 1'b0;
        
        if (arb_priority == 1'b0) begin
            // L1I has priority
            if (l1i_req) begin
                current_req = 1'b1;
                current_addr = l1i_addr;
                current_we = 1'b0;
                req_from_l1i = 1'b1;
            end else if (l1d_req) begin
                current_req = 1'b1;
                current_addr = l1d_addr;
                current_wdata = l1d_wdata;
                current_we = l1d_we;
                req_from_l1d = 1'b1;
            end
        end else begin
            // L1D has priority
            if (l1d_req) begin
                current_req = 1'b1;
                current_addr = l1d_addr;
                current_wdata = l1d_wdata;
                current_we = l1d_we;
                req_from_l1d = 1'b1;
            end else if (l1i_req) begin
                current_req = 1'b1;
                current_addr = l1i_addr;
                current_we = 1'b0;
                req_from_l1i = 1'b1;
            end
        end
    end
    
    // Address breakdown
    logic [5:0]  offset;
    logic [12:0] index;
    logic [16:0] tag;
    
    assign offset = current_addr[5:0];
    assign index = current_addr[18:6];
    assign tag = current_addr[63:19];
    
    // Hit detection
    logic [ASSOCIATIVITY-1:0] way_hit;
    logic [2:0] hit_way;
    logic cache_hit;
    
    always_comb begin
        way_hit = '0;
        hit_way = 3'b0;
        cache_hit = 1'b0;
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (l2_cache_lines_valid[index][i] && l2_cache_lines_tag[index][i] == tag) begin
                way_hit[i] = 1'b1;
                hit_way = i;
                cache_hit = 1'b1;
            end
        end
    end
    
    // LRU replacement policy for 8-way
    logic [2:0] replace_way;
    
    logic [2:0] oldest_lru;

    always_comb begin
        oldest_lru = 3'b000;
        replace_way = 3'b000;
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (l2_cache_lines_lru_bits[index][i] >= oldest_lru) begin
                oldest_lru = l2_cache_lines_lru_bits[index][i];
                replace_way = i;
            end
        end
    end
    
    // Access latency pipeline
    // L2 Pipeline - flattened for synthesis
    logic l2_pipeline_valid [ACCESS_LATENCY-1:0];
    logic l2_pipeline_from_l1i [ACCESS_LATENCY-1:0];
    logic l2_pipeline_from_l1d [ACCESS_LATENCY-1:0];
    logic l2_pipeline_is_write [ACCESS_LATENCY-1:0];
    logic [12:0] l2_pipeline_req_index [ACCESS_LATENCY-1:0];
    logic [16:0] l2_pipeline_req_tag [ACCESS_LATENCY-1:0];
    logic [2:0] l2_pipeline_req_way [ACCESS_LATENCY-1:0];
    logic [511:0] l2_pipeline_req_wdata [ACCESS_LATENCY-1:0];
    logic l2_pipeline_req_hit [ACCESS_LATENCY-1:0];
    
    // L2 cache state machine
    typedef enum logic [2:0] {
        L2_IDLE,
        L2_ACCESS,
        L2_MISS_REQ,
        L2_MISS_WAIT,
        L2_WRITEBACK,
        L2_FILL
    } l2_state_t;
    
    l2_state_t l2_state;
    logic [63:0] miss_addr;
    logic [2:0]  miss_way;
    logic [12:0] miss_index;
    logic [16:0] miss_tag;
    logic        miss_from_l1i, miss_from_l1d;
    logic        writeback_needed;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SETS; i++) begin
                for (int j = 0; j < ASSOCIATIVITY; j++) begin
                    l2_cache_lines_valid[i][j] = 1'b0;
                    l2_cache_lines_dirty[i][j] = 1'b0;
                    l2_cache_lines_tag[i][j] = 17'b0;
                    l2_cache_lines_data[i][j] = 512'b0;
                    l2_cache_lines_lru_bits[i][j] = 3'b0;
                    l2_cache_lines_l1i_shared[i][j] = 1'b0;
                    l2_cache_lines_l1d_shared[i][j] = 1'b0;
                end
            end
            l2_state <= L2_IDLE;
            arb_priority <= 1'b0;
            for (int k = 0; k < ACCESS_LATENCY; k++) begin
                l2_pipeline_valid[k] <= 1'b0;
                l2_pipeline_from_l1i[k] <= 1'b0;
                l2_pipeline_from_l1d[k] <= 1'b0;
                l2_pipeline_is_write[k] <= 1'b0;
                l2_pipeline_req_index[k] <= 13'b0;
                l2_pipeline_req_tag[k] <= 17'b0;
                l2_pipeline_req_way[k] <= 3'b0;
                l2_pipeline_req_wdata[k] <= 512'b0;
                l2_pipeline_req_hit[k] <= 1'b0;
            end
            l3_addr <= 64'b0;
            l3_wdata <= 512'b0;
            l3_we <= 1'b0;
            perf_hits <= 32'b0;
            perf_misses <= 32'b0;
            perf_writebacks <= 32'b0;
        end else begin
            
            // Arbitration priority toggle
            if (current_req) begin
                arb_priority <= ~arb_priority;
            end
            
            // Pipeline stages
            for (int i = ACCESS_LATENCY-1; i > 0; i--) begin
                l2_pipeline_valid[i] <= l2_pipeline_valid[i-1];
                l2_pipeline_from_l1i[i] <= l2_pipeline_from_l1i[i-1];
                l2_pipeline_from_l1d[i] <= l2_pipeline_from_l1d[i-1];
                l2_pipeline_is_write[i] <= l2_pipeline_is_write[i-1];
                l2_pipeline_req_index[i] <= l2_pipeline_req_index[i-1];
                l2_pipeline_req_tag[i] <= l2_pipeline_req_tag[i-1];
                l2_pipeline_req_way[i] <= l2_pipeline_req_way[i-1];
                l2_pipeline_req_wdata[i] <= l2_pipeline_req_wdata[i-1];
                l2_pipeline_req_hit[i] <= l2_pipeline_req_hit[i-1];
            end
            
            // Pipeline stage 0 (input)
            l2_pipeline_valid[0] <= current_req && (l2_state == L2_IDLE);
            l2_pipeline_from_l1i[0] <= req_from_l1i;
            l2_pipeline_from_l1d[0] <= req_from_l1d;
            l2_pipeline_is_write[0] <= current_we;
            l2_pipeline_req_index[0] <= index;
            l2_pipeline_req_tag[0] <= tag;
            l2_pipeline_req_way[0] <= cache_hit ? hit_way : replace_way;
            l2_pipeline_req_wdata[0] <= current_wdata;
            l2_pipeline_req_hit[0] <= cache_hit;
            
            // State machine
            case (l2_state)
                L2_IDLE: begin
                    if (current_req) begin
                        l2_state <= L2_ACCESS;
                    end
                end
                
                L2_ACCESS: begin
                    // Wait for pipeline to complete
                    if (l2_pipeline_valid[ACCESS_LATENCY-1]) begin
                        if (l2_pipeline_req_hit[ACCESS_LATENCY-1]) begin
                            // Cache hit
                            perf_hits <= perf_hits + 1;
                            
                            if (l2_pipeline_is_write[ACCESS_LATENCY-1]) begin
                                // Write hit - update cache line
                                l2_cache_lines_data[l2_pipeline_req_index[ACCESS_LATENCY-1]][l2_pipeline_req_way[ACCESS_LATENCY-1]] <= l2_pipeline_req_wdata[ACCESS_LATENCY-1];
                                l2_cache_lines_dirty[l2_pipeline_req_index[ACCESS_LATENCY-1]][l2_pipeline_req_way[ACCESS_LATENCY-1]] <= 1'b1;
                            end
                            
                            // Update LRU
                            l2_cache_lines_lru_bits[l2_pipeline_req_index[ACCESS_LATENCY-1]][l2_pipeline_req_way[ACCESS_LATENCY-1]] <= 3'b000;
                            for (int i = 0; i < ASSOCIATIVITY; i++) begin
                                if (i != l2_pipeline_req_way[ACCESS_LATENCY-1]) begin
                                    if (l2_cache_lines_lru_bits[l2_pipeline_req_index[ACCESS_LATENCY-1]][i] < 3'b111) begin
                                        l2_cache_lines_lru_bits[l2_pipeline_req_index[ACCESS_LATENCY-1]][i] <= 
                                            l2_cache_lines_lru_bits[l2_pipeline_req_index[ACCESS_LATENCY-1]][i] + 1;
                                    end
                                end
                            end
                            
                            l2_state <= L2_IDLE;
                            
                        end else begin
                            // Cache miss
                            perf_misses <= perf_misses + 1;
                            miss_addr <= {l2_pipeline_req_tag[ACCESS_LATENCY-1], l2_pipeline_req_index[ACCESS_LATENCY-1], 6'b0};
                            miss_way <= l2_pipeline_req_way[ACCESS_LATENCY-1];
                            miss_index <= l2_pipeline_req_index[ACCESS_LATENCY-1];
                            miss_tag <= l2_pipeline_req_tag[ACCESS_LATENCY-1];
                            miss_from_l1i <= l2_pipeline_from_l1i[ACCESS_LATENCY-1];
                            miss_from_l1d <= l2_pipeline_from_l1d[ACCESS_LATENCY-1];
                            
                            // Check if we need to writeback
                            writeback_needed <= l2_cache_lines_dirty[l2_pipeline_req_index[ACCESS_LATENCY-1]][l2_pipeline_req_way[ACCESS_LATENCY-1]];
                            
                            if (l2_cache_lines_dirty[l2_pipeline_req_index[ACCESS_LATENCY-1]][l2_pipeline_req_way[ACCESS_LATENCY-1]]) begin
                                l2_state <= L2_WRITEBACK;
                            end else begin
                                l2_state <= L2_MISS_REQ;
                            end
                        end
                    end
                end
                
                L2_WRITEBACK: begin
                    // Writeback dirty line to L3
                    l3_req <= 1'b1;
                    l3_addr <= {l2_cache_lines_tag[miss_index][miss_way], miss_index, 6'b0};
                    l3_wdata <= l2_cache_lines_data[miss_index][miss_way];
                    l3_we <= 1'b1;
                    perf_writebacks <= perf_writebacks + 1;
                    l2_state <= L2_MISS_REQ;
                end
                
                L2_MISS_REQ: begin
                    // Request miss line from L3
                    l3_req <= 1'b1;
                    l3_addr <= miss_addr;
                    l3_we <= 1'b0;
                    l2_state <= L2_MISS_WAIT;
                end
                
                L2_MISS_WAIT: begin
                    if (l3_ack) begin
                        l3_req <= 1'b0;
                        l2_state <= L2_FILL;
                    end
                end
                
                L2_FILL: begin
                    // Fill cache line
                    l2_cache_lines_valid[miss_index][miss_way] <= 1'b1;
                    l2_cache_lines_dirty[miss_index][miss_way] <= 1'b0;
                    l2_cache_lines_tag[miss_index][miss_way] <= miss_tag;
                    l2_cache_lines_data[miss_index][miss_way] <= l3_rdata;
                    l2_cache_lines_lru_bits[miss_index][miss_way] <= 3'b000;
                    l2_cache_lines_l1i_shared[miss_index][miss_way] <= miss_from_l1i;
                    l2_cache_lines_l1d_shared[miss_index][miss_way] <= miss_from_l1d;
                    
                    // Update LRU for other ways
                    for (int i = 0; i < ASSOCIATIVITY; i++) begin
                        if (i != miss_way && l2_cache_lines_lru_bits[miss_index][i] < 3'b111) begin
                            l2_cache_lines_lru_bits[miss_index][i] <= l2_cache_lines_lru_bits[miss_index][i] + 1;
                        end
                    end
                    
                    l2_state <= L2_IDLE;
                end
            endcase
        end
    end
    
    // Output logic
    logic pipeline_hit;
    logic [511:0] pipeline_data;
    
    assign pipeline_hit = l2_pipeline_valid[ACCESS_LATENCY-1] && l2_pipeline_req_hit[ACCESS_LATENCY-1];
    assign pipeline_data = pipeline_hit ? 
           l2_cache_lines_data[l2_pipeline_req_index[ACCESS_LATENCY-1]][l2_pipeline_req_way[ACCESS_LATENCY-1]] : 
           l3_rdata;
    
    assign hit = pipeline_hit;
    assign l1i_data = pipeline_data;
    assign l1d_rdata = pipeline_data;
    assign l1i_ack = pipeline_hit && l2_pipeline_from_l1i[ACCESS_LATENCY-1];
    assign l1d_ack = (pipeline_hit || (l2_state == L2_FILL)) && l2_pipeline_from_l1d[ACCESS_LATENCY-1];

endmodule

// =============================================================================
// Vixen Dio Pro L3 Cache
// =============================================================================
// 2MB, 16-way set associative, 12-20 cycle latency
// Last level cache before main memory
// =============================================================================

module vixen_l3_cache #(
    parameter int CACHE_SIZE = 2*1024*1024, // 2MB
    parameter int LINE_SIZE = 64,            // 64-byte cache lines
    parameter int ASSOCIATIVITY = 16,        // 16-way set associative
    parameter int NUM_SETS = CACHE_SIZE / (LINE_SIZE * ASSOCIATIVITY),
    parameter int ACCESS_LATENCY = 16        // 12-20 cycle latency
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // L2 interface
    input  logic        l2_req,
    input  logic [63:0] l2_addr,
    input  logic [511:0] l2_wdata,
    input  logic        l2_we,
    output logic [511:0] l2_rdata,
    output logic        l2_ack,
    
    // Cache status
    output logic        hit,
    
    // Main memory interface
    output logic [63:0] mem_addr,
    output logic [511:0] mem_wdata,
    input  logic [511:0] mem_rdata,
    output logic        mem_we,
    output logic        mem_req,
    input  logic        mem_ack,
    input  logic        mem_ready,
    
    // Performance counters
    output logic [31:0] perf_hits,
    output logic [31:0] perf_misses,
    output logic [31:0] perf_writebacks
);

    // L3 cache line structure
    // L3 cache line arrays
    logic l3_cache_lines_valid [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic l3_cache_lines_dirty [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [13:0] l3_cache_lines_tag [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [511:0] l3_cache_lines_data [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [3:0] l3_cache_lines_lru_bits [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    
    // Cache storage
    
    // Address breakdown
    logic [5:0]  offset;
    logic [15:0] index;
    logic [13:0] tag;
    
    assign offset = l2_addr[5:0];
    assign index = l2_addr[21:6];
    assign tag = l2_addr[63:22];
    
    // Hit detection
    logic [ASSOCIATIVITY-1:0] way_hit;
    logic [3:0] hit_way;
    logic cache_hit;
    
    always_comb begin
        way_hit = '0;
        hit_way = 4'b0;
        cache_hit = 1'b0;
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (l3_cache_lines_valid[index][i] && l3_cache_lines_tag[index][i] == tag) begin
                way_hit[i] = 1'b1;
                hit_way = i;
                cache_hit = 1'b1;
            end
        end
    end
    
    // LRU replacement policy for 16-way
    logic [3:0] replace_way;
    logic [3:0] oldest_lru;
    
    always_comb begin
        oldest_lru = 4'b0000;
        replace_way = 4'b0000;
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (l3_cache_lines_lru_bits[index][i] >= oldest_lru) begin
                oldest_lru = l3_cache_lines_lru_bits[index][i];
                replace_way = i;
            end
        end
    end
    
    // Access latency pipeline
    // L3 pipeline arrays
    // L3 pipeline arrays
    logic l3_pipeline_valid [ACCESS_LATENCY-1:0];
    logic l3_pipeline_is_write [ACCESS_LATENCY-1:0];
    logic [15:0] l3_pipeline_req_index [ACCESS_LATENCY-1:0];
    logic [13:0] l3_pipeline_req_tag [ACCESS_LATENCY-1:0];
    logic [3:0] l3_pipeline_req_way [ACCESS_LATENCY-1:0];
    logic [511:0] l3_pipeline_req_wdata [ACCESS_LATENCY-1:0];
    logic l3_pipeline_req_hit [ACCESS_LATENCY-1:0];

    typedef enum logic [2:0] {
        L3_IDLE,
        L3_ACCESS,
        L3_MISS_REQ,
        L3_MISS_WAIT,
        L3_WRITEBACK,
        L3_FILL
    } l3_state_t;
    
    l3_state_t l3_state;
    logic [63:0] miss_addr;
    logic [3:0]  miss_way;
    logic [15:0] miss_index;
    logic [13:0] miss_tag;
    logic        writeback_needed;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SETS; i++) begin
                for (int j = 0; j < ASSOCIATIVITY; j++) begin
                    l3_cache_lines_valid[i][j] = 1'b0;
                    l3_cache_lines_dirty[i][j] = 1'b0;
                    l3_cache_lines_tag[i][j] = 14'b0;
                    l3_cache_lines_data[i][j] = 512'b0;
                    l3_cache_lines_lru_bits[i][j] = 4'b0;
                end
            end
            for (int i = 0; i < ACCESS_LATENCY; i++) begin
                l3_pipeline_valid[i] <= 1'b0;
                l3_pipeline_is_write[i] <= 1'b0;
                l3_pipeline_req_index[i] <= 16'b0;
                l3_pipeline_req_tag[i] <= 14'b0;
                l3_pipeline_req_way[i] <= 4'b0;
                l3_pipeline_req_wdata[i] <= 512'b0;
                l3_pipeline_req_hit[i] <= 1'b0;
            end
            l3_state <= L3_IDLE;
            mem_req <= 1'b0;
            mem_addr <= 64'b0;
            mem_wdata <= 512'b0;
            mem_we <= 1'b0;
            perf_hits <= 32'b0;
            perf_misses <= 32'b0;
            perf_writebacks <= 32'b0;
        end else begin
            
            // Pipeline stages
            for (int i = ACCESS_LATENCY-1; i > 0; i--) begin
                l3_pipeline_valid[i] <= l3_pipeline_valid[i-1];
                l3_pipeline_is_write[i] <= l3_pipeline_is_write[i-1];
                l3_pipeline_req_index[i] <= l3_pipeline_req_index[i-1];
                l3_pipeline_req_tag[i] <= l3_pipeline_req_tag[i-1];
                l3_pipeline_req_way[i] <= l3_pipeline_req_way[i-1];
                l3_pipeline_req_wdata[i] <= l3_pipeline_req_wdata[i-1];
                l3_pipeline_req_hit[i] <= l3_pipeline_req_hit[i-1];
            end
            
            // Pipeline stage 0 (input)
            l3_pipeline_valid[0] <= l2_req && (l3_state == L3_IDLE);
            l3_pipeline_is_write[0] <= l2_we;
            l3_pipeline_req_index[0] <= index;
            l3_pipeline_req_tag[0] <= tag;
            l3_pipeline_req_way[0] <= cache_hit ? hit_way : replace_way;
            l3_pipeline_req_wdata[0] <= l2_wdata;
            l3_pipeline_req_hit[0] <= cache_hit;
            
            // State machine
            case (l3_state)
                L3_IDLE: begin
                    if (l2_req) begin
                        l3_state <= L3_ACCESS;
                    end
                end
                
                L3_ACCESS: begin
                    // Wait for pipeline to complete
                    if (l3_pipeline_valid[ACCESS_LATENCY-1]) begin
                        if (l3_pipeline_req_hit[ACCESS_LATENCY-1]) begin
                            // Cache hit
                            perf_hits <= perf_hits + 1;
                            
                            if (l3_pipeline_is_write[ACCESS_LATENCY-1]) begin
                                // Write hit
                                l3_cache_lines_data[l3_pipeline_req_index[ACCESS_LATENCY-1]][l3_pipeline_req_way[ACCESS_LATENCY-1]] <= l3_pipeline_req_wdata[ACCESS_LATENCY-1];
                                l3_cache_lines_dirty[l3_pipeline_req_index[ACCESS_LATENCY-1]][l3_pipeline_req_way[ACCESS_LATENCY-1]] <= 1'b1;
                            end
                            
                            // Update LRU
                            l3_cache_lines_lru_bits[l3_pipeline_req_index[ACCESS_LATENCY-1]][l3_pipeline_req_way[ACCESS_LATENCY-1]] <= 4'b0000;
                            for (int i = 0; i < ASSOCIATIVITY; i++) begin
                                if (i != l3_pipeline_req_way[ACCESS_LATENCY-1]) begin
                                    if (l3_cache_lines_lru_bits[l3_pipeline_req_index[ACCESS_LATENCY-1]][i] < 4'b1111) begin
                                        l3_cache_lines_lru_bits[l3_pipeline_req_index[ACCESS_LATENCY-1]][i] <= 
                                            l3_cache_lines_lru_bits[l3_pipeline_req_index[ACCESS_LATENCY-1]][i] + 1;
                                    end
                                end
                            end
                            
                            l3_state <= L3_IDLE;
                            
                        end else begin
                            // Cache miss
                            perf_misses <= perf_misses + 1;
                            miss_addr <= {l3_pipeline_req_tag[ACCESS_LATENCY-1], l3_pipeline_req_index[ACCESS_LATENCY-1], 6'b0};
                            miss_way <= l3_pipeline_req_way[ACCESS_LATENCY-1];
                            miss_index <= l3_pipeline_req_index[ACCESS_LATENCY-1];
                            miss_tag <= l3_pipeline_req_tag[ACCESS_LATENCY-1];
                            
                            // Check if we need to writeback
                            writeback_needed <= l3_cache_lines_dirty[l3_pipeline_req_index[ACCESS_LATENCY-1]][l3_pipeline_req_way[ACCESS_LATENCY-1]];
                            
                            if (l3_cache_lines_dirty[l3_pipeline_req_index[ACCESS_LATENCY-1]][l3_pipeline_req_way[ACCESS_LATENCY-1]]) begin
                                l3_state <= L3_WRITEBACK;
                            end else begin
                                l3_state <= L3_MISS_REQ;
                            end
                        end
                    end
                end
                
                L3_WRITEBACK: begin
                    // Writeback dirty line to memory
                    mem_req <= 1'b1;
                    mem_addr <= {l3_cache_lines_tag[miss_index][miss_way], miss_index, 6'b0};
                    mem_wdata <= l3_cache_lines_data[miss_index][miss_way];
                    mem_we <= 1'b1;
                    perf_writebacks <= perf_writebacks + 1;
                    l3_state <= L3_MISS_REQ;
                end
                
                L3_MISS_REQ: begin
                    // Request miss line from memory
                    mem_req <= 1'b1;
                    mem_addr <= miss_addr;
                    mem_we <= 1'b0;
                    l3_state <= L3_MISS_WAIT;
                end
                
                L3_MISS_WAIT: begin
                    if (mem_ack && mem_ready) begin
                        mem_req <= 1'b0;
                        l3_state <= L3_FILL;
                    end
                end
                
                L3_FILL: begin
                    // Fill cache line
                    l3_cache_lines_valid[miss_index][miss_way] <= 1'b1;
                    l3_cache_lines_dirty[miss_index][miss_way] <= 1'b0;
                    l3_cache_lines_tag[miss_index][miss_way] <= miss_tag;
                    l3_cache_lines_data[miss_index][miss_way] <= mem_rdata;
                    l3_cache_lines_lru_bits[miss_index][miss_way] <= 4'b0000;
                    
                    // Update LRU for other ways
                    for (int i = 0; i < ASSOCIATIVITY; i++) begin
                        if (i != miss_way && l3_cache_lines_lru_bits[miss_index][i] < 4'b1111) begin
                            l3_cache_lines_lru_bits[miss_index][i] <= l3_cache_lines_lru_bits[miss_index][i] + 1;
                        end
                    end
                    
                    l3_state <= L3_IDLE;
                end
            endcase
        end
    end
    
    // Output logic
    logic pipeline_hit;
    logic [511:0] pipeline_data;
    
    assign pipeline_hit = l3_pipeline_valid[ACCESS_LATENCY-1] && l3_pipeline_req_hit[ACCESS_LATENCY-1];
    assign pipeline_data = pipeline_hit ? 
           l3_cache_lines_data[l3_pipeline_req_index[ACCESS_LATENCY-1]][l3_pipeline_req_way[ACCESS_LATENCY-1]] : 
           mem_rdata;
    
    assign hit = pipeline_hit;
    assign l2_rdata = pipeline_data;
    assign l2_ack = pipeline_hit || (l3_state == L3_FILL);

endmodule
