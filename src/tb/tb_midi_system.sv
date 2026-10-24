`timescale 1ns / 1ps

// Whole player: text MIDI over UART -> synth -> output samples.
// "ON 69 100" must sound at 440 Hz, "OFF 69" must fade out, the piano key and LEDs follow.
//   iverilog -g2012 -o /tmp/ms -s tb_midi_system src/rtl/*.sv src/tb/tb_midi_system.sv
//   cd src/rtl/mem && vvp -n /tmp/ms +OUT=/tmp/ms.txt && cd -
//   python3 tools/samples_to_wav.py /tmp/ms.txt midi.wav 50
module tb_midi_system;
  bit clk, pclk;
  logic rst_n = 0;
  always #10.171 clk  = ~clk;
  always #12.518 pclk = ~pclk;

  logic rx = 1;
  wire  [3:0] leds;
  wire        pwm;

  player_top #( .SPLASH_LOG2 ( 8 ), .SD_WAIT_BITS ( 8 ) ) player (
    .aud_clk ( clk ), .aud_rst_n ( rst_n ), .pix_clk ( pclk ), .pix_rst_n ( rst_n ),
    .btn_c ( 1'b0 ), .btn_u ( 1'b0 ), .btn_d ( 1'b0 ), .btn_l ( 1'b0 ), .btn_r ( 1'b0 ),
    .sw ( 16'd0 ), .aud_pwm ( pwm ), .uart_rx ( rx ), .uart_tx ( ),
    .sd_reset ( ), .sd_cs ( ), .sd_sck ( ), .sd_mosi ( ), .sd_miso ( 1'b1 ),
    .vga_r ( ), .vga_g ( ), .vga_b ( ), .vga_hs ( ), .vga_vs ( ), .vga_de ( ), .vga_h ( ), .vga_v ( ),
    .play ( ), .volume ( ), .note_index ( ), .track ( ), .octave ( ), .leds ( leds )
  );

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

  // output samples at every tick
  int    fd;
  string out;
  always @( posedge clk ) if ( player.audio_core.st[2] ) $fwrite( fd, "%0d\n", player.audio_core.out_u16 );

  int errors = 0;
  initial begin
    if ( !$value$plusargs( "OUT=%s", out ) ) out = "ms.txt";
    fd = $fopen( out, "w" );
    repeat ( 10 ) @( posedge clk );
    rst_n = 1;
    #2_000_000;                                       // 2 ms of silence
    send_line( "ON 69 100\n" );                       // A4
    #100;
    $display( "after ON:  key A4=%b leds=%b", player.key_mask[21], leds );
    if ( !player.key_mask[21] || !leds[1] || !leds[2] ) errors++;
    #40_000_000;                                      // 40 ms of the note
    send_line( "OFF 69\n" );
    #100_000_000;                                     // release (~80 ms)
    $display( "after OFF: key A4=%b leds=%b", player.key_mask[21], leds );
    if ( player.key_mask[21] || leds[2] ) errors++;
    $fclose( fd );
    if ( errors == 0 ) $display( "PASS (pitch: python3 tools/samples_to_wav.py %s midi.wav 50)", out );
    else               $display( "FAIL" );
    $finish;
  end
endmodule
