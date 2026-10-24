// Polyphonic DDS synthesizer, 10 voices, time-multiplexed.
//
//   voice 0      : manual synth (buttons / switches), v0_note + v0_gate
//   voice 1      : melody player, v1_note + v1_gate (fixed sound: sine, short envelope)
//   voices 2..9  : MIDI keyboard, midi_on / midi_off events
//
// Once per sample tick the voices are processed one after another (6 clocks
// each, ~60 of the 1024 clocks between ticks), so one sine ROM and one
// multiplier serve all of them.
//
// Voices 0 and 2..9 use the settings (synth_settings.sv): waveform, ADSR
// times, sustain level, vibrato depth (+ mod wheel), MIDI octave shift; pitch
// bend moves them up to +-2 semitones. Each voice: 32-bit phase accumulator,
// increment from note_inc.mem by MIDI note number, 24-bit envelope.
module poly_synth #(
    parameter  SINE_FILE = "sine1024.mem",
    parameter  NOTE_FILE = "note_inc.mem",
    parameter  NV        = 10
)(
    input  wire                clk          ,
    input  wire                rst_n        ,
    input  wire                tick         ,   // one pulse per sample
  //--------- Settings                          --------//
    input  wire        [31:0]  params       ,   // synth_settings.sv
    input  wire signed [13:0]  bend         ,   // -8192..8191 = -2..+2 semitones
    input  wire        [ 6:0]  mod_wheel    ,   // 0..127, adds vibrato
  //--------- Voice 0: manual                   --------//
    input  wire        [ 6:0]  v0_note      ,
    input  wire                v0_gate      ,
  //--------- Voice 1: melody                   --------//
    input  wire        [ 6:0]  v1_note      ,   // 0 = rest
    input  wire                v1_gate      ,
  //--------- MIDI voices                       --------//
    input  wire                midi_on      ,   // pulse
    input  wire                midi_off     ,   // pulse
    input  wire        [ 6:0]  midi_note    ,
    input  wire                midi_all_off ,   // pulse: release every MIDI voice
  //--------- Output                            --------//
    output logic signed [15:0] track_out    ,   // voices 0 + 1
    output logic signed [15:0] midi_out     ,   // MIDI voices, mixed with headroom
    output logic       [35:0]  key_mask         // sounding notes C3 (48) .. B5 (83)
);

  wire [1:0] p_wave = params[1:0];
  wire [3:0] p_att  = params[7:4];
  wire [3:0] p_dec  = params[11:8];
  wire [3:0] p_sus  = params[15:12];
  wire [3:0] p_rel  = params[19:16];
  wire [3:0] p_vib  = params[23:20];
  wire [2:0] p_oct  = params[26:24];

  typedef enum logic [2:0] { OFF, ATTACK, DECAY, SUSTAIN, RELEASE } stage_t;

  logic [31:0] phase [0:NV-1];
  logic [ 6:0] note  [0:NV-1];
  logic [23:0] env   [0:NV-1];         // 16.8 fixed point
  stage_t      stage [0:NV-1];

//------------- ROMs                                             -------------//
  logic signed [15:0] sine_mem [0:1023];
  logic        [31:0] inc_mem  [0:127];
  initial begin
    $readmemh( SINE_FILE, sine_mem );
    $readmemh( NOTE_FILE, inc_mem );
  end

  logic [ 9:0]        sine_addr;
  logic signed [15:0] sine_q;
  logic [ 6:0]        inc_addr;
  logic [31:0]        inc_q;
  always_ff @( posedge clk ) begin
    sine_q <= sine_mem[sine_addr];
    inc_q  <= inc_mem[inc_addr];
  end
//____________________________________________________________________________//

//------------- Helpers                                          -------------//
  function automatic logic signed [15:0] shape (input [1:0] sel, input [31:0] p, input signed [15:0] s);
    logic [14:0] t;
    t = p[31] ? ~p[30:16] : p[30:16];
    case ( sel )
      2'd0:    shape = s;                                              // sine
      2'd1:    shape = { ~t[14], t[13:0], 1'b0 };                       // triangle
      2'd2:    shape = p[31] ? -16'sd12000 : 16'sd12000;                // square (quieter)
      default: shape = { ~p[31], ~p[31], p[30:17] };                    // saw, half amplitude
    endcase
  endfunction

  function automatic logic signed [15:0] sat16 (input signed [19:0] x);
    if ( x > 20'sd32767 )        sat16 = 16'sd32767;
    else if ( x < -20'sd32768 )  sat16 = -16'sd32768;
    else                         sat16 = x[15:0];
  endfunction

  // envelope step per tick for a full swing in 0, 2, 5, 10, 20, 40, 70, 100,
  // 150, 200, 300, 450, 600, 800, 1200, 2000 ms (16.8 fixed point)
  function automatic [23:0] rate (input [3:0] t);
    case ( t )
      4'd0:  rate = 24'd16777215;  4'd1:  rate = 24'd174736;  4'd2:  rate = 24'd69895;
      4'd3:  rate = 24'd34947;     4'd4:  rate = 24'd17474;   4'd5:  rate = 24'd8737;
      4'd6:  rate = 24'd4992;      4'd7:  rate = 24'd3495;    4'd8:  rate = 24'd2330;
      4'd9:  rate = 24'd1747;      4'd10: rate = 24'd1165;    4'd11: rate = 24'd777;
      4'd12: rate = 24'd582;       4'd13: rate = 24'd437;     4'd14: rate = 24'd291;
      default: rate = 24'd175;
    endcase
  endfunction
//____________________________________________________________________________//

//------------- Vibrato LFO, 5.5 Hz triangle                     -------------//
  logic [31:0] lfo;
  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n )   lfo <= '0;
    else if ( tick ) lfo <= lfo + 32'd492062;          // 5.5 Hz * 2^32 / 48006.5
  end
  wire [9:0]         lfo_t   = lfo[31] ? ~lfo[30:21] : lfo[30:21];   // 0..1023..0
  wire [5:0]         depth   = { 2'b0, p_vib } + { 2'b0, mod_wheel[6:3] } + ( mod_wheel[6:3] != 0 ? 6'd2 : 6'd0 );
  // pitch factor: +-8192 = +-12.5 % (about 2 semitones), vibrato up to ~+-0.5 semitone
  wire signed [16:0] vib     = ( $signed( { 1'b0, lfo_t } ) - 17'sd512 ) * $signed( { 1'b0, depth } ) >>> 3;
  wire signed [16:0] pfactor = 17'( bend ) + vib;
//____________________________________________________________________________//

//------------- MIDI event latch                                 -------------//
  // Events come much slower than ticks (one UART line > 0.3 ms), one slot is enough.
  logic       pend_on, pend_off, pend_all;
  logic [6:0] pend_note;

  // MIDI octave shift, clamped to 0..127
  wire  [7:0] shifted  = { 1'b0, pend_note } + 8'd12 * { 5'd0, p_oct } - 8'd24;
  wire  [6:0] on_note  = ( { 1'b0, pend_note } + 8'd12 * { 5'd0, p_oct } < 8'd24 ) ? 7'd0
                       : ( shifted > 8'd127 ) ? 7'd127 : shifted[6:0];

//------------- Free voice search (MIDI voices only)            -------------//
  logic [3:0] free_v;
  logic       free_found;
  logic [3:0] steal_v;                       // round-robin victim when all are busy
  always_comb begin
    free_found = 1'b0;
    free_v     = 4'd2;
    for ( int i = NV-1; i >= 2; i-- )
      if ( stage[i] == OFF ) begin
        free_found = 1'b1;
        free_v     = 4'( i );
      end
  end
//____________________________________________________________________________//

//------------- Voice processing FSM                             -------------//
  typedef enum logic [2:0] { S_IDLE, S_EVENTS, S_INC, S_SINE, S_MUL, S_ACC, S_DONE } fsm_t;
  fsm_t        st;
  logic [3:0]  v;
  logic        g0_prev, g1_prev;
  logic [6:0]  n1_prev;
  logic [31:0] inc_r;
  logic signed [15:0] wave_r;
  logic signed [32:0] prod;
  logic signed [19:0] acc_track, acc_midi;

  // settings of the current voice: the melody voice keeps a fixed sound
  wire        fixed = ( v == 4'd1 );
  wire [1:0]  v_wave = fixed ? 2'd0 : p_wave;
  wire [23:0] v_att  = rate( fixed ? 4'd1 : p_att );
  wire [23:0] v_dec  = rate( fixed ? 4'd5 : p_dec );
  wire [23:0] v_rel  = rate( fixed ? 4'd6 : p_rel );
  wire [23:0] v_sus  = { ( fixed ? 4'd11 : p_sus ) * 16'd4369, 8'd0 };

  // increment with bend and vibrato: inc + inc * pfactor / 65536
  wire signed [49:0] inc_mod = $signed( { 1'b0, inc_q } ) * pfactor;
  wire        [31:0] inc_bent = inc_q + 32'( inc_mod >>> 16 );

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      st        <= S_IDLE;
      v         <= '0;
      g0_prev   <= 1'b0;
      g1_prev   <= 1'b0;
      n1_prev   <= '0;
      steal_v   <= 4'd2;
      pend_on   <= 1'b0;
      pend_off  <= 1'b0;
      pend_all  <= 1'b0;
      pend_note <= '0;
      track_out <= '0;
      midi_out  <= '0;
      acc_track <= '0;
      acc_midi  <= '0;
      sine_addr <= '0;
      inc_addr  <= '0;
      inc_r     <= '0;
      wave_r    <= '0;
      prod      <= '0;
      for ( int i = 0; i < NV; i++ ) begin
        phase[i] <= '0;
        note[i]  <= 7'd60;
        env[i]   <= '0;
        stage[i] <= OFF;
      end
    end
    else begin
      // latch MIDI events (a new event overwrites an unprocessed one of the same kind)
      if ( midi_on )      begin pend_on  <= 1'b1; pend_note <= midi_note; end
      if ( midi_off )     begin pend_off <= 1'b1; if ( !midi_on ) pend_note <= midi_note; end
      if ( midi_all_off ) pend_all <= 1'b1;

      case ( st )
        S_IDLE: if ( tick ) st <= S_EVENTS;

        // gates of voices 0/1 and MIDI events, once per tick
        S_EVENTS: begin
          // voice 0: manual
          note[0] <= v0_note;
          if ( v0_gate && !g0_prev )       stage[0] <= ATTACK;
          else if ( !v0_gate && g0_prev )  stage[0] <= RELEASE;
          g0_prev <= v0_gate;
          // voice 1: melody, every new note is attacked again
          if ( v1_note != 7'd0 ) note[1] <= v1_note;
          if ( v1_gate && ( !g1_prev || v1_note != n1_prev ) )  stage[1] <= ATTACK;
          else if ( !v1_gate && g1_prev )                      stage[1] <= RELEASE;
          g1_prev <= v1_gate;
          n1_prev <= v1_note;
          // MIDI
          if ( pend_all ) begin
            for ( int i = 2; i < NV; i++ )
              if ( stage[i] != OFF ) stage[i] <= RELEASE;
            pend_all <= 1'b0;
            pend_on  <= 1'b0;
            pend_off <= 1'b0;
          end
          else if ( pend_on && !midi_on ) begin
            if ( free_found ) begin
              note[free_v]  <= on_note;
              stage[free_v] <= ATTACK;
            end
            else begin
              note[steal_v]  <= on_note;
              stage[steal_v] <= ATTACK;
              steal_v <= ( steal_v == 4'( NV-1 ) ) ? 4'd2 : steal_v + 1'b1;
            end
            pend_on <= 1'b0;
          end
          else if ( pend_off && !midi_off ) begin
            for ( int i = 2; i < NV; i++ )
              if ( note[i] == on_note && stage[i] != OFF && stage[i] != RELEASE )
                stage[i] <= RELEASE;
            pend_off <= 1'b0;
          end
          v         <= '0;
          acc_track <= '0;
          acc_midi  <= '0;
          inc_addr  <= v0_note;
          st        <= S_INC;
        end

        // inc_addr was set one clock ago -> wait for the ROM
        S_INC: begin
          sine_addr <= phase[v][31:22];
          st        <= S_SINE;
        end

        // increment with pitch bend and vibrato (not for the melody voice)
        S_SINE: begin
          inc_r <= fixed ? inc_q : inc_bent;
          st    <= S_MUL;
        end

        // sine_q is valid now
        S_MUL: begin
          wave_r   <= shape( v_wave, phase[v], sine_q );
          phase[v] <= phase[v] + inc_r;
          // envelope step
          case ( stage[v] )
            ATTACK:  if ( 25'( env[v] ) + 25'( v_att ) >= 25'h0FFFFFF ) begin env[v] <= 24'hFFFFFF; stage[v] <= DECAY; end
                     else env[v] <= env[v] + v_att;
            DECAY:   if ( 25'( env[v] ) <= 25'( v_sus ) + 25'( v_dec ) ) begin env[v] <= v_sus; stage[v] <= SUSTAIN; end
                     else env[v] <= env[v] - v_dec;
            SUSTAIN: env[v] <= v_sus;
            RELEASE: if ( env[v] <= v_rel ) begin env[v] <= '0; stage[v] <= OFF; end
                     else env[v] <= env[v] - v_rel;
            default: env[v] <= '0;
          endcase
          st <= S_ACC;
        end

        S_ACC: begin
          prod <= wave_r * $signed( { 1'b0, env[v][23:8] } );
          st   <= S_DONE;
        end

        S_DONE: begin
          if ( v < 4'd2 ) acc_track <= acc_track + 20'( prod >>> 16 );
          else            acc_midi  <= acc_midi  + 20'( prod >>> 16 );
          if ( v == 4'( NV-1 ) ) begin
            st <= S_IDLE;
          end
          else begin
            v        <= v + 1'b1;
            inc_addr <= note[v + 1'b1];
            st       <= S_INC;
          end
        end

        default: st <= S_IDLE;
      endcase

      // outputs are updated once all voices are summed
      if ( st == S_IDLE && tick ) begin
        track_out <= sat16( acc_track );
        midi_out  <= sat16( acc_midi >>> 2 );
      end
    end
  end
//____________________________________________________________________________//

//------------- Piano keys                                       -------------//
  always_comb begin
    key_mask = '0;
    for ( int i = 0; i < NV; i++ )
      if ( ( stage[i] == ATTACK || stage[i] == DECAY || stage[i] == SUSTAIN ) &&
           note[i] >= 7'd48 && note[i] <= 7'd83 )
        key_mask[note[i] - 7'd48] = 1'b1;
  end
//____________________________________________________________________________//

endmodule
