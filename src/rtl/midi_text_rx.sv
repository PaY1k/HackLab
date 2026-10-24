// Text MIDI commands from the PC over UART -> note on / note off pulses.
//
// One command per line (end: \n, \r or ;). Case does not matter. Understood:
//
//   ON 60 100          note 60 on, velocity 100   (velocity 0 = off)
//   ON 60              note 60 on
//   OFF 60             note 60 off
//   OFF                all notes off
//   60 100  /  60 0    bare numbers: note + velocity (0 = off)
//   note_on channel=0 note=60 velocity=100 time=0      (str(msg) in mido)
//   note_off channel=0 note=60 velocity=64 time=0
//   control_change channel=0 control=123 value=0       (all notes off)
//   NOTE_ON / NOTEON / NOTE_OFF / NOTEOFF, ALLOFF / ALL_OFF / PANIC / STOP
//
// Unknown words are ignored, so "note_on ch=1 n=60 v=100" style also works
// when the numbers are in order note, velocity. Note numbers are MIDI: 60 = C4.
module midi_text_rx (
    input  wire        clk          ,
    input  wire        rst_n        ,
    input  wire [7:0]  rx_data      ,   // from uart_rx
    input  wire        rx_valid     ,
    output logic       midi_on      ,   // one-clock pulses
    output logic       midi_off     ,
    output logic [6:0] midi_note    ,
    output logic       midi_all_off ,
    output logic       cmd_ok           // pulse: a line was understood (for an LED)
);

  typedef enum logic [1:0] { C_NONE, C_ON, C_OFF, C_CC } cmd_t;
  typedef enum logic [2:0] { K_NONE, K_NOTE, K_VEL, K_CTRL, K_SKIP } key_t;

  cmd_t         cmd;
  key_t         key;
  logic [127:0] word;               // up to 16 letters, newest in the low byte
  logic         in_word;
  logic [11:0]  num;
  logic         in_num;
  logic [7:0]   note, vel, ctrl;
  logic         have_note, have_vel;

  // classify the next character
  wire [7:0] c      = ( rx_data >= "A" && rx_data <= "Z" ) ? rx_data + 8'd32 : rx_data;   // lower case
  wire       is_let = ( c >= "a" && c <= "z" ) || ( c == "_" );
  wire       is_dig = ( rx_data >= "0" && rx_data <= "9" );
  wire       is_eol = ( rx_data == 8'h0A ) || ( rx_data == 8'h0D ) || ( rx_data == ";" );

  // value of a finished number (clamped to 127 for notes)
  wire [7:0] num8 = ( num > 12'd255 ) ? 8'd255 : num[7:0];

  // what a word means: 0 nothing, 1 on, 2 off, 3 control change, 4 all notes off
  function automatic [2:0] word_cmd (input [127:0] w);
    if      ( w == "on" || w == "note_on" || w == "noteon" )                    word_cmd = 3'd1;
    else if ( w == "off" || w == "note_off" || w == "noteoff" )                 word_cmd = 3'd2;
    else if ( w == "control_change" || w == "cc" )                              word_cmd = 3'd3;
    else if ( w == "alloff" || w == "all_off" || w == "panic" || w == "stop" )  word_cmd = 3'd4;
    else                                                                        word_cmd = 3'd0;
  endfunction

  // a finished word changes the command or the key of the next number
  task automatic take_word ();
    case ( word_cmd( word ) )
      3'd1: cmd <= C_ON;
      3'd2: cmd <= C_OFF;
      3'd3: cmd <= C_CC;
      3'd4: begin cmd <= C_OFF; have_note <= 1'b0; end
      default: ;
    endcase
    if      ( word == "note" || word == "n" )                         key <= K_NOTE;
    else if ( word == "velocity" || word == "vel" || word == "v" )    key <= K_VEL;
    else if ( word == "control" )                                     key <= K_CTRL;
    else if ( word == "channel" || word == "ch" || word == "time" || word == "value" ) key <= K_SKIP;
  endtask

  // a finished number goes to its key, or by position: note first, velocity second
  task automatic take_num ();
    case ( key )
      K_NOTE: begin note <= num8; have_note <= 1'b1; end
      K_VEL:  begin vel  <= num8; have_vel  <= 1'b1; end
      K_CTRL: ctrl <= num8;
      K_SKIP: ;
      default: begin
        if ( !have_note )     begin note <= num8; have_note <= 1'b1; end
        else if ( !have_vel ) begin vel  <= num8; have_vel  <= 1'b1; end
      end
    endcase
    key <= K_NONE;
  endtask

  // values at the end of the line, including a number that ends right at EOL
  logic [7:0] f_note, f_vel;
  logic       f_have_note, f_have_vel;
  always_comb begin
    f_note      = note;
    f_vel       = vel;
    f_have_note = have_note;
    f_have_vel  = have_vel;
    if ( in_num ) begin
      case ( key )
        K_NOTE:  begin f_note = num8; f_have_note = 1'b1; end
        K_VEL:   begin f_vel  = num8; f_have_vel  = 1'b1; end
        K_CTRL, K_SKIP: ;
        default: if ( !have_note ) begin f_note = num8; f_have_note = 1'b1; end
                 else if ( !have_vel ) begin f_vel = num8; f_have_vel = 1'b1; end
      endcase
    end
  end
  wire [7:0] f_ctrl = ( in_num && key == K_CTRL ) ? num8 : ctrl;

  // command at the end of the line, including a word that ends right at EOL ("OFF\n")
  wire [2:0] eol_w = in_word ? word_cmd( word ) : 3'd0;
  cmd_t      f_cmd;
  always_comb begin
    case ( eol_w )
      3'd1:    f_cmd = C_ON;
      3'd2:    f_cmd = C_OFF;
      3'd3:    f_cmd = C_CC;
      3'd4:    f_cmd = C_OFF;
      default: f_cmd = cmd;
    endcase
  end
  wire f_all = ( eol_w == 3'd4 );

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      cmd          <= C_NONE;
      key          <= K_NONE;
      word         <= '0;
      in_word      <= 1'b0;
      num          <= '0;
      in_num       <= 1'b0;
      note         <= '0;
      vel          <= '0;
      ctrl         <= '0;
      have_note    <= 1'b0;
      have_vel     <= 1'b0;
      midi_on      <= 1'b0;
      midi_off     <= 1'b0;
      midi_note    <= '0;
      midi_all_off <= 1'b0;
      cmd_ok       <= 1'b0;
    end
    else begin
      midi_on      <= 1'b0;
      midi_off     <= 1'b0;
      midi_all_off <= 1'b0;
      cmd_ok       <= 1'b0;

      if ( rx_valid ) begin
        // words
        if ( is_let ) begin
          word    <= in_word ? { word[119:0], c } : { 120'd0, c };
          in_word <= 1'b1;
        end
        else if ( in_word ) begin
          in_word <= 1'b0;
          take_word();
        end

        // numbers (a digit right after letters, like "v100", starts a number too)
        if ( is_dig ) begin
          num    <= in_num ? ( ( num > 12'd255 ) ? num : num * 12'd10 + 12'( rx_data - "0" ) ) : 12'( rx_data - "0" );
          in_num <= 1'b1;
        end
        else if ( in_num ) begin
          in_num <= 1'b0;
          if ( !is_eol ) take_num();
        end

        // end of line: act
        if ( is_eol ) begin
          if ( f_all ) begin
            midi_all_off <= 1'b1;
            cmd_ok       <= 1'b1;
          end
          else if ( f_have_note && f_note <= 8'd127 &&
               ( f_cmd == C_ON || f_cmd == C_NONE ) && !( f_have_vel && f_vel == 8'd0 ) ) begin
            midi_on   <= 1'b1;
            midi_note <= f_note[6:0];
            cmd_ok    <= 1'b1;
          end
          else if ( f_have_note && f_note <= 8'd127 && f_cmd != C_CC ) begin
            midi_off  <= 1'b1;
            midi_note <= f_note[6:0];
            cmd_ok    <= 1'b1;
          end
          else if ( ( f_cmd == C_OFF && !f_have_note ) ||
                    ( f_cmd == C_CC && ( f_ctrl == 8'd123 || f_ctrl == 8'd120 ) ) ) begin
            midi_all_off <= 1'b1;
            cmd_ok       <= 1'b1;
          end
          // new line
          cmd       <= C_NONE;
          key       <= K_NONE;
          in_word   <= 1'b0;
          in_num    <= 1'b0;
          have_note <= 1'b0;
          have_vel  <= 1'b0;
          ctrl      <= '0;
        end
      end
    end
  end

endmodule
