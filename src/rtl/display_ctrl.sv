module display_ctrl #(
  //SVGA 800x600@60Hz timing
  parameter h_pixels   = 800    ,  // horizontal active display
  parameter h_fp       = 40     ,  // horizontal front porch
  parameter h_pulse    = 128    ,  // horizontal sync pulse
  parameter h_bp       = 88     ,  // horizontal back porch
  parameter h_pol      = 1'b1   ,  // horizontal sync polarity (1 = positive, 0 = negative)
  parameter v_pixels   = 600    ,  // vertical active display
  parameter v_fp       = 1      ,  // vertical front porch
  parameter v_pulse    = 4      ,  // vertical pulse
  parameter v_bp       = 23     ,  // vertical back porch
  parameter v_pol      = 1'b1      // vertical sync polarity (1 = positive, 0 = negative)
)(
  input  wire      pixel_clk   ,  // pixel clock
  input  wire      rst_n       ,  // active low synchronous reset
  output reg       h_sync      ,  // horizontal sync signal
  output reg       v_sync      ,  // vertical sync signal
  output reg       disp_enbl   ,  // display enable (0 = all colors must be blank)
  output reg [10:0] h_coord     ,  // horizontal pixel coordinate
  output reg [ 9:0] v_coord        // vertical pixel coordinate
);

  //----------- Get total number of row and column pixel clocks    -----------//
    localparam h_period = h_pulse + h_bp + (h_pixels-1) + h_fp;
    localparam v_period = v_pulse + v_bp + (v_pixels-1) + v_fp;
  //----------- Full range counters                                -----------//
    //reg [$clog2(h_period)-1:0] h_count;  // Verilator doesn't work with $clog2
    //reg [$clog2(v_period)-1:0] v_count;
    reg [10:0] h_count;
    reg [ 9:0] v_count;

    always_ff @( posedge pixel_clk ) begin  // Pixel Counters
      if ( !rst_n ) begin
        h_count <= 0;
        v_count <= 0;
      end
      else if (h_count < h_period) begin
        h_count <= h_count + 1;
      end 
      else begin
        h_count <= 0;
        if (v_count < v_period) begin
          v_count <= v_count + 1;
        end 
        else begin
          v_count <= 0;
        end
      end
    end
  //----------- h_sync & v_sync                                    -----------//
    always @( posedge pixel_clk ) begin
      if ( !rst_n ) begin
        h_sync   <= ~ h_pol;
        v_sync   <= ~ v_pol;
      end
      else begin
        // Horizontal Sync Signal
        if ( (h_count >= (h_pixels-1) + h_fp) && (h_count < (h_pixels-1) + h_fp + h_pulse) ) begin
          h_sync <= h_pol;
        end
        else begin
          h_sync <= ~h_pol;
        end
        // Vertical Sync Signal
        if ( (v_count >= (v_pixels-1) + v_fp) && (v_count < (v_pixels-1) + v_fp + v_pulse) ) begin
          v_sync <= v_pol;
        end
        else begin
          v_sync <= ~v_pol;
        end
      end
    end
  //----------- h_coord & v_coord                                  -----------//
    assign h_coord = h_count;
    assign v_coord = v_count;
  //----------- Display enable                                     -----------//
    always @( posedge pixel_clk ) begin
      if ( !rst_n ) begin
        disp_enbl <= 1'b1;
      end
      else begin
        if   ( h_count < (h_pixels-1) && v_count < v_pixels ) begin
          disp_enbl <= 1'b1;
        end 
        else if (h_count == h_period && (v_count < (v_pixels-1 ) || (v_count == v_period) )) begin
          disp_enbl <= 1'b1;
        end
        else begin
          disp_enbl <= 1'b0;
        end
      end
    end
endmodule
