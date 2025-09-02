// =============================================================================
// Vixen Dio Pro Frontend - Fetch and Decode Pipeline
// =============================================================================
// Handles instruction fetch, preliminary decode, and micro-op generation
// Supports both threads in SMT configuration
// =============================================================================

module vixen_frontend (
    input  logic        clk,
    input  logic        rst_n,
    
    // Thread Program Counters
    input  logic [63:0] pc_t0,
    input  logic [63:0] pc_t1,
    input  logic [1:0]  thread_active,
    
    // Branch Prediction Interface
    input  logic [63:0] bp_target,
    input  logic        bp_taken,
    input  logic        bp_valid,
    
    // L1 I-Cache Interface
    output logic [63:0] l1i_addr,
    input  logic [511:0] l1i_data,
    input  logic        l1i_hit,
    
    // Fetch Output
    output logic [127:0] fetch_bundle,    // Up to 4x32-bit instructions
    output logic        fetch_valid,
    output logic [1:0]  fetch_thread_id,
    
    // Decode Output (up to 3 micro-ops per cycle)
    output logic [191:0] decoded_uops,        // 3 * 64 bits
    output logic [2:0]   decoded_valid,
    output logic [5:0]   decoded_thread_id    // 3 * 2 bits
);

    // =========================================================================
    // Fetch Stage - Pipeline Stage 1-4
    // =========================================================================
    
    // Thread arbitration for fetch
    logic        fetch_thread_sel;
    logic [63:0] fetch_pc;
    logic        fetch_req;
    
    // Pipeline registers for fetch stages
    logic [511:0] fetch_pipe_bundle;      // [3:0][127:0] flattened to [511:0]
    logic [3:0]   fetch_pipe_valid;
    logic [7:0]   fetch_pipe_thread_id;   // [3:0][1:0] flattened to [7:0]
    logic [255:0] fetch_pipe_pc;          // [3:0][63:0] flattened to [255:0]
    
    // Simple round-robin thread selection for fetch
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_thread_sel <= 1'b0;
        end else if (fetch_req) begin
            fetch_thread_sel <= ~fetch_thread_sel;
        end
    end
    
    // Select PC based on thread and branch prediction
    always_comb begin
        fetch_req = 1'b0;
        fetch_pc = 64'b0;
        
        if (bp_valid && bp_taken) begin
            fetch_pc = bp_target;
            fetch_req = 1'b1;
        end else if (thread_active[fetch_thread_sel]) begin
            fetch_pc = fetch_thread_sel ? pc_t1 : pc_t0;
            fetch_req = 1'b1;
        end else if (thread_active[~fetch_thread_sel]) begin
            fetch_pc = fetch_thread_sel ? pc_t0 : pc_t1;
            fetch_req = 1'b1;
        end
    end
    
    assign l1i_addr = fetch_pc;
    
    // Fetch pipeline stages (4 stages total)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_pipe_valid <= 4'b0;
            fetch_pipe_bundle <= 512'd0;
            fetch_pipe_thread_id <= 8'd0;
            fetch_pipe_pc <= 256'd0;
        end else begin
            // Stage 1: Address generation and cache access
            fetch_pipe_valid[0] <= fetch_req;
            fetch_pipe_thread_id[1:0] <= {1'b0, fetch_thread_sel};
            fetch_pipe_pc[63:0] <= fetch_pc;
            
            // Stage 2: Cache data return
            fetch_pipe_valid[1] <= fetch_pipe_valid[0] && l1i_hit;
            fetch_pipe_bundle[127 +: 128] <= l1i_data[127:0]; // Take first 128 bits
            fetch_pipe_thread_id[3:2] <= fetch_pipe_thread_id[1:0];
            fetch_pipe_pc[127:64] <= fetch_pipe_pc[63:0];
            
            // Stage 3: Instruction alignment
            fetch_pipe_valid[2] <= fetch_pipe_valid[1];
            fetch_pipe_bundle[255:128] <= fetch_pipe_bundle[127:0];
            fetch_pipe_thread_id[5:4] <= fetch_pipe_thread_id[3:2];
            fetch_pipe_pc[191:128] <= fetch_pipe_pc[127:64];
            
            // Stage 4: Pre-decode
            fetch_pipe_valid[3] <= fetch_pipe_valid[2];
            fetch_pipe_bundle[383:256] <= fetch_pipe_bundle[255:128];
            fetch_pipe_thread_id[7:6] <= fetch_pipe_thread_id[5:4];
            fetch_pipe_pc[255:192] <= fetch_pipe_pc[191:128];
        end
    end
    
    // Output fetch results
    assign fetch_bundle = fetch_pipe_bundle[383:256];
    assign fetch_valid = fetch_pipe_valid[3];
    assign fetch_thread_id = fetch_pipe_thread_id[7:6];
    
    // =========================================================================
    // Instruction Length Decoder - Pipeline Stage 5-8
    // =========================================================================
    
    // x86 instruction length decoder (simplified)
    logic [31:0]  inst_lengths;      // [3:0][7:0] flattened to [31:0]
    logic [3:0]   inst_valid;        // Valid instruction flags  
    logic [127:0] inst_raw;          // [3:0][31:0] flattened to [127:0]
    
    // Pipeline registers for length decode
    logic [127:0] length_pipe_lengths;    // [3:0][3:0][7:0] flattened to [127:0]
    logic [15:0]  length_pipe_valid;      // [3:0][3:0] flattened to [15:0] 
    logic [511:0] length_pipe_raw;        // [3:0][3:0][31:0] flattened to [511:0]
    logic [7:0]   length_pipe_thread_id;  // [3:0][1:0] flattened to [7:0]
    logic [3:0]   length_pipe_bundle_valid;
    
    // Simplified x86 length decoder
    logic [7:0] opcode_temp;
    always_comb begin
        inst_lengths = 32'd0;  // Initialize all to 0
        inst_valid = 4'b0;
        inst_raw = 128'd0;     // Initialize to 0
        opcode_temp = 8'h0;    // Default value to avoid latch
        
        if (fetch_valid) begin
            // Parse up to 4 instructions from 128-bit bundle
            for (int i = 0; i < 4; i++) begin
                opcode_temp = fetch_bundle[i*32 +: 8];
                
                // Simplified length calculation based on opcode
                case (opcode_temp)
                    8'h0F: inst_lengths[i*8 +: 8] = 8'd2;      // Two-byte opcodes
                    8'h66, 8'h67: inst_lengths[i*8 +: 8] = 8'd2; // Prefixes
                    8'hF0, 8'hF2, 8'hF3: inst_lengths[i*8 +: 8] = 8'd2; // Lock/rep prefixes
                    default: begin
                        if (opcode_temp[7:4] == 4'h4) // REX prefix
                            inst_lengths[i*8 +: 8] = 8'd2;
                        else
                            inst_lengths[i*8 +: 8] = 8'd1;
                    end
                endcase
                
                inst_valid[i] = 1'b1;
                inst_raw[i*32 +: 32] = fetch_bundle[i*32 +: 32];
            end
        end
    end
    
    // Length decode pipeline (4 stages)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            length_pipe_valid <= 16'd0;
            length_pipe_lengths <= 128'd0;
            length_pipe_raw <= 512'd0;
            length_pipe_thread_id <= 8'd0;
            length_pipe_bundle_valid <= 4'b0;
        end else begin
            // Stage 1: Initial length decode
            length_pipe_valid[3:0] <= inst_valid;
            length_pipe_lengths[31:0] <= inst_lengths;
            length_pipe_raw[127:0] <= inst_raw;
            length_pipe_thread_id[1:0] <= fetch_thread_id;
            length_pipe_bundle_valid[0] <= fetch_valid;
            
            // Stages 2-4: Pipeline the results
            for (int i = 1; i < 4; i++) begin
                length_pipe_valid[i*4 +: 4] <= length_pipe_valid[(i-1)*4 +: 4];
                length_pipe_lengths[i*32 +: 32] <= length_pipe_lengths[(i-1)*32 +: 32];
                length_pipe_raw[i*128 +: 128] <= length_pipe_raw[(i-1)*128 +: 128];
                length_pipe_thread_id[i*2 +: 2] <= length_pipe_thread_id[(i-1)*2 +: 2];
                length_pipe_bundle_valid[i] <= length_pipe_bundle_valid[i-1];
            end
        end
    end
    
    // =========================================================================
    // Instruction Decoder - Pipeline Stage 9-12
    // =========================================================================
    
    // Decoded micro-operation structure
    typedef struct packed {
        logic [7:0]  opcode;          // x86 opcode
        logic [2:0]  rm;              // Register/memory field
        logic [2:0]  reg_field;       // Register field (renamed from 'reg')
        logic [1:0]  mod;             // Addressing mode
        logic [3:0]  src1_reg;        // Source register 1
        logic [3:0]  src2_reg;        // Source register 2
        logic [3:0]  dst_reg;         // Destination register
        logic [31:0] immediate;       // Immediate value
        logic [3:0]  uop_type;        // Micro-op type
        logic [1:0]  exec_unit;       // Target execution unit
        logic        has_immediate;   // Has immediate operand
        logic        is_branch;       // Is branch instruction
        logic        is_memory;       // Is memory operation
        logic        is_fp;           // Is floating-point operation
    } decoded_uop_t;
    
    // Decoding logic
    logic [2:0] num_uops;
    decoded_uop_t [2:0] uops;
    
    // Pipeline registers for decode
    logic [767:0] decode_pipe_uops;      // [3:0][2:0][63:0] flattened to [767:0]
    logic [11:0]  decode_pipe_valid;     // [3:0][2:0] flattened to [11:0]
    logic [23:0]  decode_pipe_thread_id; // [3:0][2:0][1:0] flattened to [23:0]
    
    // Instruction decoder (simplified for x86-64)
    logic [31:0] inst_temp;
    logic [7:0] opcode_decode;
    decoded_uop_t uop_temp;
    
    always_comb begin
        num_uops = 3'd0;
        uops[0] = '0;
        uops[1] = '0;
        uops[2] = '0;
        inst_temp = 32'h0;
        opcode_decode = 8'h0;
        uop_temp = '0;
        
        if (length_pipe_bundle_valid[3]) begin
            // Process up to 3 instructions, checking if we have room for more uops
            if (length_pipe_valid[3*4 + 0]) begin
                inst_temp = length_pipe_raw[3*128 + 0*32 +: 32];
                opcode_decode = inst_temp[7:0];
                
                // Decode instruction into micro-ops (always use uops[0] for first instruction)
                case (opcode_decode)
                        8'h01: begin // ADD
                            uop_temp.opcode = opcode_decode;
                            uop_temp.uop_type = 4'b0001; // ALU
                            uop_temp.exec_unit = 2'b00;  // ALU0
                            uop_temp.dst_reg = inst_temp[11:8];
                            uop_temp.src1_reg = inst_temp[15:12];
                            uop_temp.src2_reg = inst_temp[19:16];
                            uops[0] = uop_temp;
                            num_uops = 3'd1;
                        end
                        
                        8'h89: begin // MOV reg/mem, reg
                            uop_temp.opcode = opcode_decode;
                            uop_temp.uop_type = 4'b0010; // Move
                            uop_temp.exec_unit = 2'b00;  // ALU0
                            uop_temp.dst_reg = inst_temp[11:8];
                            uop_temp.src1_reg = inst_temp[15:12];
                            uops[0] = uop_temp;
                            num_uops = 3'd1;
                        end
                        
                        8'hC7: begin // MOV reg/mem, imm32
                            uop_temp.opcode = opcode_decode;
                            uop_temp.uop_type = 4'b0010; // Move
                            uop_temp.exec_unit = 2'b00;  // ALU0
                            uop_temp.dst_reg = inst_temp[11:8];
                            uop_temp.immediate = inst_temp[31:8];
                            uop_temp.has_immediate = 1'b1;
                            uops[0] = uop_temp;
                            num_uops = 3'd1;
                        end
                        
                        8'h8B: begin // MOV reg, reg/mem
                            uop_temp.opcode = opcode_decode;
                            uop_temp.uop_type = 4'b0011; // Load
                            uop_temp.exec_unit = 2'b10;  // AGU
                            uop_temp.is_memory = 1'b1;
                            uop_temp.dst_reg = inst_temp[15:12];
                            uop_temp.src1_reg = inst_temp[11:8];
                            uops[0] = uop_temp;
                            num_uops = 3'd1;
                        end
                        
                        8'hEB, 8'hE9: begin // JMP
                            uop_temp.opcode = opcode_decode;
                            uop_temp.uop_type = 4'b0100; // Branch
                            uop_temp.exec_unit = 2'b00;  // ALU0
                            uop_temp.is_branch = 1'b1;
                            uop_temp.immediate = inst_temp[31:8];
                            uop_temp.has_immediate = 1'b1;
                            uops[0] = uop_temp;
                            num_uops = 3'd1;
                        end
                        
                        default: begin
                            // NOP or unknown instruction
                            uop_temp.opcode = 8'h90; // NOP
                            uop_temp.uop_type = 4'b0000;
                            uops[0] = uop_temp;
                            num_uops = 3'd1;
                        end
                    endcase
                end
        end
    end
    
    // Decode pipeline (4 stages)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decode_pipe_uops <= 768'd0;
            decode_pipe_valid <= 12'd0;
            decode_pipe_thread_id <= 24'd0;
        end else begin
            // Stage 1: Complex decode
            decode_pipe_valid[2:0] <= '0;
            for (int i = 0; i < 3; i++) begin
                if (i < num_uops) begin
                    decode_pipe_uops[i*64 +: 64] <= uops[i];
                    decode_pipe_valid[i] <= 1'b1;
                    decode_pipe_thread_id[i*2 +: 2] <= length_pipe_thread_id[7:6]; // Thread ID from stage 3
                end
            end
            
            // Stages 2-4: Pipeline the decoded micro-ops
            for (int stage = 1; stage < 4; stage++) begin
                decode_pipe_uops[stage*192 +: 192] <= decode_pipe_uops[(stage-1)*192 +: 192];
                decode_pipe_valid[stage*3 +: 3] <= decode_pipe_valid[(stage-1)*3 +: 3];
                decode_pipe_thread_id[stage*6 +: 6] <= decode_pipe_thread_id[(stage-1)*6 +: 6];
            end
        end
    end
    
    // Output decoded micro-ops
    assign decoded_uops = decode_pipe_uops[3*192 +: 192];
    assign decoded_valid = decode_pipe_valid[3*3 +: 3];
    assign decoded_thread_id = decode_pipe_thread_id[3*6 +: 6];

endmodule
