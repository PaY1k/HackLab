// Text commands from the PC over UART -> notes and synth settings.
//
// One command per line (end: \n, \r or ;). Case does not matter, extra
// spaces are fine, unknown lines are ignored. Notes are MIDI numbers (60 = C4).
//
//   ON 60 100          note on, velocity 100 (velocity 0 = off)
//   ON 60              note on
//   OFF 60             note off
//   OFF / STOP / PANIC / ALLOFF        all notes off
//   60 100  /  60 0    bare numbers: note + velocity
//   note_on channel=0 note=60 velocity=100 time=0      (str(msg) in mido)
//   note_off channel=0 note=60 velocity=64 time=0
//   BEND -4096         pitch bend -8192..8191 (+-2 semitones), BEND 0 = middle
//   pitchwheel channel=0 pitch=-4096 time=0             (mido)
//   CC 1 64            mod wheel (vibrato); CC 7 v = MIDI volume; CC 120/123 = all off
//   control_change channel=0 control=1 value=64         (mido)
//   SET ATTACK 5       synth setting (synth_settings.sv), also without SET:
//   ATTACK 5 / DECAY 3 / SUSTAIN 12 / RELEASE 8 / VIBRATO 4 / OCTAVE 3 / MVOL 10
//   WAVE SAW / WAVE SINE / WAVE TRI / WAVE SQUARE / WAVE 2
//   SET 1 5            setting by number 0..7
module midi_text_rx (
    input  wire               clk          ,
    input  wire               rst_n        ,
    input  wire        [7:0]  rx_data      ,   // from uart_rx
    input  wire               rx_valid     ,
  //--------- Notes                              --------//
    output logic              midi_on      ,   // one-clock pulses
    output logic              midi_off     ,
    output logic       [6:0]  midi_note    ,
    output logic              midi_all_off ,
  //--------- Controllers (levels)               --------//
    output logic signed [13:0] bend        ,   // -8192..8191
    output logic       [6:0]  mod_wheel    ,
  //--------- Settings                           --------//
    output logic              set_valid    ,   // pulse
    output logic       [2:0]  set_idx      ,
    output logic       [3:0]  set_val      ,
  //--------- Debug                              --------//
    output logic              cmd_ok           // pulse: a line was understood
);

  typedef enum logic [2:0] { C_NONE, C_ON, C_OFF, C_CC, C_BEND, C_SET } cmd_t;
  typedef enum logic [1:0] { K_NONE, K_A, K_B, K_SKIP } key_t;     // A: note/control/pitch, B: velocity/value

  cmd_t         cmd;
  key_t         key;
  logic [127:0] word;               // up to 16 letters, newest in the low byte
  logic         in_word;
  logic [13:0]  num;                // magnitude of the number being read
  logic         neg;                // '-' before it
  logic         in_num;
  logic signed [15:0] a, b;         // the two values of the line
  logic         have_a, have_b;
  logic [2:0]   sidx;               // setting chosen by a word
  logic         have_sidx;
  logic         all_req;

  // classify the next character
  wire [7:0] c      = ( rx_data >= "A" && rx_data <= "Z" ) ? rx_data + 8'd32 : rx_data;   // lower case
  wire       is_let = ( c >= "a" && c <= "z" ) || ( c == "_" );
  wire       is_dig = ( rx_data >= "0" && rx_data <= "9" );
  wire       is_eol = ( rx_data == 8'h0A ) || ( rx_data == 8'h0D ) || ( rx_data == ";" );

  wire signed [15:0] num_s = neg ? -$signed( { 2'b0, num } ) : $signed( { 2'b0, num } );

//------------- Word meaning                                     -------------//
  // {kind, value}: kind 0 nothing, 1 command, 2 key, 3 setting name, 4 wave name
  //   command: 1 on, 2 off, 3 cc, 4 bend, 5 set, 6 all off
  //   key:     1 A, 2 B, 3 skip
  function automatic [5:0] word_kind (input [127:0] w);
    word_kind = 6'd0;
    if      ( w == "on" || w == "note_on" || w == "noteon" )                    word_kind = { 3'd1, 3'd1 };
    else if ( w == "off" || w == "note_off" || w == "noteoff" )                 word_kind = { 3'd1, 3'd2 };
    else if ( w == "control_change" || w == "cc" )                              word_kind = { 3'd1, 3'd3 };
    else if ( w == "bend" || w == "pitchwheel" || w == "pb" )                   word_kind = { 3'd1, 3'd4 };
    else if ( w == "set" )                                                      word_kind = { 3'd1, 3'd5 };
    else if ( w == "alloff" || w == "all_off" || w == "panic" || w == "stop" )  word_kind = { 3'd1, 3'd6 };
    else if ( w == "note" || w == "n" || w == "control" || w == "pitch" )       word_kind = { 3'd2, 3'd1 };
    else if ( w == "velocity" || w == "vel" || w == "v" || w == "value" )      word_kind = { 3'd2, 3'd2 };
    else if ( w == "channel" || w == "ch" || w == "time" )                      word_kind = { 3'd2, 3'd3 };
    else if ( w == "wave" || w == "waveform" )                                  word_kind = { 3'd3, 3'd0 };
    else if ( w == "attack" || w == "att" || w == "a" )                         word_kind = { 3'd3, 3'd1 };
    else if ( w == "decay" || w == "dec" || w == "d" )                          word_kind = { 3'd3, 3'd2 };
    else if ( w == "sustain" || w == "sus" || w == "s" )                        word_kind = { 3'd3, 3'd3 };
    else if ( w == "release" || w == "rel" || w == "r" )                        word_kind = { 3'd3, 3'd4 };
    else if ( w == "vibrato" || w == "vib" )                                    word_kind = { 3'd3, 3'd5 };
    else if ( w == "octave" || w == "oct" )                                     word_kind = { 3'd3, 3'd6 };
    else if ( w == "mvol" || w == "midivol" || w == "volume" )                  word_kind = { 3'd3, 3'd7 };
    else if ( w == "sine" || w == "sin" )                                       word_kind = { 3'd4, 3'd0 };
    else if ( w == "triangle" || w == "tri" )                                   word_kind = { 3'd4, 3'd1 };
    else if ( w == "square" || w == "sq" )                                      word_kind = { 3'd4, 3'd2 };
    else if ( w == "saw" )                                                      word_kind = { 3'd4, 3'd3 };
  endfunction

  function automatic cmd_t to_cmd (input [2:0] k);
    case ( k )
      3'd1:    to_cmd = C_ON;
      3'd2, 3'd6: to_cmd = C_OFF;
      3'd3:    to_cmd = C_CC;
      3'd4:    to_cmd = C_BEND;
      default: to_cmd = C_SET;
    endcase
  endfunction

  wire [5:0] wk = word_kind( word );

//------------- Values at the end of the line                    -------------//
  // everything a word or a number that ends right at the EOL character adds
  cmd_t              f_cmd;
  logic signed [15:0] f_a, f_b;
  logic              f_have_a, f_have_b, f_all, f_have_sidx;
  logic [2:0]        f_sidx;

  always_comb begin
    f_cmd       = cmd;
    f_a         = a;
    f_b         = b;
    f_have_a    = have_a;
    f_have_b    = have_b;
    f_all       = all_req;
    f_sidx      = sidx;
    f_have_sidx = have_sidx;
    if ( in_word ) begin
      case ( wk[5:3] )
        3'd1: begin f_cmd = to_cmd( wk[2:0] ); if ( wk[2:0] == 3'd6 ) f_all = 1'b1; end
        3'd3: begin f_sidx = wk[2:0]; f_have_sidx = 1'b1; if ( cmd == C_NONE ) f_cmd = C_SET; end
        3'd4: if ( !have_a ) begin f_a = { 13'd0, wk[2:0] }; f_have_a = 1'b1; end
        default: ;
      endcase
    end
    if ( in_num ) begin
      if ( key == K_A || ( key == K_NONE && !have_a ) )      begin f_a = num_s; f_have_a = 1'b1; end
      else if ( key == K_B || ( key == K_NONE && !have_b ) ) begin f_b = num_s; f_have_b = 1'b1; end
    end
  end

  function automatic [6:0] clamp7 (input signed [15:0] x);
    clamp7 = ( x < 0 ) ? 7'd0 : ( x > 127 ) ? 7'd127 : x[6:0];
  endfunction
  function automatic [3:0] clamp4 (input signed [15:0] x);
    clamp4 = ( x < 0 ) ? 4'd0 : ( x > 15 ) ? 4'd15 : x[3:0];
  endfunction
  function automatic signed [13:0] clamp14 (input signed [15:0] x);
    clamp14 = ( x < -16'sd8192 ) ? -14'sd8192 : ( x > 16'sd8191 ) ? 14'sd8191 : x[13:0];
  endfunction

  wire note_ok = f_have_a && f_a >= 0 && f_a <= 127;
//____________________________________________________________________________//

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      cmd          <= C_NONE;
      key          <= K_NONE;
      word         <= '0;
      in_word      <= 1'b0;
      num          <= '0;
      neg          <= 1'b0;
      in_num       <= 1'b0;
      a            <= '0;
      b            <= '0;
      have_a       <= 1'b0;
      have_b       <= 1'b0;
      sidx         <= '0;
      have_sidx    <= 1'b0;
      all_req      <= 1'b0;
      midi_on      <= 1'b0;
      midi_off     <= 1'b0;
      midi_note    <= '0;
      midi_all_off <= 1'b0;
      bend         <= '0;
      mod_wheel    <= '0;
      set_valid    <= 1'b0;
      set_idx      <= '0;
      set_val      <= '0;
      cmd_ok       <= 1'b0;
    end
    else begin
      midi_on      <= 1'b0;
      midi_off     <= 1'b0;
      midi_all_off <= 1'b0;
      set_valid    <= 1'b0;
      cmd_ok       <= 1'b0;

      if ( rx_valid && is_eol ) begin
        //------- act on the line
        if ( f_all ) begin
          midi_all_off <= 1'b1;
          cmd_ok       <= 1'b1;
        end
        else case ( f_cmd )
          C_ON, C_NONE: if ( note_ok ) begin
            midi_note <= f_a[6:0];
            if ( f_have_b && f_b == 0 ) midi_off <= 1'b1;
            else                        midi_on  <= 1'b1;
            cmd_ok <= 1'b1;
          end
          C_OFF: begin
            if ( note_ok ) begin midi_note <= f_a[6:0]; midi_off <= 1'b1; end
            else if ( !f_have_a ) midi_all_off <= 1'b1;
            cmd_ok <= 1'b1;
          end
          C_CC: if ( f_have_a ) begin
            cmd_ok <= 1'b1;
            if ( f_a == 16'sd1 )                          mod_wheel <= clamp7( f_b );
            else if ( f_a == 16'sd7 ) begin               set_valid <= 1'b1; set_idx <= 3'd7; set_val <= clamp7( f_b ) >> 3; end
            else if ( f_a == 16'sd120 || f_a == 16'sd123 ) midi_all_off <= 1'b1;
            else                                          cmd_ok <= 1'b0;
          end
          C_BEND: if ( f_have_a ) begin
            bend   <= clamp14( f_a );
            cmd_ok <= 1'b1;
          end
          C_SET: begin
            // "SET ATTACK 5" -> name + value; "SET 1 5" -> number + value; "ATTACK 5", "WAVE SAW"
            if ( f_have_sidx && f_have_a ) begin
              set_valid <= 1'b1; set_idx <= f_sidx; set_val <= clamp4( f_a ); cmd_ok <= 1'b1;
            end
            else if ( !f_have_sidx && f_have_a && f_have_b ) begin
              set_valid <= 1'b1; set_idx <= f_a[2:0]; set_val <= clamp4( f_b ); cmd_ok <= 1'b1;
            end
          end
          default: ;
        endcase
        //------- new line
        cmd       <= C_NONE;
        key       <= K_NONE;
        in_word   <= 1'b0;
        in_num    <= 1'b0;
        neg       <= 1'b0;
        have_a    <= 1'b0;
        have_b    <= 1'b0;
        have_sidx <= 1'b0;
        all_req   <= 1'b0;
      end
      else if ( rx_valid ) begin
        //------- words
        if ( is_let ) begin
          word    <= in_word ? { word[119:0], c } : { 120'd0, c };
          in_word <= 1'b1;
        end
        else if ( in_word ) begin
          in_word <= 1'b0;
          case ( wk[5:3] )
            3'd1: begin cmd <= to_cmd( wk[2:0] ); if ( wk[2:0] == 3'd6 ) all_req <= 1'b1; end
            3'd2: if ( wk[2:0] == 3'd1 ) key <= K_A; else if ( wk[2:0] == 3'd2 ) key <= K_B; else key <= K_SKIP;
            3'd3: begin sidx <= wk[2:0]; have_sidx <= 1'b1; if ( cmd == C_NONE ) cmd <= C_SET; end
            3'd4: if ( !have_a ) begin a <= { 13'd0, wk[2:0] }; have_a <= 1'b1; end
            default: ;
          endcase
        end

        //------- numbers (a digit right after letters, like "v100", starts a number too)
        if ( is_dig ) begin
          num    <= in_num ? ( ( num > 14'd9000 ) ? num : num * 14'd10 + 14'( rx_data - "0" ) ) : 14'( rx_data - "0" );
          in_num <= 1'b1;
        end
        else begin
          if ( in_num ) begin
            in_num <= 1'b0;
            neg    <= 1'b0;
            if ( key == K_A || ( key == K_NONE && !have_a ) )      begin a <= num_s; have_a <= 1'b1; end
            else if ( key == K_B || ( key == K_NONE && !have_b ) ) begin b <= num_s; have_b <= 1'b1; end
            key <= K_NONE;
          end
          neg <= ( rx_data == "-" );
        end
      end
    end
  end

endmodule
