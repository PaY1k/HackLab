`timescale 1ns / 1ps

// Self-checking test: text MIDI lines over UART 115200 -> note on/off events.
//   iverilog -g2012 -o /tmp/mt -s tb_midi_text src/rtl/uart.sv src/rtl/midi_text_rx.sv src/tb/tb_midi_text.sv
//   vvp -n /tmp/mt
module tb_midi_text;
  bit   clk;
  logic rst_n = 0;
  always #10.171 clk = ~clk;                       // 49.159 MHz

  logic       rx = 1;
  wire  [7:0] rx_byte;
  wire        rx_valid, m_on, m_off, m_all, ok;
  wire  [6:0] m_note;

  uart_rx #( .CLKS_PER_BIT ( 427 ) ) uart ( .clk ( clk ), .rst_n ( rst_n ), .rx ( rx ), .data ( rx_byte ), .valid ( rx_valid ) );
  midi_text_rx dut (
    .clk ( clk ), .rst_n ( rst_n ), .rx_data ( rx_byte ), .rx_valid ( rx_valid ),
    .midi_on ( m_on ), .midi_off ( m_off ), .midi_note ( m_note ), .midi_all_off ( m_all ), .cmd_ok ( ok )
  );

  // PC side: 115200 baud, 8N1
  localparam real BIT_NS = 1.0e9 / 115200;
  task automatic send_line (input string s);
    logic [7:0] ch;
    for ( int k = 0; k < s.len(); k++ ) begin
      ch = s[k];
      rx = 0; #( BIT_NS );
      for ( int i = 0; i < 8; i++ ) begin rx = ch[i]; #( BIT_NS ); end
      rx = 1; #( BIT_NS );
    end
  endtask

  string got = "";
  always @( posedge clk ) begin
    if ( m_on )  got = { got, $sformatf( "on%0d ", m_note ) };
    if ( m_off ) got = { got, $sformatf( "off%0d ", m_note ) };
    if ( m_all ) got = { got, "all " };
  end

  string expected = "on60 off60 on64 off64 off67 on62 off62 all on72 all on48 all ";

  initial begin
    repeat ( 10 ) @( posedge clk );
    rst_n = 1;
    #20_000;
    send_line( "ON 60 100\n" );
    send_line( "OFF 60\r\n" );
    send_line( "note_on channel=0 note=64 velocity=90 time=0\n" );
    send_line( "note_off channel=0 note=64 velocity=64 time=0\n" );
    send_line( "NOTE_ON 67 0\n" );                                  // velocity 0 = off
    send_line( "62 100\n" );
    send_line( "62 0\n" );
    send_line( "control_change channel=0 control=123 value=0\n" );  // all notes off
    send_line( "  on   72 \n" );
    send_line( "OFF\n" );                                           // all notes off
    send_line( "hello world\n" );                                   // ignored
    send_line( "NoteOn 48 127;" );
    send_line( "STOP\n" );
    send_line( "control_change channel=0 control=7 value=100\n" );  // volume CC: ignored
    #50_000;
    $display( "got:      %s", got );
    $display( "expected: %s", expected );
    if ( got == expected ) $display( "PASS" );
    else                   $display( "FAIL" );
    $finish;
  end
endmodule
