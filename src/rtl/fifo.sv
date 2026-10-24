module fifo #(
    parameter    DATA_WIDTH = 32,
    parameter    DEPTH      = 256,
    parameter    ADDR_WIDTH = 8
)(
    input  wire                  clk     ,
    input  wire                  rst_n   ,

    input  wire [DATA_WIDTH-1:0] wr_data ,
    input  wire                  wr_en   ,
    output wire                  full    ,

    output wire [DATA_WIDTH-1:0] rd_data ,
    input  wire                  rd_en   ,
    output wire                  empty
);

    localparam [ADDR_WIDTH:0] DEPTH_SIZED = DEPTH[ADDR_WIDTH:0];

    reg  [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg  [ADDR_WIDTH-1:0] wr_ptr;
    reg  [ADDR_WIDTH-1:0] rd_ptr;
    reg  [ADDR_WIDTH:0]   count;

    wire do_write;
    wire do_read;

    assign do_write = wr_en && !full;
    assign do_read  = rd_en && !empty;

    always_ff @( posedge clk or negedge rst_n ) begin
      if ( !rst_n ) begin
        wr_ptr <= {ADDR_WIDTH{1'b0}};
        rd_ptr <= {ADDR_WIDTH{1'b0}};
        count  <= {(ADDR_WIDTH+1){1'b0}};
      end
      else begin
        if ( do_write ) begin
          mem [wr_ptr] <= wr_data;
          wr_ptr       <= wr_ptr + 1'b1;
        end
        if ( do_read )
          rd_ptr <= rd_ptr + 1'b1;
        case ( {do_write, do_read} )
          2'b10:   count <= count + 1'b1;
          2'b01:   count <= count - 1'b1;
          default: count <= count        ;
        endcase
      end
    end

    assign full    = ( count == DEPTH_SIZED            );
    assign empty   = ( count == {(ADDR_WIDTH+1){1'b0}} );
    assign rd_data = mem [rd_ptr];

endmodule
