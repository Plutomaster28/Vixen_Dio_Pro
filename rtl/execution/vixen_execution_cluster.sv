// =============================================================================
// Vixen Dio Pro Execution Cluster
// =============================================================================
// Contains all execution units: 2 ALUs, 1 AGU, 1 MUL, 1 DIV, 2 FPU pipelines
// Handles out-of-order execution with proper latency modeling
// =============================================================================

module vixen_execution_cluster (
    input  logic        clk,
    input  logic        rst_n,
    
    // Execution unit busy status
    output logic [2:0]  eu_alu_busy,      // ALU0, ALU1, AGU
    output logic        eu_mul_busy,
    output logic        eu_div_busy,
    output logic [1:0]  eu_fpu_busy,      // FPU0, FPU1
    
    // Issue interface from IQ
    input  logic [1:0]       alu_issue_valid,
    input  logic [128-1:0]   alu_issue_uop,      // [1:0][63:0] flattened to [128-1:0]
    input  logic [12-1:0]    alu_issue_rob_id,   // [1:0][5:0] flattened to [12-1:0]
    input  logic [4-1:0]     alu_issue_thread_id, // [1:0][1:0] flattened to [4-1:0]
    
    input  logic        agu_issue_valid,
    input  logic [63:0] agu_issue_uop,
    input  logic [5:0]  agu_issue_rob_id,
    input  logic [1:0]  agu_issue_thread_id,
    
    input  logic        mul_issue_valid,
    input  logic [63:0] mul_issue_uop,
    input  logic [5:0]  mul_issue_rob_id,
    input  logic [1:0]  mul_issue_thread_id,
    
    input  logic        div_issue_valid,
    input  logic [63:0] div_issue_uop,
    input  logic [5:0]  div_issue_rob_id,
    input  logic [1:0]  div_issue_thread_id,
    
    input  logic [1:0]       fpu_issue_valid,
    input  logic [128-1:0]   fpu_issue_uop,      // [1:0][63:0] flattened to [128-1:0]
    input  logic [12-1:0]    fpu_issue_rob_id,   // [1:0][5:0] flattened to [12-1:0]
    input  logic [4-1:0]     fpu_issue_thread_id, // [1:0][1:0] flattened to [4-1:0]
    
    // Completion interface to ROB
    output logic [2:0]       eu_complete,
    output logic [18-1:0]    eu_rob_id,          // [2:0][5:0] flattened to [18-1:0]
    output logic [192-1:0]   eu_result,          // [2:0][63:0] flattened to [192-1:0]
    
    // Wakeup interface to IQ
    output logic [2:0]       eu_wakeup_valid,
    output logic [24-1:0]    eu_wakeup_tag,      // [2:0][7:0] flattened to [24-1:0]
    
    // Memory interface (for AGU)
    output logic [63:0] mem_load_addr,
    output logic [63:0] mem_store_addr,
    input  logic [63:0] mem_load_data,
    output logic [63:0] mem_store_data,
    output logic        mem_load_req,
    output logic        mem_store_req,
    input  logic        mem_load_ack,
    input  logic        mem_store_ack,
    
    // Performance counters
    output logic [31:0] perf_alu_ops,
    output logic [31:0] perf_fpu_ops,
    output logic [31:0] perf_mem_ops
);

    // =========================================================================
    // ALU 0 - Integer ALU (1-cycle operations)
    // =========================================================================
    
    logic        alu0_valid;
    logic [63:0] alu0_result;
    logic [5:0]  alu0_rob_id;
    logic [1:0]  alu0_thread_id;
    logic        alu0_complete;
    
    vixen_alu #(.ALU_ID(0)) u_alu0 (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(alu_issue_valid[0]),
        .issue_uop(alu_issue_uop[63:0]),        // Flattened indexing [0*64 +: 64]
        .issue_rob_id(alu_issue_rob_id[5:0]),   // Flattened indexing [0*6 +: 6] 
        .issue_thread_id(alu_issue_thread_id[1:0]), // Flattened indexing [0*2 +: 2]
        .result(alu0_result),
        .rob_id_out(alu0_rob_id),
        .thread_id_out(alu0_thread_id),
        .complete(alu0_complete),
        .busy(eu_alu_busy[0])
    );
    
    // =========================================================================
    // ALU 1 - Integer ALU (1-cycle operations)
    // =========================================================================
    
    logic        alu1_valid;
    logic [63:0] alu1_result;
    logic [5:0]  alu1_rob_id;
    logic [1:0]  alu1_thread_id;
    logic        alu1_complete;
    
    vixen_alu #(.ALU_ID(1)) u_alu1 (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(alu_issue_valid[1]),
        .issue_uop(alu_issue_uop[127:64]),      // Flattened indexing [1*64 +: 64]
        .issue_rob_id(alu_issue_rob_id[11:6]),  // Flattened indexing [1*6 +: 6]
        .issue_thread_id(alu_issue_thread_id[3:2]), // Flattened indexing [1*2 +: 2]
        .result(alu1_result),
        .rob_id_out(alu1_rob_id),
        .thread_id_out(alu1_thread_id),
        .complete(alu1_complete),
        .busy(eu_alu_busy[1])
    );
    
    // =========================================================================
    // AGU - Address Generation Unit (1-cycle address calc + memory access)
    // =========================================================================
    
    logic        agu_valid;
    logic [63:0] agu_result;
    logic [5:0]  agu_rob_id;
    logic [1:0]  agu_thread_id;
    logic        agu_complete;
    
    vixen_agu u_agu (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(agu_issue_valid),
        .issue_uop(agu_issue_uop),
        .issue_rob_id(agu_issue_rob_id),
        .issue_thread_id(agu_issue_thread_id),
        .result(agu_result),
        .rob_id_out(agu_rob_id),
        .thread_id_out(agu_thread_id),
        .complete(agu_complete),
        .busy(eu_alu_busy[2]),
        .mem_load_addr(mem_load_addr),
        .mem_store_addr(mem_store_addr),
        .mem_load_data(mem_load_data),
        .mem_store_data(mem_store_data),
        .mem_load_req(mem_load_req),
        .mem_store_req(mem_store_req),
        .mem_load_ack(mem_load_ack),
        .mem_store_ack(mem_store_ack)
    );
    
    // =========================================================================
    // Multiplier Unit (3-4 cycle latency)
    // =========================================================================
    
    logic        mul_valid;
    logic [63:0] mul_result;
    logic [5:0]  mul_rob_id;
    logic [1:0]  mul_thread_id;
    logic        mul_complete;
    
    vixen_multiplier u_multiplier (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(mul_issue_valid),
        .issue_uop(mul_issue_uop),
        .issue_rob_id(mul_issue_rob_id),
        .issue_thread_id(mul_issue_thread_id),
        .result(mul_result),
        .rob_id_out(mul_rob_id),
        .thread_id_out(mul_thread_id),
        .complete(mul_complete),
        .busy(eu_mul_busy)
    );
    
    // =========================================================================
    // Divider Unit (10-20 cycle iterative)
    // =========================================================================
    
    logic        div_valid;
    logic [63:0] div_result;
    logic [5:0]  div_rob_id;
    logic [1:0]  div_thread_id;
    logic        div_complete;
    
    vixen_divider u_divider (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(div_issue_valid),
        .issue_uop(div_issue_uop),
        .issue_rob_id(div_issue_rob_id),
        .issue_thread_id(div_issue_thread_id),
        .result(div_result),
        .rob_id_out(div_rob_id),
        .thread_id_out(div_thread_id),
        .complete(div_complete),
        .busy(eu_div_busy)
    );
    
    // =========================================================================
    // FPU 0 - Floating Point Unit (1-2 cycle latency)
    // =========================================================================
    
    logic        fpu0_valid;
    logic [63:0] fpu0_result;
    logic [5:0]  fpu0_rob_id;
    logic [1:0]  fpu0_thread_id;
    logic        fpu0_complete;
    
    vixen_fpu #(.FPU_ID(0)) u_fpu0 (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(fpu_issue_valid[0]),
        .issue_uop(fpu_issue_uop[0]),
        .issue_rob_id(fpu_issue_rob_id[0]),
        .issue_thread_id(fpu_issue_thread_id[0]),
        .result(fpu0_result),
        .rob_id_out(fpu0_rob_id),
        .thread_id_out(fpu0_thread_id),
        .complete(fpu0_complete),
        .busy(eu_fpu_busy[0])
    );
    
    // =========================================================================
    // FPU 1 - Floating Point Unit (1-2 cycle latency)
    // =========================================================================
    
    logic        fpu1_valid;
    logic [63:0] fpu1_result;
    logic [5:0]  fpu1_rob_id;
    logic [1:0]  fpu1_thread_id;
    logic        fpu1_complete;
    
    vixen_fpu #(.FPU_ID(1)) u_fpu1 (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(fpu_issue_valid[1]),
        .issue_uop(fpu_issue_uop[1]),
        .issue_rob_id(fpu_issue_rob_id[1]),
        .issue_thread_id(fpu_issue_thread_id[1]),
        .result(fpu1_result),
        .rob_id_out(fpu1_rob_id),
        .thread_id_out(fpu1_thread_id),
        .complete(fpu1_complete),
        .busy(eu_fpu_busy[1])
    );
    
    // =========================================================================
    // Result Arbitration and Forwarding
    // =========================================================================
    
    // Round-robin result selection (up to 3 completions per cycle)
    logic [2:0] completion_valid;
    logic [192-1:0] completion_results_flat;    // [2:0][63:0] flattened to [192-1:0]
    logic [18-1:0] completion_rob_ids_flat;     // [2:0][5:0] flattened to [18-1:0]
    logic [6-1:0] completion_thread_ids_flat;   // [2:0][1:0] flattened to [6-1:0]
    logic [2:0] completion_count;
    
    // Collect completion signals
    always_comb begin
        completion_valid = 3'b0;
        completion_results_flat = 192'b0;  // Initialize flattened array
        completion_rob_ids_flat = 18'b0;   // Initialize flattened array
        completion_thread_ids_flat = 6'b0; // Initialize flattened array
        
        completion_count = 3'b0;
        
        // ALU0 completion
        if (alu0_complete && completion_count < 3) begin
            completion_valid[completion_count] = 1'b1;
            completion_results_flat[completion_count*64 +: 64] = alu0_result;  // Flattened indexing
            completion_rob_ids_flat[completion_count*6 +: 6] = alu0_rob_id;    // Flattened indexing
            completion_thread_ids_flat[completion_count*2 +: 2] = alu0_thread_id; // Flattened indexing
            completion_count++;
        end
        
        // ALU1 completion
        if (alu1_complete && completion_count < 3) begin
            completion_valid[completion_count] = 1'b1;
            completion_results_flat[completion_count*64 +: 64] = alu1_result;  // Flattened indexing
            completion_rob_ids_flat[completion_count*6 +: 6] = alu1_rob_id;    // Flattened indexing
            completion_thread_ids_flat[completion_count*2 +: 2] = alu1_thread_id; // Flattened indexing
            completion_count++;
        end
        
        // AGU completion
        if (agu_complete && completion_count < 3) begin
            completion_valid[completion_count] = 1'b1;
            completion_results_flat[completion_count*64 +: 64] = agu_result;   // Flattened indexing
            completion_rob_ids_flat[completion_count*6 +: 6] = agu_rob_id;     // Flattened indexing
            completion_thread_ids_flat[completion_count*2 +: 2] = agu_thread_id; // Flattened indexing
            completion_count++;
        end
        
        // MUL completion (if space available)
        if (mul_complete && completion_count < 3) begin
            completion_valid[completion_count] = 1'b1;
            completion_results_flat[completion_count*64 +: 64] = mul_result;   // Flattened indexing
            completion_rob_ids_flat[completion_count*6 +: 6] = mul_rob_id;     // Flattened indexing
            completion_thread_ids_flat[completion_count*2 +: 2] = mul_thread_id; // Flattened indexing
            completion_count++;
        end
        
        // DIV completion (if space available)
        if (div_complete && completion_count < 3) begin
            completion_valid[completion_count] = 1'b1;
            completion_results_flat[completion_count*64 +: 64] = div_result;   // Flattened indexing
            completion_rob_ids_flat[completion_count*6 +: 6] = div_rob_id;     // Flattened indexing
            completion_thread_ids_flat[completion_count*2 +: 2] = div_thread_id; // Flattened indexing
            completion_count++;
        end
        
        // FPU0 completion (if space available)
        if (fpu0_complete && completion_count < 3) begin
            completion_valid[completion_count] = 1'b1;
            completion_results_flat[completion_count*64 +: 64] = fpu0_result;  // Flattened indexing
            completion_rob_ids_flat[completion_count*6 +: 6] = fpu0_rob_id;    // Flattened indexing
            completion_thread_ids_flat[completion_count*2 +: 2] = fpu0_thread_id; // Flattened indexing
            completion_count++;
        end
        
        // FPU1 completion (if space available)
        if (fpu1_complete && completion_count < 3) begin
            completion_valid[completion_count] = 1'b1;
            completion_results_flat[completion_count*64 +: 64] = fpu1_result;  // Flattened indexing
            completion_rob_ids_flat[completion_count*6 +: 6] = fpu1_rob_id;    // Flattened indexing
            completion_thread_ids_flat[completion_count*2 +: 2] = fpu1_thread_id; // Flattened indexing
            completion_count++;
        end
    end
    
    // Output completion signals
    assign eu_complete = completion_valid;
    assign eu_rob_id = completion_rob_ids_flat;     // Use flattened array
    assign eu_result = completion_results_flat;     // Use flattened array
    
    // Generate wakeup signals (same as completion for simplicity)
    assign eu_wakeup_valid = completion_valid;
    assign eu_wakeup_tag = {2'b0, completion_rob_ids_flat[17:12],  // ROB ID 2 with padding
                           2'b0, completion_rob_ids_flat[11:6],   // ROB ID 1 with padding  
                           2'b0, completion_rob_ids_flat[5:0]};   // ROB ID 0 with padding
    
    // =========================================================================
    // Performance Counters
    // =========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_alu_ops <= 32'b0;
            perf_fpu_ops <= 32'b0;
            perf_mem_ops <= 32'b0;
        end else begin
            // Count ALU operations
            if (alu0_complete || alu1_complete) begin
                perf_alu_ops <= perf_alu_ops + (alu0_complete ? 1 : 0) + (alu1_complete ? 1 : 0);
            end
            
            // Count FPU operations
            if (fpu0_complete || fpu1_complete) begin
                perf_fpu_ops <= perf_fpu_ops + (fpu0_complete ? 1 : 0) + (fpu1_complete ? 1 : 0);
            end
            
            // Count memory operations
            if (agu_complete) begin
                perf_mem_ops <= perf_mem_ops + 1;
            end
        end
    end

endmodule

// =============================================================================
// ALU - Arithmetic Logic Unit
// =============================================================================

module vixen_alu #(
    parameter int ALU_ID = 0
) (
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

    // ALU operation decode
    logic [3:0]  alu_op;
    logic [63:0] operand_a, operand_b;
    logic [63:0] alu_result;
    
    // Pipeline register
    logic        pipe_valid;
    logic [5:0]  pipe_rob_id;
    logic [1:0]  pipe_thread_id;
    
    assign alu_op = issue_uop[3:0];
    assign operand_a = issue_uop[31:16];  // Simplified operand extraction
    assign operand_b = issue_uop[47:32];
    
    // ALU operations (1-cycle latency)
    always_comb begin
        case (alu_op)
            4'b0001: alu_result = operand_a + operand_b;      // ADD
            4'b0010: alu_result = operand_a - operand_b;      // SUB
            4'b0011: alu_result = operand_a & operand_b;      // AND
            4'b0100: alu_result = operand_a | operand_b;      // OR
            4'b0101: alu_result = operand_a ^ operand_b;      // XOR
            4'b0110: alu_result = operand_a << operand_b[5:0]; // SHL
            4'b0111: alu_result = operand_a >> operand_b[5:0]; // SHR
            4'b1000: alu_result = operand_b;                   // MOV
            default: alu_result = 64'b0;                       // NOP
        endcase
    end
    
    // Pipeline stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid <= 1'b0;
            pipe_rob_id <= 6'b0;
            pipe_thread_id <= 2'b0;
            result <= 64'b0;
        end else begin
            pipe_valid <= issue_valid;
            pipe_rob_id <= issue_rob_id;
            pipe_thread_id <= issue_thread_id;
            result <= alu_result;
        end
    end
    
    assign complete = pipe_valid;
    assign rob_id_out = pipe_rob_id;
    assign thread_id_out = pipe_thread_id;
    assign busy = issue_valid; // 1-cycle busy

endmodule
