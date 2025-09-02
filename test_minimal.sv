module test_minimal (
    input logic [9:0] btb_index,
    input logic [63:0] predict_pc,
    input logic predict_thread,
    output logic btb_hit
);

    typedef struct packed {
        logic        valid;
        logic [47:0] tag;
        logic [63:0] target;
        logic [1:0]  branch_type;
        logic        thread_id;
    } btb_entry_t;

    btb_entry_t btb_table [1023:0];
    logic [47:0] btb_tag;
    
    assign btb_tag = predict_pc[63:16];
    
    always_comb begin
        if (btb_table[btb_index].valid && 
            btb_table[btb_index].tag == btb_tag &&
            btb_table[btb_index].thread_id == predict_thread) begin
            btb_hit = 1'b1;
        end else begin
            btb_hit = 1'b0;
        end
    end

endmodule
