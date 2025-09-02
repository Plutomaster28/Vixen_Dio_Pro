// =============================================================================
// Vixen Dio Pro L1 Instruction Cache
// =============================================================================
// 32KB, 4-way set associative, single-cycle access
// Supports SMT with thread-aware replacement policy
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
);

    // Cache line structure
    // Cache storage - flattened for synthesis
    logic cache_lines_valid [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [19:0] cache_lines_tag [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [511:0] cache_lines_data [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [1:0] cache_lines_lru_bits [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic cache_lines_thread_hint [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    
    // Address breakdown
    logic [5:0]  offset;    // Byte offset within line
    logic [8:0]  index;     // Set index
    logic [19:0] tag;       // Tag
    
    assign offset = addr[5:0];
    assign index = addr[14:6];
    assign tag = addr[63:15];
    
    // Hit detection
    logic [ASSOCIATIVITY-1:0] way_hit;
    logic [1:0] hit_way;
    logic cache_hit;
    
    always_comb begin
        way_hit = {ASSOCIATIVITY{1'b0}};
        hit_way = 2'b0;
        cache_hit = 1'b0;
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (cache_lines_valid[index][i] && cache_lines_tag[index][i] == tag) begin
                way_hit[i] = 1'b1;
                hit_way = i;
                cache_hit = 1'b1;
            end
        end
    end
    
    // LRU replacement policy
    logic [1:0] replace_way;
    logic [1:0] oldest_lru;
    
    always_comb begin
        oldest_lru = 2'b00;
        replace_way = 2'b00;
        
        // Find way with oldest LRU value
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (cache_lines_lru_bits[index][i] >= oldest_lru) begin
                oldest_lru = cache_lines_lru_bits[index][i];
                replace_way = i;
            end
        end
    end
    
    // Miss handling state machine
    typedef enum logic [1:0] {
        IDLE,
        MISS_REQ,
        MISS_WAIT,
        MISS_FILL
    } miss_state_t;
    
    miss_state_t miss_state;
    logic [63:0] miss_addr;
    logic [8:0]  miss_index;
    logic [19:0] miss_tag;
    logic [1:0]  miss_way;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SETS; i++) begin
                for (int j = 0; j < ASSOCIATIVITY; j++) begin
                    cache_lines_valid[i][j] = 1'b0;
                    cache_lines_tag[i][j] = 20'b0;
                    cache_lines_data[i][j] = 512'b0;
                    cache_lines_lru_bits[i][j] = 2'b0;
                    cache_lines_thread_hint[i][j] = 1'b0;
                end
            end
            miss_state <= IDLE;
            miss_addr <= 64'b0;
            miss_index <= 9'b0;
            miss_tag <= 20'b0;
            miss_way <= 2'b0;
            l2_req <= 1'b0;
            l2_addr <= 64'b0;
            perf_hits <= 32'b0;
            perf_misses <= 32'b0;
        end else begin
            
            case (miss_state)
                IDLE: begin
                    if (req && !cache_hit) begin
                        // Cache miss - initiate L2 request
                        miss_addr <= {addr[63:6], 6'b0}; // Align to cache line
                        miss_index <= index;
                        miss_tag <= tag;
                        miss_way <= replace_way;
                        l2_req <= 1'b1;
                        l2_addr <= {addr[63:6], 6'b0};
                        miss_state <= MISS_REQ;
                        perf_misses <= perf_misses + 1;
                    end else if (req && cache_hit) begin
                        perf_hits <= perf_hits + 1;
                        
                        // Update LRU on hit
                        for (int i = 0; i < ASSOCIATIVITY; i++) begin
                            if (i == hit_way) begin
                                cache_lines_lru_bits[index][i] <= 2'b00; // Most recently used
                            end else if (cache_lines_lru_bits[index][i] < cache_lines_lru_bits[index][hit_way]) begin
                                cache_lines_lru_bits[index][i] <= cache_lines_lru_bits[index][i] + 1;
                            end
                        end
                    end
                end
                
                MISS_REQ: begin
                    miss_state <= MISS_WAIT;
                end
                
                MISS_WAIT: begin
                    if (l2_ack) begin
                        l2_req <= 1'b0;
                        miss_state <= MISS_FILL;
                    end
                end
                
                MISS_FILL: begin
                    // Fill cache line
                    cache_lines_valid[miss_index][miss_way] <= 1'b1;
                    cache_lines_tag[miss_index][miss_way] <= miss_tag;
                    cache_lines_data[miss_index][miss_way] <= l2_data;
                    cache_lines_lru_bits[miss_index][miss_way] <= 2'b00;
                    
                    // Update LRU for other ways
                    for (int i = 0; i < ASSOCIATIVITY; i++) begin
                        if (i != miss_way) begin
                            cache_lines_lru_bits[miss_index][i] <= cache_lines_lru_bits[miss_index][i] + 1;
                        end
                    end
                    
                    miss_state <= IDLE;
                end
            endcase
        end
    end
    
    // Output logic
    assign data_out = cache_hit ? cache_lines_data[index][hit_way] : 512'b0;
    assign hit = cache_hit && (miss_state == IDLE);
    assign ready = (miss_state == IDLE) || (miss_state == MISS_FILL);

endmodule

// =============================================================================
// Vixen Dio Pro L1 Data Cache
// =============================================================================
// 32KB, 4-way set associative, single-cycle access
// Supports loads and stores with write-through policy
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
    
    // Cache status
    output logic        hit,
    
    // L2 interface
    output logic        l2_req,
    output logic [63:0] l2_addr,
    output logic [511:0] l2_wdata,
    input  logic [511:0] l2_rdata,
    output logic        l2_we,
    input  logic        l2_ack,
    
    // Performance counters
    output logic [31:0] perf_load_hits,
    output logic [31:0] perf_load_misses,
    output logic [31:0] perf_store_hits,
    output logic [31:0] perf_store_misses
);

    // Cache storage - flattened for synthesis
    logic cache_lines_valid [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic cache_lines_dirty [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [19:0] cache_lines_tag [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [511:0] cache_lines_data [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    logic [1:0] cache_lines_lru_bits [NUM_SETS-1:0][ASSOCIATIVITY-1:0];
    
    // Address breakdown (for current operation)
    logic [63:0] current_addr;
    logic [5:0]  offset;
    logic [8:0]  index;
    logic [19:0] tag;
    logic        is_load, is_store;
    
    always_comb begin
        if (load_req) begin
            current_addr = load_addr;
            is_load = 1'b1;
            is_store = 1'b0;
        end else if (store_req) begin
            current_addr = store_addr;
            is_load = 1'b0;
            is_store = 1'b1;
        end else begin
            current_addr = 64'b0;
            is_load = 1'b0;
            is_store = 1'b0;
        end
        
        offset = current_addr[5:0];
        index = current_addr[14:6];
        tag = current_addr[63:15];
    end
    
    // Hit detection
    logic [ASSOCIATIVITY-1:0] way_hit;
    logic [1:0] hit_way;
    logic cache_hit;
    
    always_comb begin
        way_hit = {ASSOCIATIVITY{1'b0}};
        hit_way = 2'b0;
        cache_hit = 1'b0;
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (cache_lines_valid[index][i] && cache_lines_tag[index][i] == tag) begin
                way_hit[i] = 1'b1;
                hit_way = i;
                cache_hit = 1'b1;
            end
        end
    end
    
    // Data extraction/insertion
    logic [511:0] cache_line_data;
    logic [511:0] updated_line_data;
    
    assign cache_line_data = cache_hit ? cache_lines_data[index][hit_way] : 512'b0;
    
    // Extract 64-bit word from cache line based on offset
    always_comb begin
        case (offset[5:3]) // Select 8-byte word within 64-byte line
            3'b000: load_data = cache_line_data[63:0];
            3'b001: load_data = cache_line_data[127:64];
            3'b010: load_data = cache_line_data[191:128];
            3'b011: load_data = cache_line_data[255:192];
            3'b100: load_data = cache_line_data[319:256];
            3'b101: load_data = cache_line_data[383:320];
            3'b110: load_data = cache_line_data[447:384];
            3'b111: load_data = cache_line_data[511:448];
        endcase
        
        // Update cache line data for stores
        updated_line_data = cache_line_data;
        case (offset[5:3])
            3'b000: updated_line_data[63:0] = store_data;
            3'b001: updated_line_data[127:64] = store_data;
            3'b010: updated_line_data[191:128] = store_data;
            3'b011: updated_line_data[255:192] = store_data;
            3'b100: updated_line_data[319:256] = store_data;
            3'b101: updated_line_data[383:320] = store_data;
            3'b110: updated_line_data[447:384] = store_data;
            3'b111: updated_line_data[511:448] = store_data;
        endcase
    end
    
    // Miss handling (simplified - write-through policy)
    typedef enum logic [1:0] {
        DCACHE_IDLE,
        DCACHE_MISS_REQ,
        DCACHE_MISS_WAIT,
        DCACHE_MISS_FILL
    } dcache_state_t;
    
    dcache_state_t dcache_state;
    logic [1:0] replace_way;
    logic [1:0] oldest_lru;
    
    // LRU replacement selection
    always_comb begin
        oldest_lru = 2'b00;
        replace_way = 2'b00;
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (cache_lines_lru_bits[index][i] >= oldest_lru) begin
                oldest_lru = cache_lines_lru_bits[index][i];
                replace_way = i;
            end
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_SETS; i++) begin
                for (int j = 0; j < ASSOCIATIVITY; j++) begin
                    cache_lines_valid[i][j] = 1'b0;
                    cache_lines_dirty[i][j] = 1'b0;
                    cache_lines_tag[i][j] = 20'b0;
                    cache_lines_data[i][j] = 512'b0;
                    cache_lines_lru_bits[i][j] = 2'b0;
                end
            end
            dcache_state <= DCACHE_IDLE;
            l2_req <= 1'b0;
            l2_addr <= 64'b0;
            l2_wdata <= 512'b0;
            l2_we <= 1'b0;
            perf_load_hits <= 32'b0;
            perf_load_misses <= 32'b0;
            perf_store_hits <= 32'b0;
            perf_store_misses <= 32'b0;
        end else begin
            
            case (dcache_state)
                DCACHE_IDLE: begin
                    if ((load_req || store_req) && cache_hit) begin
                        // Cache hit
                        if (is_load) begin
                            perf_load_hits <= perf_load_hits + 1;
                        end else begin
                            perf_store_hits <= perf_store_hits + 1;
                            // Update cache line with store data
                            cache_lines_data[index][hit_way] <= updated_line_data;
                            cache_lines_dirty[index][hit_way] <= 1'b1;
                        end
                        
                        // Update LRU
                        cache_lines_lru_bits[index][hit_way] <= 2'b00;
                        for (int i = 0; i < ASSOCIATIVITY; i++) begin
                            if (i != hit_way && cache_lines_lru_bits[index][i] < 2'b11) begin
                                cache_lines_lru_bits[index][i] <= cache_lines_lru_bits[index][i] + 1;
                            end
                        end
                        
                    end else if ((load_req || store_req) && !cache_hit) begin
                        // Cache miss - request from L2
                        if (is_load) begin
                            perf_load_misses <= perf_load_misses + 1;
                        end else begin
                            perf_store_misses <= perf_store_misses + 1;
                        end
                        
                        l2_req <= 1'b1;
                        l2_addr <= {current_addr[63:6], 6'b0}; // Align to cache line
                        l2_we <= 1'b0; // Read request
                        dcache_state <= DCACHE_MISS_REQ;
                    end
                end
                
                DCACHE_MISS_REQ: begin
                    dcache_state <= DCACHE_MISS_WAIT;
                end
                
                DCACHE_MISS_WAIT: begin
                    if (l2_ack) begin
                        l2_req <= 1'b0;
                        dcache_state <= DCACHE_MISS_FILL;
                    end
                end
                
                DCACHE_MISS_FILL: begin
                    // Fill cache line
                    cache_lines_valid[index][replace_way] <= 1'b1;
                    cache_lines_tag[index][replace_way] <= tag;
                    cache_lines_data[index][replace_way] <= is_store ? updated_line_data : l2_rdata;
                    cache_lines_dirty[index][replace_way] <= is_store;
                    cache_lines_lru_bits[index][replace_way] <= 2'b00;
                    
                    // Update LRU for other ways
                    for (int i = 0; i < ASSOCIATIVITY; i++) begin
                        if (i != replace_way && cache_lines_lru_bits[index][i] < 2'b11) begin
                            cache_lines_lru_bits[index][i] <= cache_lines_lru_bits[index][i] + 1;
                        end
                    end
                    
                    dcache_state <= DCACHE_IDLE;
                end
            endcase
        end
    end
    
    // Output signals
    assign hit = cache_hit && (dcache_state == DCACHE_IDLE);
    assign load_ack = hit && is_load;
    assign store_ack = hit && is_store;

endmodule
