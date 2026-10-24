// The whole music player, without clocks, resets and button debouncers.
// Used by the board top (src/top/audio_nexys_a7.sv) and the Verilator
// simulator (src/sim/top_audio.sv).
//
//   buttons ──> player_ctrl ──> audio_core ──> AUD_PWM
//                  │               ▲   ▲
//   SD card ──> sd_card ─> sd_player ─> FIFO      │
//   USB-UART ─> pc_link ──> FIFO, MIDI events ────┘
//                  │
//   everything ──> screen_text_ctrl + player_screen ──> VGA
//
// Tracks: 0 synth, 1-2 melodies (BRAM), 3-4 WAV files from SD, 5 stream from PC.
// Switches: SW[2:0] octave, SW[4:3] waveform, SW15 BTNL/BTNR play notes.
module player_top #(
    parameter  FONT_FILE   = "font8x16.mem",
    parameter  TEXT_FILE   = "screen_text.mem",
    parameter  SINE_FILE   = "sine1024.mem",
    parameter  NOTE_FILE   = "note_inc.mem",
    parameter  MEL_FILE    = "melodies.mem",
    parameter  INFO_FILE   = "melody_info.mem",
    parameter  STR_FILE    = "strings.mem",
    parameter  SPLASH_LOG2 = 27,
    parameter  SD_WAIT_BITS = 24
)(
  //--------- Clocks / resets                    --------//
    input  wire          aud_clk    ,   // 49.15865 MHz
    input  wire          aud_rst_n  ,
    input  wire          pix_clk    ,   // 39.941 MHz
    input  wire          pix_rst_n  ,
  //--------- Buttons (one-clock pulses, aud_clk) and switches --------//
    input  wire          btn_c      ,
    input  wire          btn_u      ,
    input  wire          btn_d      ,
    input  wire          btn_l      ,
    input  wire          btn_r      ,
    input  wire  [15:0]  sw         ,   // asynchronous
  //--------- Audio                              --------//
    output wire          aud_pwm    ,
  //--------- USB-UART                           --------//
    input  wire          uart_rx    ,
    output wire          uart_tx    ,
  //--------- microSD                            --------//
    output wire          sd_reset   ,
    output wire          sd_cs      ,
    output wire          sd_sck     ,
    output wire          sd_mosi    ,
    input  wire          sd_miso    ,
  //--------- VGA                                --------//
    output wire  [ 3:0]  vga_r      ,
    output wire  [ 3:0]  vga_g      ,
    output wire  [ 3:0]  vga_b      ,
    output wire          vga_hs     ,
    output wire          vga_vs     ,
    output wire          vga_de     ,
    output wire  [10:0]  vga_h      ,
    output wire  [ 9:0]  vga_v      ,
  //--------- Status (seven-segment, sim window) --------//
    output wire          play       ,
    output wire  [ 3:0]  volume     ,
    output wire  [ 2:0]  note_index ,
    output wire  [ 2:0]  track      ,
    output wire  [ 2:0]  octave
);

//------------- Switches                                         -------------//
  (* ASYNC_REG = "TRUE" *) logic [15:0] sw_s1, sw_s2;
  always_ff @( posedge aud_clk ) begin
    sw_s1 <= sw;
    sw_s2 <= sw_s1;
  end
  assign octave = sw_s2[2:0];
  wire [1:0] wave_sel   = sw_s2[4:3];
  wire       notes_mode = sw_s2[15];
//____________________________________________________________________________//

//------------- Control                                          -------------//
  wire switching, restart, gain_zero;

  player_ctrl player_ctrl (
    .clk        ( aud_clk    ),
    .rst_n      ( aud_rst_n  ),
    .btn_c      ( btn_c      ),
    .btn_u      ( btn_u      ),
    .btn_d      ( btn_d      ),
    .btn_l      ( btn_l      ),
    .btn_r      ( btn_r      ),
    .notes_mode ( notes_mode ),
    .gain_zero  ( gain_zero  ),
    .play       ( play       ),
    .volume     ( volume     ),
    .note_index ( note_index ),
    .track      ( track      ),
    .switching  ( switching  ),
    .restart    ( restart    )
  );

  // manual synth note: octave SW 0..7 = octaves 1..8, MIDI = 12 * (octave + 2) + semitone
  logic [3:0] semi;
  always_comb begin
    case ( note_index )
      3'd0: semi = 4'd0;   3'd1: semi = 4'd2;   3'd2: semi = 4'd4;   3'd3: semi = 4'd5;
      3'd4: semi = 4'd7;   3'd5: semi = 4'd9;   default: semi = 4'd11;
    endcase
  end
  wire [6:0] synth_note = 7'( ( { 4'd0, octave } + 7'd2 ) * 7'd12 ) + 7'( semi );
//____________________________________________________________________________//

//------------- PC link (USB-UART)                               -------------//
  wire        pc_wr, pc_rd, pc_empty;
  wire [15:0] pc_wdata, pc_q;
  wire [12:0] pc_level;
  wire        midi_on, midi_off, midi_all_off;
  wire [ 6:0] midi_note;
  wire [ 4:0] pc_title_idx;
  wire [ 7:0] pc_title_char;
  wire        pc_title_valid, pc_title_chg;

  pc_link pc_link (
    .clk           ( aud_clk        ),
    .rst_n         ( aud_rst_n      ),
    .uart_rx_pin   ( uart_rx        ),
    .uart_tx_pin   ( uart_tx        ),
    .fifo_wr       ( pc_wr          ),
    .fifo_data     ( pc_wdata       ),
    .fifo_level    ( pc_level       ),
    .midi_on       ( midi_on        ),
    .midi_off      ( midi_off       ),
    .midi_note     ( midi_note      ),
    .midi_all_off  ( midi_all_off   ),
    .title_idx     ( pc_title_idx   ),
    .title_char    ( pc_title_char  ),
    .title_valid   ( pc_title_valid ),
    .title_changed ( pc_title_chg   )
  );

  async_fifo #( .DATA_WIDTH ( 16 ), .ADDR_WIDTH ( 12 ) ) pc_fifo (
    .wr_clk ( aud_clk ), .wr_rst_n ( aud_rst_n ), .wr_en ( pc_wr ), .wr_data ( pc_wdata ),
    .full   (         ), .wr_level ( pc_level  ),
    .rd_clk ( aud_clk ), .rd_rst_n ( aud_rst_n ), .rd_en ( pc_rd ), .rd_data ( pc_q ),
    .empty  ( pc_empty ), .rd_level (          )
  );
//____________________________________________________________________________//

//------------- SD card                                          -------------//
  wire        card_ready, card_sdhc, rd_req, sd_hold, rd_busy, rd_valid, rd_done, rd_err;
  wire [31:0] rd_lba;
  wire [ 7:0] rd_data;
  wire [ 8:0] rd_idx;
  wire        sd_wr, sd_rd, sd_empty, sd_flush;
  wire [15:0] sd_wdata, sd_q, sd_step, sd_len;
  wire [12:0] sd_level;
  wire [ 1:0] sd_nfiles;
  wire        sd_name_file;
  wire [ 3:0] sd_name_idx;
  wire [ 7:0] sd_name_char;
  wire [ 2:0] sd_status;
  wire        sd_len_valid;
  wire [ 9:0] sd_progress;

  sd_card #( .WAIT_BITS ( SD_WAIT_BITS ) ) sd_card (
    .clk        ( aud_clk    ),
    .rst_n      ( aud_rst_n  ),
    .sd_reset   ( sd_reset   ),
    .sd_cs      ( sd_cs      ),
    .sd_sck     ( sd_sck     ),
    .sd_mosi    ( sd_mosi    ),
    .sd_miso    ( sd_miso    ),
    .card_ready ( card_ready ),
    .card_sdhc  ( card_sdhc  ),
    .rd_req     ( rd_req     ),
    .rd_lba     ( rd_lba     ),
    .hold       ( sd_hold    ),
    .rd_busy    ( rd_busy    ),
    .rd_data    ( rd_data    ),
    .rd_idx     ( rd_idx     ),
    .rd_valid   ( rd_valid   ),
    .rd_done    ( rd_done    ),
    .rd_err     ( rd_err     )
  );

  wire sd_track = ( track == 3'd3 ) || ( track == 3'd4 );

  sd_player sd_player (
    .clk         ( aud_clk                  ),
    .rst_n       ( aud_rst_n                ),
    .card_ready  ( card_ready               ),
    .rd_req      ( rd_req                   ),
    .rd_lba      ( rd_lba                   ),
    .hold        ( sd_hold                  ),
    .rd_busy     ( rd_busy                  ),
    .rd_data     ( rd_data                  ),
    .rd_idx      ( rd_idx                   ),
    .rd_valid    ( rd_valid                 ),
    .rd_done     ( rd_done                  ),
    .rd_err      ( rd_err                   ),
    .play_start  ( restart && sd_track      ),
    .file_sel    ( track == 3'd4            ),
    .play_stop   ( restart && !sd_track     ),
    .fifo_wr     ( sd_wr                    ),
    .fifo_data   ( sd_wdata                 ),
    .fifo_level  ( sd_level                 ),
    .fifo_flush  ( sd_flush                 ),
    .nfiles      ( sd_nfiles                ),
    .name_file   ( sd_name_file             ),
    .name_idx    ( sd_name_idx              ),
    .name_char   ( sd_name_char             ),
    .status      ( sd_status                ),
    .step        ( sd_step                  ),
    .len_bcd     ( sd_len                   ),
    .len_valid   ( sd_len_valid             ),
    .progress    ( sd_progress              )
  );

  wire sd_fifo_rst_n = aud_rst_n && !sd_flush;

  async_fifo #( .DATA_WIDTH ( 16 ), .ADDR_WIDTH ( 12 ) ) sd_fifo (
    .wr_clk ( aud_clk ), .wr_rst_n ( sd_fifo_rst_n ), .wr_en ( sd_wr ), .wr_data ( sd_wdata ),
    .full   (         ), .wr_level ( sd_level      ),
    .rd_clk ( aud_clk ), .rd_rst_n ( sd_fifo_rst_n ), .rd_en ( sd_rd ), .rd_data ( sd_q ),
    .empty  ( sd_empty ), .rd_level (               )
  );
//____________________________________________________________________________//

//------------- Sound                                            -------------//
  wire        tick;
  wire [15:0] out_u16, mel_len;
  wire [35:0] key_mask;
  wire [ 9:0] mel_progress;

  audio_core #(
    .SINE_FILE ( SINE_FILE ),
    .NOTE_FILE ( NOTE_FILE ),
    .MEL_FILE  ( MEL_FILE  ),
    .INFO_FILE ( INFO_FILE )
  ) audio_core (
    .clk          ( aud_clk      ),
    .rst_n        ( aud_rst_n    ),
    .play         ( play         ),
    .volume       ( volume       ),
    .track        ( track        ),
    .switching    ( switching    ),
    .restart      ( restart      ),
    .synth_note   ( synth_note   ),
    .wave_sel     ( wave_sel     ),
    .midi_on      ( midi_on      ),
    .midi_off     ( midi_off     ),
    .midi_note    ( midi_note    ),
    .midi_all_off ( midi_all_off ),
    .sd_empty     ( sd_empty     ),
    .sd_data      ( sd_q         ),
    .sd_step      ( sd_step      ),
    .sd_rd        ( sd_rd        ),
    .pc_empty     ( pc_empty     ),
    .pc_data      ( pc_q         ),
    .pc_rd        ( pc_rd        ),
    .tick         ( tick         ),
    .gain_zero    ( gain_zero    ),
    .aud_pwm      ( aud_pwm      ),
    .out_u16      ( out_u16      ),
    .key_mask     ( key_mask     ),
    .mel_len_bcd  ( mel_len      ),
    .mel_progress ( mel_progress )
  );
//____________________________________________________________________________//

//------------- Screen                                           -------------//
  logic [15:0] len_bcd;
  logic        len_valid;
  logic [ 9:0] progress;
  always_comb begin
    case ( track )
      3'd1, 3'd2: begin len_bcd = mel_len; len_valid = 1'b1;         progress = mel_progress; end
      3'd3, 3'd4: begin len_bcd = sd_len;  len_valid = sd_len_valid; progress = sd_progress;  end
      default:    begin len_bcd = '0;      len_valid = 1'b0;         progress = '0;           end
    endcase
  end

  wire        txt_we, txt_full;
  wire [24:0] txt_word;

  screen_text_ctrl #( .STR_FILE ( STR_FILE ) ) screen_text_ctrl (
    .clk            ( aud_clk        ),
    .rst_n          ( aud_rst_n      ),
    .track          ( track          ),
    .note_index     ( note_index     ),
    .octave         ( octave         ),
    .sd_status      ( sd_status      ),
    .sd_nfiles      ( sd_nfiles      ),
    .sd_name_file   ( sd_name_file   ),
    .sd_name_idx    ( sd_name_idx    ),
    .sd_name_char   ( sd_name_char   ),
    .pc_title_idx   ( pc_title_idx   ),
    .pc_title_char  ( pc_title_char  ),
    .pc_title_valid ( pc_title_valid ),
    .pc_title_chg   ( pc_title_chg   ),
    .txt_we         ( txt_we         ),
    .txt_word       ( txt_word       ),
    .txt_full       ( txt_full       )
  );

  player_screen #(
    .FONT_FILE   ( FONT_FILE   ),
    .TEXT_FILE   ( TEXT_FILE   ),
    .SPLASH_LOG2 ( SPLASH_LOG2 )
  ) player_screen (
    .aud_clk      ( aud_clk    ),
    .aud_rst_n    ( aud_rst_n  ),
    .play         ( play       ),
    .volume       ( volume     ),
    .key_mask     ( key_mask   ),
    .sample_valid ( tick       ),
    .sample       ( out_u16    ),
    .aud_en       ( 1'b1       ),
    .track_idx    ( track      ),
    .len_bcd      ( len_bcd    ),
    .len_valid    ( len_valid  ),
    .progress     ( progress   ),
    .time_clear   ( restart    ),
    .txt_we       ( txt_we     ),
    .txt_word     ( txt_word   ),
    .txt_full     ( txt_full   ),
    .pix_clk      ( pix_clk    ),
    .pix_rst_n    ( pix_rst_n  ),
    .vga_r        ( vga_r      ),
    .vga_g        ( vga_g      ),
    .vga_b        ( vga_b      ),
    .vga_hs       ( vga_hs     ),
    .vga_vs       ( vga_vs     ),
    .vga_de       ( vga_de     ),
    .vga_h        ( vga_h      ),
    .vga_v        ( vga_v      )
  );
//____________________________________________________________________________//

endmodule
