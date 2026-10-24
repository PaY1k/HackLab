// Player control from the board buttons (debounced one-clock pulses).
//
//   BTNC        play / pause
//   BTNU / BTND volume up / down (0..15, start 10)
//   BTNL / BTNR previous / next track (6 tracks, wraps around);
//               with notes_mode = 1 (SW15) on track 0: previous / next note
//   menu_mode = 1 (SW14): BTNU/BTND/BTNL/BTNR edit the synth settings
//               (synth_settings.sv) and are ignored here
//
// A track change is done in two steps: `switching` fades the sound out,
// when audio_core reports gain_zero the new track is applied and `restart`
// pulses (melody from the start, SD file opened, timer cleared), then the
// sound fades in again.
module player_ctrl #(
    parameter  N_TRACKS = 3'd6
)(
    input  wire        clk        ,
    input  wire        rst_n      ,
    input  wire        btn_c      ,
    input  wire        btn_u      ,
    input  wire        btn_d      ,
    input  wire        btn_l      ,
    input  wire        btn_r      ,
    input  wire        notes_mode ,
    input  wire        menu_mode  ,
    input  wire        gain_zero  ,
    output logic       play       ,
    output logic [3:0] volume     ,
    output logic [2:0] note_index ,   // 0..6 = C D E F G A B
    output logic [2:0] track      ,
    output logic       switching  ,
    output logic       restart
);

  logic [2:0] next_track;
  wire        note_keys = notes_mode && ( track == 3'd0 ) && !switching;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      play       <= 1'b0;
      volume     <= 4'd10;
      note_index <= 3'd0;
      track      <= 3'd0;
      next_track <= 3'd0;
      switching  <= 1'b0;
      restart    <= 1'b1;            // start the first track after reset
    end
    else begin
      restart <= 1'b0;

      if ( btn_c ) play <= ~play;

      if ( !menu_mode && btn_u && volume != 4'd15 )      volume <= volume + 1'b1;
      else if ( !menu_mode && btn_d && volume != 4'd0 )  volume <= volume - 1'b1;

      if ( menu_mode ) begin
        if ( switching && gain_zero ) begin              // finish a change started before
          track     <= next_track;
          switching <= 1'b0;
          restart   <= 1'b1;
        end
      end
      else if ( note_keys ) begin
        if ( btn_r )      note_index <= ( note_index == 3'd6 ) ? 3'd0 : note_index + 1'b1;
        else if ( btn_l ) note_index <= ( note_index == 3'd0 ) ? 3'd6 : note_index - 1'b1;
      end
      else if ( btn_r || btn_l ) begin
        // count from the track already requested, so fast presses add up
        if ( btn_r ) next_track <= ( ( switching ? next_track : track ) == N_TRACKS - 1'b1 ) ? 3'd0
                                   : ( switching ? next_track : track ) + 1'b1;
        else         next_track <= ( ( switching ? next_track : track ) == 3'd0 ) ? N_TRACKS - 1'b1
                                   : ( switching ? next_track : track ) - 1'b1;
        switching <= 1'b1;
      end
      else if ( switching && gain_zero ) begin
        track     <= next_track;
        switching <= 1'b0;
        restart   <= 1'b1;
      end
    end
  end

endmodule
