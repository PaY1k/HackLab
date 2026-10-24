`timescale 1ns / 1ps

// Self-checking test of pc_link: UART packets in, FIFO / MIDI / title / credits out.
//   iverilog -g2012 -o /tmp/pl -s tb_pc_link src/rtl/uart.sv src/rtl/pc_link.sv src/rtl/async_fifo.sv src/tb/tb_pc_link.sv
//   vvp -n /tmp/pl
module tb_pc_link;
  localparam CPB = 53;
  bit   clk;
  logic rst_n = 0;
  always #10.171 clk = ~clk;                    // 49.159 MHz

  logic rx = 1;
  wire  tx;
  wire        fifo_wr, fifo_empty, fifo_full;
  wire [15:0] fifo_data, fifo_q;
  wire [12:0] wr_level, rd_level;
  logic       fifo_rd = 0;
  wire        m_on, m_off, m_all;
  wire [6:0]  m_note;
  logic [4:0] t_idx = 0;
  wire [7:0]  t_char;
  wire        t_valid, t_changed;

  pc_link #( .CLKS_PER_BIT ( CPB ) ) dut (
    .clk ( clk ), .rst_n ( rst_n ), .uart_rx_pin ( rx ), .uart_tx_pin ( tx ),
    .fifo_wr ( fifo_wr ), .fifo_data ( fifo_data ), .fifo_level ( wr_level ),
    .midi_on ( m_on ), .midi_off ( m_off ), .midi_note ( m_note ), .midi_all_off ( m_all ),
    .title_idx ( t_idx ), .title_char ( t_char ), .title_valid ( t_valid ), .title_changed ( t_changed )
  );

  async_fifo #( .DATA_WIDTH ( 16 ), .ADDR_WIDTH ( 12 ) ) fifo (
    .wr_clk ( clk ), .wr_rst_n ( rst_n ), .wr_en ( fifo_wr ), .wr_data ( fifo_data ), .full ( fifo_full ), .wr_level ( wr_level ),
    .rd_clk ( clk ), .rd_rst_n ( rst_n ), .rd_en ( fifo_rd ), .rd_data ( fifo_q ), .empty ( fifo_empty ), .rd_level ( rd_level )
  );

  // PC -> board, 921600 baud as the PC really sends (bit = 1085 ns)
  task automatic send_byte (input [7:0] b);
    rx = 0; #1085;
    for ( int i = 0; i < 8; i++ ) begin rx = b[i]; #1085; end
    rx = 1; #1085;
  endtask

  logic [7:0] pl [0:299];                       // payload of the next packet

  task automatic send_pkt (input [7:0] t, input int len);
    send_byte( 8'hA5 ); send_byte( t ); send_byte( 8'( len ) );
    for ( int i = 0; i < len; i++ ) send_byte( pl[i] );
  endtask

  // board -> PC: count credit bytes
  int credits = 0;
  initial begin
    logic [7:0] b;
    forever begin
      @( negedge tx );
      #( CPB * 20.342 * 1.5 );
      for ( int i = 0; i < 8; i++ ) begin b[i] = tx; #( CPB * 20.342 ); end
      if ( b == 8'hC1 ) credits++;
    end
  end

  int ons = 0, offs = 0, alls = 0, last_note = 0, errors = 0;
  always @( posedge clk ) begin
    if ( m_on )  begin ons++;  last_note = m_note; end
    if ( m_off ) offs++;
    if ( m_all ) alls++;
  end

  int         got;
  string      title;
  logic [7:0] exp;

  initial begin
    repeat ( 10 ) @( posedge clk );
    rst_n = 1;
    #50_000;
    send_pkt( 8'd5, 0 );                                   // hello
    // title "Привет"
    { pl[0], pl[1], pl[2], pl[3], pl[4], pl[5] } = { 8'h8F, 8'hE0, 8'hA8, 8'hA2, 8'hA5, 8'hE2 };
    send_pkt( 8'd3, 6 );
    // 300 bytes of audio in two packets: ramp 0..255, 0..43
    for ( int i = 0; i < 255; i++ ) pl[i] = 8'( i );
    send_pkt( 8'd1, 255 );
    for ( int i = 0; i < 45; i++ ) pl[i] = 8'( i );
    send_pkt( 8'd1, 45 );
    // MIDI: note on 60 vel 100, note off 60, note on 64 vel 0 (= off), all off
    { pl[0], pl[1], pl[2] } = { 8'h90, 8'd60, 8'd100 };  send_pkt( 8'd2, 3 );
    { pl[0], pl[1], pl[2] } = { 8'h80, 8'd60, 8'd0   };  send_pkt( 8'd2, 3 );
    { pl[0], pl[1], pl[2] } = { 8'h90, 8'd64, 8'd0   };  send_pkt( 8'd2, 3 );
    send_pkt( 8'd4, 0 );
    #50_000;

    // check FIFO content
    got = 0;
    while ( !fifo_empty ) begin
      exp = ( got < 255 ) ? 8'( got ) : 8'( got - 255 );
      if ( fifo_q !== { ~exp[7], exp[6:0], 8'h00 } ) begin
        errors++;
        if ( errors < 5 ) $display( "audio %0d: got %h", got, fifo_q );
      end
      @( negedge clk ) fifo_rd = 1;
      @( negedge clk ) fifo_rd = 0;
      got++;
    end

    title = "";
    for ( int i = 0; i < 6; i++ ) begin
      t_idx = 5'( i ); #1;
      title = { title, $sformatf( "%02x ", t_char ) };
    end

    $display( "audio=%0d ons=%0d offs=%0d alls=%0d note=%0d title_valid=%b title=%s credits=%0d",
              got, ons, offs, alls, last_note, t_valid, title, credits );
    if ( errors == 0 && got == 300 && ons == 1 && offs == 2 && alls == 1 && last_note == 60 &&
         t_valid && title == "8f e0 a8 a2 a5 e2 " && credits >= 16 )
      $display( "PASS" );
    else
      $display( "FAIL (errors=%0d)", errors );
    $finish;
  end
endmodule
