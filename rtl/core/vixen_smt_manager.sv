// =============================================================================
// Vixen Dio Pro SMT (Simultaneous Multi-Threading) Manager
// =============================================================================
// Manages two hardware threads with per-thread state and resource arbitration
// Similar to Pentium 4's Hyper-Threading technology
// =============================================================================

module vixen_smt_manager #(
    parameter int NUM_THREADS = 2,
    parameter int NUM_ARCH_REGS = 16,
    parameter int ROB_ENTRIES = 48
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Thread control
    output logic [1:0]  thread_active,
    input  logic [1:0]  thread_stalled,
    
    // Program counters (per thread)
    output logic [63:0] pc_t0,
    output logic [63:0] pc_t1,
    input  logic [63:0] pc_update_t0,
    input  logic [63:0] pc_update_t1,
    input  logic        pc_update_valid_t0,
    input  logic        pc_update_valid_t1,
    
    // ROB management
    input  logic [5:0]  rob_head,
    input  logic [5:0]  rob_tail,
    input  logic [ROB_ENTRIES-1:0] rob_valid,
    
    // Resource allocation fairness
    output logic [31:0] thread_priority_0,        // Thread 0 priority
    output logic [31:0] thread_priority_1,        // Thread 1 priority
    output logic [1:0]  preferred_thread,
    
    // Exception and interrupt handling
    input  logic [1:0]  thread_exception,
    input  logic [7:0]  exception_vector_t0,
    input  logic [7:0]  exception_vector_t1,
    output logic        thread_flush_t0,
    output logic        thread_flush_t1,
    
    // Context switching control
    input  logic        context_switch_req,
    input  logic [1:0]  context_switch_thread,
    output logic        context_switch_ack,
    
    // Performance monitoring
    output logic [31:0] perf_thread_cycles_0,       // Thread 0 cycles
    output logic [31:0] perf_thread_cycles_1,       // Thread 1 cycles
    output logic [31:0] perf_thread_instructions_0, // Thread 0 instructions
    output logic [31:0] perf_thread_instructions_1, // Thread 1 instructions
    output logic [31:0] perf_context_switches,
    output logic [31:0] perf_resource_conflicts
);

    // =========================================================================
    // Internal Arrays (for logic convenience)
    // =========================================================================
    logic [31:0] thread_priority_int [NUM_THREADS];
    logic [31:0] perf_thread_cycles_int [NUM_THREADS];
    logic [31:0] perf_thread_instructions_int [NUM_THREADS];

    // =========================================================================
    // Per-Thread Architectural State
    // =========================================================================
    
    typedef struct packed {
        logic        active;              // Thread is active
        logic        halted;              // Thread is halted
        logic        privileged;          // Privilege level
        logic [63:0] pc;                  // Program counter
        logic [63:0] stack_pointer;       // Stack pointer
        logic [31:0] flags;               // Processor flags
        logic [63:0] cr3;                 // Page table base (for MMU)
        logic [95:0] segment_regs;        // Segment registers (CS, DS, ES, FS, GS, SS) - packed as 6x16 bits
        logic [63:0] gdt_base;            // Global descriptor table base
        logic [63:0] idt_base;            // Interrupt descriptor table base
        logic [7:0]  exception_pending;   // Pending exception vector
        logic        exception_valid;     // Exception is pending
        logic [31:0] cycle_count;         // Cycles this thread has been active
        logic [31:0] instruction_count;   // Instructions retired by this thread
    } thread_context_t;
    
    thread_context_t [NUM_THREADS-1:0] thread_contexts;
    
    // =========================================================================
    // Resource Arbitration and Fairness
    // =========================================================================
    
    // Thread scheduling policy
    typedef enum logic [1:0] {
        SCHED_ROUND_ROBIN,
        SCHED_PRIORITY,
        SCHED_FAIR_SHARE,
        SCHED_ADAPTIVE
    } sched_policy_t;
    
    sched_policy_t current_policy;
    
    // Resource usage tracking
    logic [31:0] resource_usage [NUM_THREADS];
    logic [31:0] issue_queue_usage [NUM_THREADS];
    logic [31:0] rob_usage [NUM_THREADS];
    logic [31:0] cache_usage [NUM_THREADS];
    
    // Fairness metrics
    logic [31:0] fairness_deficit [NUM_THREADS];
    logic [31:0] total_resource_cycles;
    
    // Thread priority calculation
    always_comb begin
        // Manual unroll for NUM_THREADS = 2
        // Thread 0 priority
        case (current_policy)
            SCHED_ROUND_ROBIN: begin
                thread_priority_int[0] = 32'd50; // Equal priority
            end
            
            SCHED_PRIORITY: begin
                thread_priority_int[0] = thread_contexts[0].privileged ? 32'd100 : 32'd25;
            end
            
            SCHED_FAIR_SHARE: begin
                // Higher priority for thread with less recent resource usage
                thread_priority_int[0] = 32'd100 - resource_usage[0][7:0];
            end
            
            SCHED_ADAPTIVE: begin
                // Adaptive based on stall conditions and resource availability
                if (thread_stalled[0]) begin
                    thread_priority_int[0] = 32'd10; // Low priority if stalled
                end else if (fairness_deficit[0] > 32'd1000) begin
                    thread_priority_int[0] = 32'd100; // High priority if starved
                end else begin
                    thread_priority_int[0] = 32'd50 + fairness_deficit[0][5:0];
                end
            end
        endcase
        
        // Thread 1 priority
        case (current_policy)
            SCHED_ROUND_ROBIN: begin
                thread_priority_int[1] = 32'd50; // Equal priority
            end
            
            SCHED_PRIORITY: begin
                thread_priority_int[1] = thread_contexts[1].privileged ? 32'd100 : 32'd25;
            end
            
            SCHED_FAIR_SHARE: begin
                // Higher priority for thread with less recent resource usage
                thread_priority_int[1] = 32'd100 - resource_usage[1][7:0];
            end
            
            SCHED_ADAPTIVE: begin
                // Adaptive based on stall conditions and resource availability
                if (thread_stalled[1]) begin
                    thread_priority_int[1] = 32'd10; // Low priority if stalled
                end else if (fairness_deficit[1] > 32'd1000) begin
                    thread_priority_int[1] = 32'd100; // High priority if starved
                end else begin
                    thread_priority_int[1] = 32'd50 + fairness_deficit[1][5:0];
                end
            end
        endcase
    end
    
    // Preferred thread selection
    always_comb begin
        if (thread_priority_int[0] > thread_priority_int[1]) begin
            preferred_thread = 2'b00;
        end else if (thread_priority_int[1] > thread_priority_int[0]) begin
            preferred_thread = 2'b01;
        end else begin
            // Equal priority - use round robin
            preferred_thread = perf_context_switches[0] ? 2'b01 : 2'b00;
        end
    end
    
    // =========================================================================
    // Context Switching Logic
    // =========================================================================
    
    typedef enum logic [2:0] {
        CTX_IDLE,
        CTX_SAVE_REQUEST,
        CTX_SAVE_WAIT,
        CTX_LOAD_REQUEST,
        CTX_LOAD_WAIT,
        CTX_COMPLETE
    } context_state_t;
    
    context_state_t context_state;
    logic [1:0] switching_thread;
    logic [7:0] context_save_cycles;
    
    // =========================================================================
    // Exception Handling
    // =========================================================================
    
    logic [1:0] exception_thread;
    logic       exception_active;
    
    always_comb begin
        exception_thread = 2'b00;
        exception_active = 1'b0;
        
        // Priority: Thread 0 exceptions first
        if (thread_exception[0]) begin
            exception_thread = 2'b00;
            exception_active = 1'b1;
        end else if (thread_exception[1]) begin
            exception_thread = 2'b01;
            exception_active = 1'b1;
        end
    end
    
    // =========================================================================
    // Main SMT Control Logic
    // =========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize thread contexts - manual unroll for NUM_THREADS = 2
            // Thread 0
            thread_contexts[0] <= '0;
            thread_contexts[0].active <= 1'b1; // Start with thread 0 active
            thread_contexts[0].pc <= 64'hFFFFFFF0; // Reset vector
            resource_usage[0] <= 32'b0;
            issue_queue_usage[0] <= 32'b0;
            rob_usage[0] <= 32'b0;
            cache_usage[0] <= 32'b0;
            fairness_deficit[0] <= 32'b0;
            
            // Thread 1
            thread_contexts[1] <= '0;
            thread_contexts[1].active <= 1'b0; // Start with thread 1 inactive
            thread_contexts[1].pc <= 64'hFFFFFFF0; // Reset vector
            resource_usage[1] <= 32'b0;
            issue_queue_usage[1] <= 32'b0;
            rob_usage[1] <= 32'b0;
            cache_usage[1] <= 32'b0;
            fairness_deficit[1] <= 32'b0;
            
            current_policy <= SCHED_ADAPTIVE;
            context_state <= CTX_IDLE;
            switching_thread <= 2'b0;
            context_save_cycles <= 8'b0;
            total_resource_cycles <= 32'b0;
            perf_context_switches <= 32'b0;
            perf_resource_conflicts <= 32'b0;
        end else begin
            
            // =============================================
            // Program Counter Updates
            // =============================================
            
            if (pc_update_valid_t0) begin
                thread_contexts[0].pc <= pc_update_t0;
            end
            
            if (pc_update_valid_t1) begin
                thread_contexts[1].pc <= pc_update_t1;
            end
            
            // =============================================
            // Resource Usage Tracking
            // =============================================
            
            total_resource_cycles <= total_resource_cycles + 1;
            
            // Manual unroll for NUM_THREADS = 2
            // Thread 0 resource tracking
            if (thread_contexts[0].active && !thread_stalled[0]) begin
                thread_contexts[0].cycle_count <= thread_contexts[0].cycle_count + 1;
                resource_usage[0] <= resource_usage[0] + 1;
                
                // Decay thread 1's resource usage
                if (resource_usage[1] > 0) begin
                    resource_usage[1] <= resource_usage[1] - 1;
                end
            end
            
            // Thread 1 resource tracking
            if (thread_contexts[1].active && !thread_stalled[1]) begin
                thread_contexts[1].cycle_count <= thread_contexts[1].cycle_count + 1;
                resource_usage[1] <= resource_usage[1] + 1;
                
                // Decay thread 0's resource usage
                if (resource_usage[0] > 0) begin
                    resource_usage[0] <= resource_usage[0] - 1;
                end
            end
            
            // =============================================
            // Fairness Deficit Tracking
            // =============================================
            
            // Manual unroll for NUM_THREADS = 2
            // Thread 0 fairness tracking
            if (thread_contexts[0].active) begin
                if (preferred_thread != 2'd0 && !thread_stalled[0]) begin
                    // Thread should run but isn't preferred - increase deficit
                    fairness_deficit[0] <= fairness_deficit[0] + 1;
                end else if (preferred_thread == 2'd0) begin
                    // Thread is running - decrease deficit
                    if (fairness_deficit[0] > 32'd10) begin
                        fairness_deficit[0] <= fairness_deficit[0] - 10;
                    end else begin
                        fairness_deficit[0] <= 32'b0;
                    end
                end
            end
            
            // Thread 1 fairness tracking
            if (thread_contexts[1].active) begin
                if (preferred_thread != 2'd1 && !thread_stalled[1]) begin
                    // Thread should run but isn't preferred - increase deficit
                    fairness_deficit[1] <= fairness_deficit[1] + 1;
                end else if (preferred_thread == 2'd1) begin
                    // Thread is running - decrease deficit
                    if (fairness_deficit[1] > 32'd10) begin
                        fairness_deficit[1] <= fairness_deficit[1] - 10;
                    end else begin
                        fairness_deficit[1] <= 32'b0;
                    end
                end
            end
            
            // =============================================
            // Exception Handling
            // =============================================
            
            if (exception_active) begin
                // Use case statement to avoid dynamic indexing
                case (exception_thread)
                    2'b00: begin
                        thread_contexts[0].exception_pending <= exception_vector_t0;
                        thread_contexts[0].exception_valid <= 1'b1;
                        thread_contexts[0].active <= 1'b0;
                        thread_contexts[0].halted <= 1'b1;
                    end
                    2'b01: begin
                        thread_contexts[1].exception_pending <= exception_vector_t1;
                        thread_contexts[1].exception_valid <= 1'b1;
                        thread_contexts[1].active <= 1'b0;
                        thread_contexts[1].halted <= 1'b1;
                    end
                endcase
            end
            
            // Clear exception flags after one cycle
            if (thread_contexts[0].exception_valid) begin
                thread_contexts[0].exception_valid <= 1'b0;
            end
            if (thread_contexts[1].exception_valid) begin
                thread_contexts[1].exception_valid <= 1'b0;
            end
            
            // =============================================
            // Context Switching State Machine
            // =============================================
            
            case (context_state)
                CTX_IDLE: begin
                    if (context_switch_req) begin
                        switching_thread <= context_switch_thread;
                        context_save_cycles <= 8'd0;
                        context_state <= CTX_SAVE_REQUEST;
                        perf_context_switches <= perf_context_switches + 1;
                    end
                end
                
                CTX_SAVE_REQUEST: begin
                    // Deactivate the thread - use case statement
                    case (switching_thread)
                        2'b00: thread_contexts[0].active <= 1'b0;
                        2'b01: thread_contexts[1].active <= 1'b0;
                    endcase
                    context_state <= CTX_SAVE_WAIT;
                end
                
                CTX_SAVE_WAIT: begin
                    context_save_cycles <= context_save_cycles + 1;
                    
                    // Wait a few cycles for pipeline to drain
                    if (context_save_cycles >= 8'd5) begin
                        context_state <= CTX_LOAD_REQUEST;
                    end
                end
                
                CTX_LOAD_REQUEST: begin
                    // Activate the other thread - use case statement
                    case (switching_thread)
                        2'b00: begin
                            thread_contexts[1].active <= 1'b1;
                            thread_contexts[1].halted <= 1'b0;
                        end
                        2'b01: begin
                            thread_contexts[0].active <= 1'b1;
                            thread_contexts[0].halted <= 1'b0;
                        end
                    endcase
                    context_state <= CTX_LOAD_WAIT;
                end
                
                CTX_LOAD_WAIT: begin
                    context_save_cycles <= context_save_cycles + 1;
                    
                    // Wait a few cycles for new thread to start
                    if (context_save_cycles >= 8'd10) begin
                        context_state <= CTX_COMPLETE;
                    end
                end
                
                CTX_COMPLETE: begin
                    context_state <= CTX_IDLE;
                end
            endcase
            
            // =============================================
            // Performance Counter Updates
            // =============================================
            
            // Manual unroll for NUM_THREADS = 2
            perf_thread_cycles_int[0] <= thread_contexts[0].cycle_count;
            perf_thread_instructions_int[0] <= thread_contexts[0].instruction_count;
            perf_thread_cycles_int[1] <= thread_contexts[1].cycle_count;
            perf_thread_instructions_int[1] <= thread_contexts[1].instruction_count;
            
            // Detect resource conflicts
            if (thread_contexts[0].active && thread_contexts[1].active &&
                (resource_usage[0] > 32'd1000) && (resource_usage[1] > 32'd1000)) begin
                perf_resource_conflicts <= perf_resource_conflicts + 1;
            end
        end
    end
    
    // =========================================================================
    // Output Assignments
    // =========================================================================
    
    assign thread_active[0] = thread_contexts[0].active && !thread_contexts[0].halted;
    assign thread_active[1] = thread_contexts[1].active && !thread_contexts[1].halted;
    
    assign pc_t0 = thread_contexts[0].pc;
    assign pc_t1 = thread_contexts[1].pc;
    
    assign thread_flush_t0 = thread_contexts[0].exception_valid;
    assign thread_flush_t1 = thread_contexts[1].exception_valid;
    
    assign context_switch_ack = (context_state == CTX_COMPLETE);
    
    // =========================================================================
    // Output Assignments - Map internal arrays to individual signals
    // =========================================================================
    assign thread_priority_0 = thread_priority_int[0];
    assign thread_priority_1 = thread_priority_int[1];
    assign perf_thread_cycles_0 = perf_thread_cycles_int[0];
    assign perf_thread_cycles_1 = perf_thread_cycles_int[1];
    assign perf_thread_instructions_0 = perf_thread_instructions_int[0];
    assign perf_thread_instructions_1 = perf_thread_instructions_int[1];

endmodule
