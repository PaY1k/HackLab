`timescale 1ns / 1ps

// Whole player: unified packets over UART -> synth -> output samples.
// "ON 69 100" must sound at 440 Hz, "OFF 69" must fade out, the piano key and LEDs follow.
//   iverilog -g2012 -o /tmp/ms -s tb_midi_system src/rtl/*.sv src/tb/tb_midi_system.sv
//   cd src/rtl/mem && vvp -n /tmp/ms +OUT=/tmp/ms.txt && cd -
//   python3 tools/samples_to_wav.py /tmp/ms.txt midi.wav 50
module tb_midi_system;
  bit clk, pclk;
  logic rst_n = 0;
  always #10.171 clk  = ~clk;
  // Pixel clock stopped: this regression checks audio/UART, not rendering.

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

  defparam player.audio_core.PWM_BITS = 7; // accelerate envelopes 8x
  localparam real BIT_NS = 1.0e9 / 921600;
  task automatic send_byte(input [7:0] ch);
    rx = 0; #(BIT_NS);
    for (int i=0; i<8; i++) begin rx=ch[i]; #(BIT_NS); end
    rx = 1; #(BIT_NS);
  endtask
  task automatic send_line(input string s);
    send_byte(8'hA5); send_byte(6); send_byte(s.len());
    for (int k=0; k<s.len(); k++) send_byte(s[k]);
  endtask
  task automatic note_packet(input [7:0] status_byte, input [7:0] note, input [7:0] vel);
    send_byte(8'hA5); send_byte(2); send_byte(3);
    send_byte(status_byte); send_byte(note); send_byte(vel);
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
    send_line("SET WAVE TRI\n");
    send_line("BEND -4096\n");
    send_line("CC 1 64\n");
    if (player.synth_params[1:0] != 1 || player.bend != -4096 || player.mod_wheel != 64)
      $fatal(1, "packet settings/controllers failed");
    send_line("BEND 0\n");
    send_line("CC 1 0\n");
    send_line("SET WAVE SINE\n");
    send_byte(8'hA5); send_byte(1); send_byte(8);
    for (int i=0; i<8; i++) send_byte(8'(120+i));
    if (player.pc_level != 7) $fatal(1, "audio not buffered beside MIDI"); // one word prefetched
    #2_000_000;                                       // 2 ms of silence
    note_packet(8'h90, 69, 100);                       // A4
    #100;
    $display( "after ON:  key A4=%b leds=%b", player.key_mask[21], leds );
    if ( !player.key_mask[21] || !leds[1] || !leds[2] ) errors++;
    #5_000_000;                                      // 40 ms of the note
    note_packet(8'h80, 69, 0);
    #15_000_000;                                     // release (~80 ms)
    $display( "after OFF: key A4=%b leds=%b", player.key_mask[21], leds );
    if ( player.key_mask[21] || leds[2] ) errors++;
    $fclose( fd );
    if ( errors == 0 ) $display( "PASS (pitch: python3 tools/samples_to_wav.py %s midi.wav 50)", out );
    else               $fatal(1, "FAIL");
    $finish;
  end
  initial begin #40_000_000; $fatal(1, "timeout"); end
endmodule
