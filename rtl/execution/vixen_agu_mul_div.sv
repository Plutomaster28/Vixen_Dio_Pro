// =============================================================================
// Vixen Dio Pro Address Generation Unit (AGU)
// =============================================================================
// Handles memory address calculation and load/store operations
// Supports complex x86-64 addressing modes
// =============================================================================

module vixen_agu (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        issue_valid,
    input  logic [63:0] issue_uop,
    input  logic [5:0]  issue_rob_id,
    input  logic [1:0]  issue_thread_id,
    output logic [63:0] result,
    output logic [5:0]  rob_id_out,
    output logic [1:0]  thread_id_out,
    output logic        complete,
    output logic        busy,
    
    // Memory interface
    output logic [63:0] mem_load_addr,
    output logic [63:0] mem_store_addr,
    input  logic [63:0] mem_load_data,
    output logic [63:0] mem_store_data,
    output logic        mem_load_req,
    output logic        mem_store_req,
    input  logic        mem_load_ack,
    input  logic        mem_store_ack
);

    // AGU pipeline stages
    typedef struct packed {
        logic        valid;
        logic [5:0]  rob_id;
        logic [1:0]  thread_id;
        logic [63:0] address;
        logic [63:0] data;
        logic        is_load;
        logic        is_store;
    } agu_pipe_t;
    
    agu_pipe_t [2:0] agu_pipe; // 3-stage pipeline (addr calc, mem access, result)
    
    // Address calculation components
    logic [63:0] base_addr, index_addr, displacement;
    logic [2:0]  scale_factor;
    logic [63:0] effective_addr;
    logic        is_load, is_store;
    
    // Decode AGU operation
    always_comb begin
        base_addr = issue_uop[31:16];      // Base register value
        index_addr = issue_uop[47:32];     // Index register value  
        displacement = issue_uop[63:48];   // Displacement (sign-extended)
        scale_factor = issue_uop[2:0];     // Scale factor (1, 2, 4, 8)
        is_load = issue_uop[4];            // Load operation flag
        is_store = issue_uop[5];           // Store operation flag
        
        // Calculate effective address: base + (index * scale) + displacement
        case (scale_factor)
            3'b000: effective_addr = base_addr + index_addr + displacement;           // scale = 1
            3'b001: effective_addr = base_addr + (index_addr << 1) + displacement;   // scale = 2
            3'b010: effective_addr = base_addr + (index_addr << 2) + displacement;   // scale = 4
            3'b011: effective_addr = base_addr + (index_addr << 3) + displacement;   // scale = 8
            default: effective_addr = base_addr + displacement;                       // No index
        endcase
    end
    
    // AGU pipeline
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            agu_pipe[0] <= '0;
            agu_pipe[1] <= '0;
            agu_pipe[2] <= '0;
            mem_load_req <= 1'b0;
            mem_store_req <= 1'b0;
            mem_load_addr <= 64'b0;
            mem_store_addr <= 64'b0;
            mem_store_data <= 64'b0;
        end else begin
            // Stage 1: Address calculation
            agu_pipe[0].valid <= issue_valid;
            agu_pipe[0].rob_id <= issue_rob_id;
            agu_pipe[0].thread_id <= issue_thread_id;
            agu_pipe[0].address <= effective_addr;
            agu_pipe[0].data <= issue_uop[63:32]; // Store data (if applicable)
            agu_pipe[0].is_load <= is_load;
            agu_pipe[0].is_store <= is_store;
            
            // Stage 2: Memory access
            agu_pipe[1] <= agu_pipe[0];
            
            if (agu_pipe[0].valid) begin
                if (agu_pipe[0].is_load) begin
                    mem_load_addr <= agu_pipe[0].address;
                    mem_load_req <= 1'b1;
                end else if (agu_pipe[0].is_store) begin
                    mem_store_addr <= agu_pipe[0].address;
                    mem_store_data <= agu_pipe[0].data;
                    mem_store_req <= 1'b1;
                end
            end else begin
                mem_load_req <= 1'b0;
                mem_store_req <= 1'b0;
            end
            
            // Stage 3: Result
            agu_pipe[2] <= agu_pipe[1];
            
            // Handle memory acknowledgments
            if (mem_load_ack) begin
                agu_pipe[2].data <= mem_load_data;
                mem_load_req <= 1'b0;
            end
            
            if (mem_store_ack) begin
                mem_store_req <= 1'b0;
            end
        end
    end
    
    // Output results
    assign result = agu_pipe[2].is_load ? agu_pipe[2].data : agu_pipe[2].address;
    assign rob_id_out = agu_pipe[2].rob_id;
    assign thread_id_out = agu_pipe[2].thread_id;
    assign complete = agu_pipe[2].valid && 
                     ((agu_pipe[2].is_load && mem_load_ack) || 
                      (agu_pipe[2].is_store && mem_store_ack) ||
                      (!agu_pipe[2].is_load && !agu_pipe[2].is_store));
    assign busy = agu_pipe[0].valid || agu_pipe[1].valid || agu_pipe[2].valid;

endmodule

// =============================================================================
// Vixen Dio Pro Multiplier Unit
// =============================================================================
// Handles integer multiplication with 3-4 cycle latency
// =============================================================================

module vixen_multiplier (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        issue_valid,
    input  logic [63:0] issue_uop,
    input  logic [5:0]  issue_rob_id,
    input  logic [1:0]  issue_thread_id,
    output logic [63:0] result,
    output logic [5:0]  rob_id_out,
    output logic [1:0]  thread_id_out,
    output logic        complete,
    output logic        busy
);

    // Multiplier pipeline (4 stages)
    typedef struct packed {
        logic        valid;
        logic [5:0]  rob_id;
        logic [1:0]  thread_id;
        logic [63:0] operand_a;
        logic [63:0] operand_b;
        logic [127:0] partial_product;
        logic [63:0] final_result;
    } mul_pipe_t;
    
    mul_pipe_t [3:0] mul_pipe;
    
    // Extract operands
    logic [63:0] op_a, op_b;
    assign op_a = issue_uop[31:16];
    assign op_b = issue_uop[47:32];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_pipe[0] <= '0;
            mul_pipe[1] <= '0;
            mul_pipe[2] <= '0;
        end else begin
            // Stage 1: Operand setup
            mul_pipe[0].valid <= issue_valid;
            mul_pipe[0].rob_id <= issue_rob_id;
            mul_pipe[0].thread_id <= issue_thread_id;
            mul_pipe[0].operand_a <= op_a;
            mul_pipe[0].operand_b <= op_b;
            
            // Stage 2: Partial multiplication
            mul_pipe[1] <= mul_pipe[0];
            if (mul_pipe[0].valid) begin
                mul_pipe[1].partial_product <= mul_pipe[0].operand_a[31:0] * mul_pipe[0].operand_b[31:0];
            end
            
            // Stage 3: Full multiplication
            mul_pipe[2] <= mul_pipe[1];
            if (mul_pipe[1].valid) begin
                mul_pipe[2].partial_product <= mul_pipe[1].operand_a * mul_pipe[1].operand_b;
            end
            
            // Stage 4: Result
            mul_pipe[3] <= mul_pipe[2];
            if (mul_pipe[2].valid) begin
                mul_pipe[3].final_result <= mul_pipe[2].partial_product[63:0]; // Take lower 64 bits
            end
        end
    end
    
    assign result = mul_pipe[3].final_result;
    assign rob_id_out = mul_pipe[3].rob_id;
    assign thread_id_out = mul_pipe[3].thread_id;
    assign complete = mul_pipe[3].valid;
    assign busy = |{mul_pipe[3].valid, mul_pipe[2].valid, mul_pipe[1].valid, mul_pipe[0].valid};

endmodule

// =============================================================================
// Vixen Dio Pro Divider Unit
// =============================================================================
// Iterative divider with 10-20 cycle latency (P4-style)
// =============================================================================

module vixen_divider (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        issue_valid,
    input  logic [63:0] issue_uop,
    input  logic [5:0]  issue_rob_id,
    input  logic [1:0]  issue_thread_id,
    output logic [63:0] result,
    output logic [5:0]  rob_id_out,
    output logic [1:0]  thread_id_out,
    output logic        complete,
    output logic        busy
);

    // Divider state machine
    typedef enum logic [2:0] {
        DIV_IDLE,
        DIV_SETUP,
        DIV_ITERATE,
        DIV_NORMALIZE,
        DIV_COMPLETE
    } div_state_t;
    
    div_state_t div_state;
    
    // Divider registers
    logic [63:0] dividend, divisor, quotient, remainder;
    logic [5:0]  iteration_count;
    logic [5:0]  stored_rob_id;
    logic [1:0]  stored_thread_id;
    logic [6:0]  div_cycles; // Variable cycle count (10-20)
    
    // Extract operands
    logic [63:0] op_a, op_b;
    assign op_a = issue_uop[31:16]; // Dividend
    assign op_b = issue_uop[47:32]; // Divisor
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_state <= DIV_IDLE;
            dividend <= 64'b0;
            divisor <= 64'b0;
            quotient <= 64'b0;
            remainder <= 64'b0;
            iteration_count <= 6'b0;
            stored_rob_id <= 6'b0;
            stored_thread_id <= 2'b0;
            div_cycles <= 7'd15; // Default 15 cycles
        end else begin
            case (div_state)
                DIV_IDLE: begin
                    if (issue_valid) begin
                        dividend <= op_a;
                        divisor <= op_b;
                        quotient <= 64'b0;
                        remainder <= 64'b0;
                        iteration_count <= 6'b0;
                        stored_rob_id <= issue_rob_id;
                        stored_thread_id <= issue_thread_id;
                        
                        // Variable latency based on operand size
                        if (op_b[63:32] == 32'b0) div_cycles <= 7'd10; // Small divisor
                        else if (op_a[63:32] == 32'b0) div_cycles <= 7'd12; // Small dividend
                        else div_cycles <= 7'd20; // Large operands
                        
                        div_state <= DIV_SETUP;
                    end
                end
                
                DIV_SETUP: begin
                    remainder <= dividend;
                    div_state <= DIV_ITERATE;
                end
                
                DIV_ITERATE: begin
                    if (iteration_count < div_cycles) begin
                        // Simplified radix-2 division step
                        if (remainder >= divisor) begin
                            remainder <= remainder - divisor;
                            quotient <= (quotient << 1) | 1'b1;
                        end else begin
                            quotient <= quotient << 1;
                        end
                        iteration_count <= iteration_count + 1;
                    end else begin
                        div_state <= DIV_NORMALIZE;
                    end
                end
                
                DIV_NORMALIZE: begin
                    // Final result adjustment
                    div_state <= DIV_COMPLETE;
                end
                
                DIV_COMPLETE: begin
                    div_state <= DIV_IDLE;
                end
            endcase
        end
    end
    
    assign result = quotient;
    assign rob_id_out = stored_rob_id;
    assign thread_id_out = stored_thread_id;
    assign complete = (div_state == DIV_COMPLETE);
    assign busy = (div_state != DIV_IDLE);

endmodule
