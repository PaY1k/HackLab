// Reset synchronizer: brings an asynchronous active-low reset into the clk domain.
// Assertion is immediate (asynchronous), release happens on a clk edge after 2 flip-flops,
// so all flip-flops of the domain leave reset on the same clock edge.
module reset_sync (
  input  wire     clk     ,
  input  wire     arst_n  ,  // reset from another clock domain
  output wire     rst_n      // reset released synchronously to clk
);

  (* ASYNC_REG = "TRUE" *) logic [1:0] sync;

  always_ff @( posedge clk or negedge arst_n ) begin
    if ( !arst_n )
      sync <= 2'b00;
    else
      sync <= { sync[0], 1'b1 };
  end

  assign rst_n = sync[1];

endmodule
