// Simple test to verify the issue queue module syntax
module test_vixen_issue_queue;
    
    logic clk, rst_n;
    
    // Instantiate the issue queue
    vixen_issue_queue #(
        .IQ_ENTRIES(32),
        .NUM_THREADS(2), 
        .NUM_ALU(2),
        .NUM_AGU(1),
        .NUM_FPU(2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        // Other ports can be tied off for syntax test
        .iq_valid(32'b0),
        .iq_ready(32'b0),
        .iq_entries_in('{default: '0}),
        .alloc_valid(4'b0),
        .alloc_uop('{default: '0}),
        .alloc_rob_id('{default: '0}),
        .alloc_thread_id('{default: '0}),
        .alloc_src1_ready(4'b0),
        .alloc_src2_ready(4'b0),
        .broadcast_rob_id('{default: '0}),
        .broadcast_valid('{default: '0}),
        .alu_issue_valid(),
        .alu_issue_uop(),
        .alu_issue_rob_id(),
        .alu_issue_thread_id(),
        .agu_issue_valid(),
        .agu_issue_uop(),
        .agu_issue_rob_id(),
        .agu_issue_thread_id(),
        .mul_issue_valid(),
        .mul_issue_uop(),
        .mul_issue_rob_id(),
        .mul_issue_thread_id(),
        .div_issue_valid(),
        .div_issue_uop(),
        .div_issue_rob_id(),
        .div_issue_thread_id(),
        .fpu_issue_valid(),
        .fpu_issue_uop(),
        .fpu_issue_rob_id(),
        .fpu_issue_thread_id(),
        .full(),
        .alloc_ready(),
        .perf_issue_stalls(),
        .perf_thread_stalls_0(),
        .perf_thread_stalls_1()
    );
    
endmodule
