// Multi-bit bus crossing between two clock domains (req/ack toggle handshake).
//
// The source copies src_data into a holding register and toggles req.
// The destination sees the synchronized toggle and takes the holding register,
// which is guaranteed stable at that moment, then answers with ack.
// The source loads a new value only after ack came back.
//
// Good for slowly changing status (play, volume, time, track number ...):
// dst_data follows src_data with a delay of a few clocks of both domains.
// Not for streams of samples - use async_fifo for those.
module cdc_bus #(
    parameter  WIDTH = 32
)(
    input  wire              src_clk   ,
    input  wire              src_rst_n ,
    input  wire [WIDTH-1:0]  src_data  ,

    input  wire              dst_clk   ,
    input  wire              dst_rst_n ,
    output logic [WIDTH-1:0] dst_data
);

  logic [WIDTH-1:0] hold;          // src domain, stable while req != ack
  logic             req;           // src domain toggle
  logic             ack;           // dst domain toggle
  (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync;  // ack in src domain
  (* ASYNC_REG = "TRUE" *) logic [1:0] req_sync;  // req in dst domain

//------------- Source domain                                    -------------//
  always_ff @( posedge src_clk or negedge src_rst_n ) begin
    if ( !src_rst_n ) begin
      hold     <= '0;
      req      <= 1'b0;
      ack_sync <= 2'b00;
    end
    else begin
      ack_sync <= { ack_sync[0], ack };
      if ( ack_sync[1] == req ) begin   // previous value delivered
        hold <= src_data;
        req  <= ~req;
      end
    end
  end

//------------- Destination domain                               -------------//
  always_ff @( posedge dst_clk or negedge dst_rst_n ) begin
    if ( !dst_rst_n ) begin
      dst_data <= '0;
      ack      <= 1'b0;
      req_sync <= 2'b00;
    end
    else begin
      req_sync <= { req_sync[0], req };
      if ( req_sync[1] != ack ) begin   // new value is waiting
        dst_data <= hold;
        ack      <= req_sync[1];
      end
    end
  end

endmodule
