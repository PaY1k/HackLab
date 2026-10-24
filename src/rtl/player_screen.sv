// Everything between the audio path and the VGA connector:
//   * sample tick (48 kHz, same rate as pwm) and playback timer mm:ss
//   * player status clk_audio -> pixel_clk through cdc_bus
//   * oscilloscope buffer (scope_capture)
//   * display_ctrl (800x600 timing) + vga_ui (the picture)
// Used by both tops: src/top/audio_nexys_a7.sv (board) and src/sim/top_audio.sv
// (Verilator). Outputs are registered, connect them straight to the pins.
//
// Text cells can be written from the audio domain through txt_we / txt_word
// ({addr[12:0], color[3:0], cp866 char[7:0]}, see screen_text_ctrl.sv): the
// words cross to pixel_clk through a small async FIFO.
module player_screen #(
    parameter  FONT_FILE   = "font8x16.mem",
    parameter  TEXT_FILE   = "screen_text.mem",
    parameter  SPLASH_LOG2 = 27
)(
  //--------- Audio domain                       --------//
    input  wire          aud_clk      ,
    input  wire          aud_rst_n    ,
    input  wire          play         ,
    input  wire  [ 3:0]  volume       ,
    input  wire  [35:0]  key_mask     ,   // piano keys lit, bit 0 = C3 (MIDI 48)
    input  wire          sample_valid ,   // a sample went to the PWM (fifo_rd_en)
    input  wire  [15:0]  sample       ,   // that sample, unsigned
    input  wire          aud_en       ,   // amplifier on = sound is playing
    input  wire  [ 2:0]  track_idx    ,
    input  wire  [15:0]  len_bcd      ,   // track length mm:ss
    input  wire          len_valid    ,
    input  wire  [ 9:0]  progress     ,   // used when len_valid = 1
    input  wire          time_clear   ,   // restart the timer (track change)
    input  wire          txt_we       ,   // text cell write
    input  wire  [24:0]  txt_word     ,
    output wire          txt_full     ,
  //--------- Pixel domain                       --------//
    input  wire          pix_clk      ,
    input  wire          pix_rst_n    ,
    output logic [ 3:0]  vga_r        ,
    output logic [ 3:0]  vga_g        ,
    output logic [ 3:0]  vga_b        ,
    output logic         vga_hs       ,
    output logic         vga_vs       ,
    output logic         vga_de       ,   // for the simulator
    output logic [10:0]  vga_h        ,   // for the simulator
    output logic [ 9:0]  vga_v
);

//------------- Audio domain: sample tick, timer, scope sample   -------------//
  logic [ 9:0] tick_cnt;
  logic        sample_tick;
  logic [ 7:0] last_sample;
  wire  [15:0] time_bcd;

  always_ff @( posedge aud_clk or negedge aud_rst_n ) begin
    if ( !aud_rst_n ) begin
      tick_cnt    <= '0;
      sample_tick <= 1'b0;
      last_sample <= 8'd128;
    end
    else begin
      tick_cnt    <= tick_cnt + 1'b1;
      sample_tick <= &tick_cnt;                    // 49.15865 MHz / 1024 = 48.006 kHz
      if ( sample_valid )
        last_sample <= sample[15:8];
      else if ( !aud_en )
        last_sample <= 8'd128;                     // silence -> flat line
    end
  end

  play_timer play_timer (
    .clk         ( aud_clk     ),
    .rst_n       ( aud_rst_n   ),
    .sample_tick ( sample_tick ),
    .run         ( play        ),
    .clear       ( time_clear  ),
    .time_bcd    ( time_bcd    )
  );

  // Without a known length the bar shows the second inside the current minute
  wire [5:0] sec_in_min   = 6'( time_bcd[7:4] ) * 6'd10 + 6'( time_bcd[3:0] );
  wire [9:0] progress_aud = len_valid ? progress : 10'( sec_in_min ) * 10'd17;
//____________________________________________________________________________//

//------------- Status -> pixel domain                           -------------//
  localparam SW = 1 + 4 + 16 + 16 + 1 + 10 + 3 + 36;

  wire  [SW-1:0] status_aud = { play, volume, time_bcd, len_bcd, len_valid,
                                progress_aud, track_idx, key_mask };
  wire  [SW-1:0] status_pix;

  cdc_bus #( .WIDTH ( SW ) ) status_cdc (
    .src_clk   ( aud_clk    ),
    .src_rst_n ( aud_rst_n  ),
    .src_data  ( status_aud ),
    .dst_clk   ( pix_clk    ),
    .dst_rst_n ( pix_rst_n  ),
    .dst_data  ( status_pix )
  );

  wire         p_play;
  wire [ 3:0]  p_volume;
  wire [ 2:0]  p_track;
  wire [15:0]  p_time, p_len;
  wire         p_len_valid;
  wire [ 9:0]  p_progress;
  wire [35:0]  p_keys;
  assign { p_play, p_volume, p_time, p_len, p_len_valid, p_progress, p_track, p_keys } = status_pix;

  // Text writes -> pixel domain
  wire        txt_empty;
  wire [24:0] txt_q;
  async_fifo #( .DATA_WIDTH ( 25 ), .ADDR_WIDTH ( 6 ) ) txt_fifo (
    .wr_clk   ( aud_clk    ), .wr_rst_n ( aud_rst_n ), .wr_en ( txt_we ), .wr_data ( txt_word ),
    .full     ( txt_full   ), .wr_level (           ),
    .rd_clk   ( pix_clk    ), .rd_rst_n ( pix_rst_n ), .rd_en ( !txt_empty ), .rd_data ( txt_q ),
    .empty    ( txt_empty  ), .rd_level (           )
  );
//____________________________________________________________________________//

//------------- Picture                                          -------------//
  wire [10:0] h_coord;
  wire [ 9:0] v_coord;
  wire        h_sync, v_sync, disp_enbl;
  wire [ 8:0] scope_addr;
  wire [ 7:0] scope_data;
  wire        frame_start;
  wire [ 3:0] red, green, blue;
  wire        ui_hs, ui_vs, ui_de;
  wire [10:0] ui_h;
  wire [ 9:0] ui_v;

  display_ctrl display_ctrl (
    .pixel_clk  ( pix_clk   ),
    .rst_n      ( pix_rst_n ),
    .h_sync     ( h_sync    ),
    .v_sync     ( v_sync    ),
    .disp_enbl  ( disp_enbl ),
    .h_coord    ( h_coord   ),
    .v_coord    ( v_coord   )
  );

  scope_capture scope_capture (
    .aud_clk     ( aud_clk     ),
    .aud_rst_n   ( aud_rst_n   ),
    .sample_tick ( sample_tick ),
    .sample      ( last_sample ),
    .pix_clk     ( pix_clk     ),
    .pix_rst_n   ( pix_rst_n   ),
    .frame_start ( frame_start ),
    .rd_addr     ( scope_addr  ),
    .rd_data     ( scope_data  )
  );

  vga_ui #(
    .FONT_FILE   ( FONT_FILE   ),
    .TEXT_FILE   ( TEXT_FILE   ),
    .SPLASH_LOG2 ( SPLASH_LOG2 )
  ) vga_ui (
    .pixel_clk   ( pix_clk     ),
    .rst_n       ( pix_rst_n   ),
    .h_coord     ( h_coord     ),
    .v_coord     ( v_coord     ),
    .h_sync      ( h_sync      ),
    .v_sync      ( v_sync      ),
    .disp_enbl   ( disp_enbl   ),
    .play        ( p_play      ),
    .volume      ( p_volume    ),
    .time_bcd    ( p_time      ),
    .len_bcd     ( p_len       ),
    .len_valid   ( p_len_valid ),
    .progress    ( p_progress  ),
    .track_idx   ( p_track     ),
    .key_mask    ( p_keys      ),
    .scope_addr  ( scope_addr  ),
    .scope_data  ( scope_data  ),
    .frame_start ( frame_start ),
    .txt_we      ( !txt_empty     ),
    .txt_addr    ( txt_q[24:12]   ),
    .txt_data    ( txt_q[11:0]    ),
    .red         ( red         ),
    .green       ( green       ),
    .blue        ( blue        ),
    .out_hs      ( ui_hs       ),
    .out_vs      ( ui_vs       ),
    .out_de      ( ui_de       ),
    .out_h       ( ui_h        ),
    .out_v       ( ui_v        )
  );

  // Output register: black outside the visible area, sync aligned with color
  always_ff @( posedge pix_clk ) begin
    vga_r  <= ui_de ? red   : 4'd0;
    vga_g  <= ui_de ? green : 4'd0;
    vga_b  <= ui_de ? blue  : 4'd0;
    vga_hs <= ui_hs;
    vga_vs <= ui_vs;
    vga_de <= ui_de;
    vga_h  <= ui_h;
    vga_v  <= ui_v;
  end
//____________________________________________________________________________//

endmodule
