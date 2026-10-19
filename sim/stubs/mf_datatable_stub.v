// Lint-only stand-in for the APF template's mf_datatable (an altsyncram).
module mf_datatable (
    input  wire [9:0]  address_a, address_b,
    input  wire        clock_a, clock_b,
    input  wire [31:0] data_a, data_b,
    input  wire        wren_a, wren_b,
    output wire [31:0] q_a, q_b
);
    assign q_a = 32'd0;
    assign q_b = 32'd0;
    wire _unused = &{1'b0, address_a, address_b, clock_a, clock_b, data_a, data_b, wren_a, wren_b};
endmodule
