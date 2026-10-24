// Synth settings for the MIDI keyboard (and the manual synth on track 01).
//
//   #  name        values                 default
//   0  wave        0 sine, 1 triangle, 2 square, 3 saw     0
//   1  attack      0..15  (0 ms .. 2 s)                    1
//   2  decay       0..15                                   5
//   3  sustain     0..15  (level 0 .. 100 %)              11
//   4  release     0..15                                   6
//   5  vibrato     0..15  (depth, + mod wheel)             0
//   6  octave      0..4   (MIDI notes shifted -2..+2)      2
//   7  midi volume 0..15                                  15
//
// Board: SW14 on = menu on the screen, BTNU/BTND choose, BTNL/BTNR change.
// PC:    "SET ATTACK 5", "WAVE SAW", "SET 1 5" ... (midi_text_rx.sv).
module synth_settings (
    input  wire        clk       ,
    input  wire        rst_n     ,
    input  wire        menu_mode ,
    input  wire        btn_u     ,
    input  wire        btn_d     ,
    input  wire        btn_l     ,
    input  wire        btn_r     ,
    input  wire        set_valid ,   // from the PC
    input  wire [2:0]  set_idx   ,
    input  wire [3:0]  set_val   ,
    output logic [2:0] sel       ,
    output wire [31:0] params        // parameter i = params[4*i +: 4]
);

  logic [3:0] p [0:7];
  generate
    for ( genvar i = 0; i < 8; i++ ) begin : g_out
      assign params[4*i +: 4] = p[i];
    end
  endgenerate

  function automatic [3:0] pmax (input [2:0] i);
    case ( i )
      3'd0:    pmax = 4'd3;
      3'd6:    pmax = 4'd4;
      default: pmax = 4'd15;
    endcase
  endfunction

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      sel  <= '0;
      p[0] <= 4'd0;   p[1] <= 4'd1;   p[2] <= 4'd5;   p[3] <= 4'd11;
      p[4] <= 4'd6;   p[5] <= 4'd0;   p[6] <= 4'd2;   p[7] <= 4'd15;
    end
    else begin
      if ( menu_mode ) begin
        if ( btn_d )      sel <= sel + 1'b1;
        else if ( btn_u ) sel <= sel - 1'b1;
        if ( btn_r && p[sel] < pmax( sel ) )      p[sel] <= p[sel] + 1'b1;
        else if ( btn_l && p[sel] != 4'd0 )       p[sel] <= p[sel] - 1'b1;
      end
      if ( set_valid )
        p[set_idx] <= ( set_val > pmax( set_idx ) ) ? pmax( set_idx ) : set_val;
    end
  end

endmodule
