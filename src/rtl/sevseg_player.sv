// Seven-segment display of the player (8 digits, left to right):
//
//   [track] [ ] [volume tens] [volume] [ ] [ ] [note] [octave]
//   e.g.  "1 10  C4",  "4  8  F.5"  (the dot after the letter = sharp, F# 5)
//
// The note is the one playing right now (MIDI keyboard, melody or synth),
// "--" when nothing sounds. Letters: A b C d E F G (as on a seven-segment
// display). Octave as in MIDI: note 60 = C4.
//
// Digits are lit one after another (one per clk), segments and anodes are
// active low, like sevseg_ctrl.sv.
module sevseg_player (
    input  wire        clk          ,   // scan clock, ~600 Hz .. 2 kHz
    input  wire        arst_n       ,
    input  wire [2:0]  track        ,   // 0..5, shown as 1..6
    input  wire [3:0]  volume       ,
    input  wire [6:0]  note         ,   // MIDI number
    input  wire        sounding     ,
    output logic [6:0] seg_active_n ,   // {g, f, e, d, c, b, a}
    output logic       dp_n         ,
    output logic [7:0] anodes
);

  // segments, active high, {g, f, e, d, c, b, a}
  localparam [6:0] S_0 = 7'b0111111, S_1 = 7'b0000110, S_2 = 7'b1011011, S_3 = 7'b1001111,
                   S_4 = 7'b1100110, S_5 = 7'b1101101, S_6 = 7'b1111101, S_7 = 7'b0000111,
                   S_8 = 7'b1111111, S_9 = 7'b1101111,
                   S_A = 7'b1110111, S_B = 7'b1111100, S_C = 7'b0111001, S_D = 7'b1011110,
                   S_E = 7'b1111001, S_F = 7'b1110001, S_G = 7'b0111101,
                   S_DASH = 7'b1000000, S_OFF = 7'b0000000;

  function automatic [6:0] digit (input [3:0] d);
    case ( d )
      4'd0: digit = S_0;  4'd1: digit = S_1;  4'd2: digit = S_2;  4'd3: digit = S_3;
      4'd4: digit = S_4;  4'd5: digit = S_5;  4'd6: digit = S_6;  4'd7: digit = S_7;
      4'd8: digit = S_8;  default: digit = S_9;
    endcase
  endfunction

  // MIDI note -> octave (note / 12) and semitone (note % 12)
  logic [3:0] oct12;
  logic [3:0] semi;
  always_comb begin
    if      ( note >= 7'd120 ) oct12 = 4'd10;
    else if ( note >= 7'd108 ) oct12 = 4'd9;
    else if ( note >= 7'd96  ) oct12 = 4'd8;
    else if ( note >= 7'd84  ) oct12 = 4'd7;
    else if ( note >= 7'd72  ) oct12 = 4'd6;
    else if ( note >= 7'd60  ) oct12 = 4'd5;
    else if ( note >= 7'd48  ) oct12 = 4'd4;
    else if ( note >= 7'd36  ) oct12 = 4'd3;
    else if ( note >= 7'd24  ) oct12 = 4'd2;
    else if ( note >= 7'd12  ) oct12 = 4'd1;
    else                       oct12 = 4'd0;
    semi = 4'( note - 7'( oct12 ) * 7'd12 );
  end

  logic [6:0] letter;
  logic       sharp;
  always_comb begin
    sharp = 1'b0;
    case ( semi )
      4'd0:  letter = S_C;
      4'd1:  begin letter = S_C; sharp = 1'b1; end
      4'd2:  letter = S_D;
      4'd3:  begin letter = S_D; sharp = 1'b1; end
      4'd4:  letter = S_E;
      4'd5:  letter = S_F;
      4'd6:  begin letter = S_F; sharp = 1'b1; end
      4'd7:  letter = S_G;
      4'd8:  begin letter = S_G; sharp = 1'b1; end
      4'd9:  letter = S_A;
      4'd10: begin letter = S_A; sharp = 1'b1; end
      default: letter = S_B;
    endcase
  end

  // what each digit shows: index 7 = leftmost
  logic [6:0] seg [0:7];
  logic [7:0] dot;
  always_comb begin
    seg[7] = digit( 4'( track ) + 4'd1 );
    seg[6] = S_OFF;
    seg[5] = ( volume >= 4'd10 ) ? S_1 : S_OFF;
    seg[4] = digit( ( volume >= 4'd10 ) ? volume - 4'd10 : volume );
    seg[3] = S_OFF;
    seg[2] = S_OFF;
    seg[1] = sounding ? letter : S_DASH;
    seg[0] = !sounding    ? S_DASH :
             ( oct12 == 4'd0 ) ? S_DASH :                 // octave -1
             digit( oct12 - 4'd1 );
    dot    = { 6'b0, sounding && sharp, 1'b0 };
  end

  logic [2:0] cnt;
  always_ff @( posedge clk or negedge arst_n ) begin
    if ( !arst_n ) begin
      cnt          <= '0;
      seg_active_n <= '1;
      dp_n         <= 1'b1;
      anodes       <= '1;
    end
    else begin
      seg_active_n <= ~seg[cnt];
      dp_n         <= ~dot[cnt];
      anodes       <= ~( 8'd1 << cnt );
      cnt          <= cnt + 1'b1;
    end
  end

endmodule
