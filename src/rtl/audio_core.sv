// Audio core: everything from sound sources to the AUD_PWM pin, clk_audio domain.
//
//   track 0       : manual synth (voice 0 of poly_synth)
//   track 1, 2    : melodies from BRAM (melody_player -> voice 1)
//   track 3, 4    : WAV files from the SD card   (sd FIFO -> stream_reader)
//   track 5       : audio stream from the PC     (pc FIFO -> stream_reader)
//   MIDI keyboard : voices 2..9, always mixed on top of the track
//
// Output stage:
//   * volume: 16 steps of 2 dB (log scale, as the ear hears it), 0 = mute
//   * gain moves smoothly (~20 ms full swing): pause, play, volume and track
//     changes never click
//   * signed sample -> unsigned -> PWM, 10 bits per 48 kHz period, with 1st
//     order noise shaping: the 6 dropped bits are carried to the next sample,
//     so the quantization noise moves above the audio band
module audio_core #(
    parameter  PWM_BITS   = 10,                   // tick = clk / 2^PWM_BITS
    parameter  SINE_FILE  = "sine1024.mem",
    parameter  NOTE_FILE  = "note_inc.mem",
    parameter  MEL_FILE   = "melodies.mem",
    parameter  INFO_FILE  = "melody_info.mem",
    parameter  UNIT_TICKS = 8'd240
)(
    input  wire          clk          ,
    input  wire          rst_n        ,
  //--------- Control (player_ctrl)              --------//
    input  wire          play         ,
    input  wire  [ 3:0]  volume       ,
    input  wire  [ 2:0]  track        ,
    input  wire          switching    ,   // fade out, a track change is waiting
    input  wire          restart      ,   // pulse: new track starts now
    input  wire  [ 6:0]  synth_note   ,   // MIDI note number of the manual synth
    input  wire  [31:0]  synth_params ,   // synth_settings.sv
    input  wire signed [13:0] bend   ,   // pitch bend -8192..8191
    input  wire  [ 6:0]  mod_wheel    ,
  //--------- MIDI                               --------//
    input  wire          midi_on      ,
    input  wire          midi_off     ,
    input  wire  [ 6:0]  midi_note    ,
    input  wire          midi_all_off ,
  //--------- Streams                            --------//
    input  wire          sd_empty     ,
    input  wire  [15:0]  sd_data      ,
    input  wire  [15:0]  sd_step      ,
    output wire          sd_rd        ,
    input  wire          pc_empty     ,
    input  wire  [15:0]  pc_data      ,
    output wire          pc_rd        ,
  //--------- Outputs                            --------//
    output logic         tick         ,   // sample tick, 48 kHz
    output wire          gain_zero    ,   // faded out completely
    output logic         aud_pwm      ,
    output logic [15:0]  out_u16      ,   // output sample, unsigned (for the scope)
    output wire  [35:0]  key_mask     ,
    output wire  [15:0]  mel_len_bcd  ,
    output wire  [ 9:0]  mel_progress
);

//------------- Sample tick and PWM counter                      -------------//
  logic [PWM_BITS-1:0] pwm_cnt;
  logic [PWM_BITS-1:0] duty;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      pwm_cnt <= '0;
      tick    <= 1'b0;
      aud_pwm <= 1'b0;
    end
    else begin
      pwm_cnt <= pwm_cnt + 1'b1;
      tick    <= &pwm_cnt;
      aud_pwm <= ( pwm_cnt < duty );
    end
  end
//____________________________________________________________________________//

//------------- Fade logic                                       -------------//
  logic [15:0] gain, target;

  function automatic [15:0] vol_gain (input [3:0] v);   // 2 dB per step
    case ( v )
      4'd0:  vol_gain = 16'd0;      4'd1:  vol_gain = 16'd2609;   4'd2:  vol_gain = 16'd3285;
      4'd3:  vol_gain = 16'd4135;   4'd4:  vol_gain = 16'd5206;   4'd5:  vol_gain = 16'd6554;
      4'd6:  vol_gain = 16'd8250;   4'd7:  vol_gain = 16'd10387;  4'd8:  vol_gain = 16'd13076;
      4'd9:  vol_gain = 16'd16462;  4'd10: vol_gain = 16'd20724;  4'd11: vol_gain = 16'd26090;
      4'd12: vol_gain = 16'd32845;  4'd13: vol_gain = 16'd41350;  4'd14: vol_gain = 16'd52056;
      default: vol_gain = 16'd65535;
    endcase
  endfunction

  localparam [15:0] GSTEP = 16'd64;          // 65535 / 64 = 1024 ticks = 21 ms

  // The track gain fades with pause and track changes. MIDI keeps playing
  // at the set volume even on pause: it is a live instrument.
  assign target    = ( play && !switching ) ? vol_gain( volume ) : 16'd0;
  assign gain_zero = ( gain == 16'd0 );
  wire   active    = !( gain_zero && target == 16'd0 );   // track sources advance

  // MIDI level: master volume * "midi volume" setting (0..15)
  logic [15:0] midi_gain;
  wire  [23:0] midi_t_full = vol_gain( volume ) * synth_params[31:28] * 8'd17;    // * mvol / 15
  wire  [15:0] midi_target = midi_t_full[23:8];
  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      gain      <= '0;
      midi_gain <= '0;
    end
    else if ( tick ) begin
      if ( gain < target )
        gain <= ( target - gain > GSTEP ) ? gain + GSTEP : target;
      else if ( gain > target )
        gain <= ( gain - target > GSTEP ) ? gain - GSTEP : target;
      if ( midi_gain < midi_target )
        midi_gain <= ( midi_target - midi_gain > GSTEP ) ? midi_gain + GSTEP : midi_target;
      else if ( midi_gain > midi_target )
        midi_gain <= ( midi_gain - midi_target > GSTEP ) ? midi_gain - GSTEP : midi_target;
    end
  end
//____________________________________________________________________________//

//------------- Sources                                          -------------//
  wire is_synth  = ( track == 3'd0 );
  wire is_melody = ( track == 3'd1 ) || ( track == 3'd2 );
  wire is_sd     = ( track == 3'd3 ) || ( track == 3'd4 );
  wire is_pc     = ( track == 3'd5 );

  wire [6:0] mel_note;
  wire       mel_gate;

  melody_player #(
    .MEL_FILE   ( MEL_FILE   ),
    .INFO_FILE  ( INFO_FILE  ),
    .UNIT_TICKS ( UNIT_TICKS )
  ) melody_player (
    .clk      ( clk                ),
    .rst_n    ( rst_n              ),
    .tick     ( tick               ),
    .sel      ( track == 3'd2      ),
    .restart  ( restart            ),
    .run      ( active && is_melody ),
    .note     ( mel_note           ),
    .gate     ( mel_gate           ),
    .len_bcd  ( mel_len_bcd        ),
    .progress ( mel_progress       )
  );

  wire signed [15:0] synth_track, synth_midi;

  poly_synth #(
    .SINE_FILE ( SINE_FILE ),
    .NOTE_FILE ( NOTE_FILE )
  ) poly_synth (
    .clk          ( clk                                           ),
    .rst_n        ( rst_n                                         ),
    .tick         ( tick                                          ),
    .params       ( synth_params                                  ),
    .bend         ( bend                                          ),
    .mod_wheel    ( mod_wheel                                     ),
    .v0_note      ( synth_note                                    ),
    .v0_gate      ( play && !switching && is_synth                ),
    .v1_note      ( mel_note                                      ),
    .v1_gate      ( mel_gate && play && !switching && is_melody   ),
    .midi_on      ( midi_on                                       ),
    .midi_off     ( midi_off                                      ),
    .midi_note    ( midi_note                                     ),
    .midi_all_off ( midi_all_off                                  ),
    .track_out    ( synth_track                                   ),
    .midi_out     ( synth_midi                                    ),
    .key_mask     ( key_mask                                      )
  );

  wire signed [15:0] sd_sample, pc_sample;
  wire               sd_underrun, pc_underrun;

  stream_reader sd_reader (
    .clk        ( clk              ),
    .rst_n      ( rst_n            ),
    .tick       ( tick             ),
    .run        ( active && is_sd  ),
    .flush      ( restart          ),
    .step       ( sd_step          ),
    .fifo_empty ( sd_empty         ),
    .fifo_data  ( sd_data          ),
    .fifo_rd    ( sd_rd            ),
    .sample     ( sd_sample        ),
    .underrun   ( sd_underrun      )
  );

  stream_reader pc_reader (
    .clk        ( clk              ),
    .rst_n      ( rst_n            ),
    .tick       ( tick             ),
    .run        ( active && is_pc  ),
    .flush      ( restart          ),
    .step       ( 16'd65527        ),   // the PC always sends 48 kHz
    .fifo_empty ( pc_empty         ),
    .fifo_data  ( pc_data          ),
    .fifo_rd    ( pc_rd            ),
    .sample     ( pc_sample        ),
    .underrun   ( pc_underrun      )
  );
//____________________________________________________________________________//

//------------- Mix, gain, PWM with noise shaping                -------------//
  logic signed [15:0] track_s;
  always_comb begin
    if ( is_sd )       track_s = sd_sample;
    else if ( is_pc )  track_s = pc_sample;
    else               track_s = synth_track;
  end

  // one multiplication per tick for each path, registered stage by stage
  logic signed [32:0] track_mul, midi_mul;
  logic signed [17:0] mix;
  logic signed [15:0] mix_sat;
  logic [ 2:0]        st;          // pipeline steps after tick
  logic [15-PWM_BITS:0] err;
  // unsigned sample + error carried from the previous sample
  wire  [16:0]        shaped = { 1'b0, ~mix_sat[15], mix_sat[14:0] } + 17'( err );

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      st        <= '0;
      track_mul <= '0;
      midi_mul  <= '0;
      mix       <= '0;
      mix_sat   <= '0;
      out_u16   <= 16'h8000;
      duty      <= { 1'b1, { (PWM_BITS-1){1'b0} } };
      err       <= '0;
    end
    else begin
      st <= { st[1:0], tick };
      if ( tick ) begin
        track_mul <= track_s    * $signed( { 1'b0, gain } );
        midi_mul  <= synth_midi * $signed( { 1'b0, midi_gain } );
      end
      if ( st[0] )
        mix <= 18'( track_mul >>> 16 ) + 18'( midi_mul >>> 16 );
      if ( st[1] ) begin
        mix_sat <= ( mix > 18'sd32767 ) ? 16'sd32767 : ( mix < -18'sd32768 ) ? -16'sd32768 : mix[15:0];
      end
      if ( st[2] ) begin
        // take the top PWM_BITS, keep the rest for the next sample
        out_u16 <= { ~mix_sat[15], mix_sat[14:0] };
        if ( shaped[16] ) begin
          duty <= '1;
          err  <= '0;
        end
        else begin
          duty <= shaped[15:16-PWM_BITS];
          err  <= shaped[15-PWM_BITS:0];
        end
      end
    end
  end
//____________________________________________________________________________//

endmodule
