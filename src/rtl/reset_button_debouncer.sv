module reset_button_debouncer #(
  parameter    CNT_WIDTH      = 16
)(
  input  wire     clk_100mhz   ,
  input  wire     clk_5mhz     ,
  input  wire     reset_button ,
  input  wire     pll_locked   ,
  output reg      pll_rst_n    ,
  output wire     rst_n
);
  reg   [1:0]             domain_100mhz_synch;
  reg   [1:0]             domain_5mhz_synch;
  reg   [CNT_WIDTH-1:0]   pulse_cntr;
  wire                    debouncing_finished;

  always_ff @( posedge clk_100mhz ) begin
    domain_100mhz_synch <= {domain_100mhz_synch[0], reset_button};
  end

  always @( posedge clk_100mhz ) begin
    if      ( domain_100mhz_synch[1] ) begin   // UNPUSHED STATE
      pulse_cntr <= 0;
    end
    else if ( !debouncing_finished ) begin     // PUSHED STATE & DEBOUNCING isn't finished
      pulse_cntr <= pulse_cntr + 1;
    end
  end

  assign debouncing_finished = &pulse_cntr;

  always @( posedge clk_100mhz ) begin
    pll_rst_n <= ~debouncing_finished;
  end

  always @( posedge clk_5mhz or negedge pll_rst_n) begin
    if      ( !pll_rst_n )
      domain_5mhz_synch <= 2'b0;
    else if ( pll_locked )
      domain_5mhz_synch <= {domain_5mhz_synch[0], 1'b1};
  end
  assign rst_n = domain_5mhz_synch[1];

endmodule