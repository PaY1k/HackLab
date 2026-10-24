// Polyphonic DDS synthesizer, 10 voices, time-multiplexed.
//
//   voice 0      : manual synth (buttons / switches), v0_note + v0_gate
//   voice 1      : melody player, v1_note + v1_gate
//   voices 2..9  : MIDI keyboard, midi_on / midi_off events
//
// Once per sample tick the voices are processed one after another (5 clocks
// each, 50 of the 1024 clocks between ticks), so one sine ROM and one
// multiplier serve all of them.
//
// Each voice: 32-bit phase accumulator (increment from note_inc.mem by MIDI
// note number), waveform (sine / triangle / square / saw), ADSR envelope.
// The envelope makes every start and stop smooth: no clicks on pause or note
// change.
module poly_synth #(
    parameter  SINE_FILE = "sine1024.mem",
    parameter  NOTE_FILE = "note_inc.mem",
    parameter  NV        = 10
)(
    input  wire                clk          ,
    input  wire                rst_n        ,
    input  wire                tick         ,   // one pulse per sample
    input  wire        [ 1:0]  wave_sel     ,   // 0 sine, 1 triangle, 2 square, 3 saw
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

  localparam [16:0] ATT = 17'd512;     // attack  ~2.7 ms
  localparam [15:0] DEC = 16'd16;      // decay   ~27 ms
  localparam [15:0] SUS = 16'd45000;   // sustain ~0.69
  localparam [15:0] REL = 16'd12;      // release ~80 ms

  typedef enum logic [2:0] { OFF, ATTACK, DECAY, SUSTAIN, RELEASE } stage_t;

  logic [31:0] phase [0:NV-1];
  logic [ 6:0] note  [0:NV-1];
  logic [15:0] env   [0:NV-1];
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
//____________________________________________________________________________//

//------------- MIDI event latch                                 -------------//
  // Events come much slower than ticks (one UART packet ~65 us), one slot is enough.
  logic       pend_on, pend_off, pend_all;
  logic [6:0] pend_note;
  logic       ev_take;                       // set by the FSM when events are applied

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
              note[free_v]  <= pend_note;
              stage[free_v] <= ATTACK;
            end
            else begin
              note[steal_v]  <= pend_note;
              stage[steal_v] <= ATTACK;
              steal_v <= ( steal_v == 4'( NV-1 ) ) ? 4'd2 : steal_v + 1'b1;
            end
            pend_on <= 1'b0;
          end
          else if ( pend_off && !midi_off ) begin
            for ( int i = 2; i < NV; i++ )
              if ( note[i] == pend_note && stage[i] != OFF && stage[i] != RELEASE )
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

        S_SINE: begin
          inc_r <= inc_q;
          st    <= S_MUL;
        end

        // sine_q is valid now
        S_MUL: begin
          wave_r   <= shape( wave_sel, phase[v], sine_q );
          phase[v] <= phase[v] + inc_r;
          // envelope step
          case ( stage[v] )
            ATTACK:  if ( 17'( env[v] ) + ATT >= 17'h0FFFF ) begin env[v] <= 16'hFFFF; stage[v] <= DECAY; end
                     else env[v] <= env[v] + ATT[15:0];
            DECAY:   if ( env[v] <= SUS + DEC ) begin env[v] <= SUS; stage[v] <= SUSTAIN; end
                     else env[v] <= env[v] - DEC;
            SUSTAIN: env[v] <= SUS;
            RELEASE: if ( env[v] <= REL ) begin env[v] <= '0; stage[v] <= OFF; end
                     else env[v] <= env[v] - REL;
            default: env[v] <= '0;
          endcase
          st <= S_ACC;
        end

        S_ACC: begin
          prod <= wave_r * $signed( { 1'b0, env[v] } );
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
