// UART receiver and transmitter, 8N1.
// CLKS_PER_BIT = f_clk / baud: 49.15865 MHz / 921600 = 53.3 -> 53 (0.6 % off, fine).

module uart_rx #(
    parameter  CLKS_PER_BIT = 53
)(
    input  wire        clk   ,
    input  wire        rst_n ,
    input  wire        rx    ,      // pin, asynchronous
    output logic [7:0] data  ,
    output logic       valid        // one clock per received byte
);
  (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync;
  logic [7:0]  cnt;
  logic [3:0]  bit_i;
  logic        busy;
  logic [7:0]  sh;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      rx_sync <= 2'b11;
      cnt     <= '0;
      bit_i   <= '0;
      busy    <= 1'b0;
      sh      <= '0;
      data    <= '0;
      valid   <= 1'b0;
    end
    else begin
      rx_sync <= { rx_sync[0], rx };
      valid   <= 1'b0;
      if ( !busy ) begin
        if ( !rx_sync[1] ) begin               // start bit edge
          busy  <= 1'b1;
          cnt   <= 8'( CLKS_PER_BIT / 2 );     // go to the middle of the start bit
          bit_i <= '0;
        end
      end
      else if ( cnt != 0 )
        cnt <= cnt - 1'b1;
      else begin
        cnt <= 8'( CLKS_PER_BIT - 1 );
        if ( bit_i == 4'd0 ) begin             // middle of start bit
          if ( rx_sync[1] ) busy <= 1'b0;      // glitch, not a start bit
          bit_i <= 4'd1;
        end
        else if ( bit_i <= 4'd8 ) begin        // data bits, LSB first
          sh    <= { rx_sync[1], sh[7:1] };
          bit_i <= bit_i + 1'b1;
        end
        else begin                             // stop bit
          busy <= 1'b0;
          if ( rx_sync[1] ) begin
            data  <= sh;
            valid <= 1'b1;
          end
        end
      end
    end
  end
endmodule


module uart_tx #(
    parameter  CLKS_PER_BIT = 53
)(
    input  wire        clk   ,
    input  wire        rst_n ,
    input  wire [7:0]  data  ,
    input  wire        start ,      // pulse, ignored while busy
    output logic       busy  ,
    output logic       tx
);
  logic [7:0] cnt;
  logic [3:0] bit_i;
  logic [9:0] sh;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      busy  <= 1'b0;
      tx    <= 1'b1;
      cnt   <= '0;
      bit_i <= '0;
      sh    <= '1;
    end
    else if ( !busy ) begin
      tx <= 1'b1;
      if ( start ) begin
        sh    <= { 1'b1, data, 1'b0 };         // stop, data, start
        busy  <= 1'b1;
        cnt   <= '0;
        bit_i <= '0;
      end
    end
    else if ( cnt != 0 )
      cnt <= cnt - 1'b1;
    else begin
      if ( bit_i == 4'd10 )
        busy <= 1'b0;
      else begin
        tx    <= sh[0];
        sh    <= { 1'b1, sh[9:1] };
        bit_i <= bit_i + 1'b1;
        cnt   <= 8'( CLKS_PER_BIT - 1 );
      end
    end
  end
endmodule
