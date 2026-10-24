`timescale 1ns / 1ps

// audio_core + player_ctrl: synth note, track change to a melody, pause.
// Every output sample is written to a text file; tools/samples_to_wav.py
// turns it into a WAV you can listen to and checks the pitch.
// PWM_BITS = 7 makes the sample tick 8x more frequent than on the board,
// everything that is counted in ticks behaves the same.
//   iverilog -g2012 -o /tmp/ac -s tb_audio_core src/rtl/poly_synth.sv src/rtl/melody_player.sv \
//     src/rtl/stream_reader.sv src/rtl/audio_core.sv src/rtl/player_ctrl.sv src/tb/tb_audio_core.sv
//   cd src/rtl/mem && vvp -n /tmp/ac +OUT=/tmp/ac.txt && cd -
//   python3 tools/samples_to_wav.py /tmp/ac.txt ac.wav
module tb_audio_core;
  bit clk;
  logic rst_n = 0;
  always #10 clk = ~clk;

  logic bc = 0, bu = 0, bd = 0, bl = 0, br = 0;
  wire       play, switching, restart, tick, gain_zero, pwm;
  wire [3:0] volume;
  wire [2:0] note_index, track;
  wire [15:0] out_u16, len_bcd;
  wire [9:0]  progress;
  wire [35:0] key_mask;

  player_ctrl ctrl (
    .clk ( clk ), .rst_n ( rst_n ),
    .btn_c ( bc ), .btn_u ( bu ), .btn_d ( bd ), .btn_l ( bl ), .btn_r ( br ),
    .notes_mode ( 1'b0 ), .gain_zero ( gain_zero ),
    .play ( play ), .volume ( volume ), .note_index ( note_index ), .track ( track ),
    .switching ( switching ), .restart ( restart )
  );

  audio_core #( .PWM_BITS ( 7 ) ) core (
    .clk ( clk ), .rst_n ( rst_n ),
    .play ( play ), .volume ( volume ), .track ( track ), .switching ( switching ), .restart ( restart ),
    .synth_note ( 7'd69 ), .synth_params ( 32'hF206B510 ), .bend ( 14'sd0 ), .mod_wheel ( 7'd0 ),
    .midi_on ( 1'b0 ), .midi_off ( 1'b0 ), .midi_note ( 7'd0 ), .midi_all_off ( 1'b0 ),
    .sd_empty ( 1'b1 ), .sd_data ( 16'd0 ), .sd_step ( 16'd65527 ), .sd_rd ( ),
    .pc_empty ( 1'b1 ), .pc_data ( 16'd0 ), .pc_rd ( ),
    .tick ( tick ), .gain_zero ( gain_zero ), .aud_pwm ( pwm ), .out_u16 ( out_u16 ),
    .key_mask ( key_mask ), .mel_len_bcd ( len_bcd ), .mel_progress ( progress )
  );

  int    fd, n;
  string out;

  // button pulse: "c", "u", "d", "l", "r"
  task automatic press (input byte b);
    @( negedge clk );
    case ( b ) "c": bc = 1; "u": bu = 1; "d": bd = 1; "l": bl = 1; default: br = 1; endcase
    @( negedge clk );
    { bc, bu, bd, bl, br } = '0;
  endtask

  task automatic run_ticks (int k);
    repeat ( k ) begin
      @( posedge tick );
      @( posedge clk );
      // out_u16 is updated 4 clocks after tick
      repeat ( 4 ) @( posedge clk );
      $fwrite( fd, "%0d\n", out_u16 );
    end
  endtask

  initial begin
    if ( !$value$plusargs( "OUT=%s", out ) ) out = "ac.txt";
    fd = $fopen( out, "w" );
    repeat ( 5 ) @( posedge clk );
    rst_n = 1;
    repeat ( 3 ) press( "u" );                 // volume 13
    press( "c" );                              // play: synth A4
    run_ticks( 9600 );                        // 0.2 s
    $display( "synth: track=%0d play=%b keys=%h", track, play, key_mask );
    press( "r" );                              // -> track 1 (melody)
    run_ticks( 48000 );                       // 1 s
    $display( "melody: track=%0d len=%h progress=%0d keys=%h", track, len_bcd, progress, key_mask );
    press( "c" );                              // pause: fade out
    run_ticks( 4800 );
    $display( "pause: gain_zero=%b", gain_zero );
    $fclose( fd );
    $finish;
  end
endmodule
