module top_audio (
  //----------- Clock & Reset                                    -------------//
    input   logic            clk          ,  // clk_audio
    input   logic            pixel_clk    ,
    input   logic            sim_rst      ,
  //----------- Buttons (keyboard levels, like the board pins)   -------------//
    input   logic            button_c     ,
    input   logic            button_u     ,
    input   logic            button_d     ,
    input   logic            button_r     ,
    input   logic            button_l     ,
  //----------- Switches                                         -------------//
    input   logic            sw0          ,
    input   logic            sw1          ,
    input   logic            sw2          ,
  //----------- Audio: data used by the sim to play the notes    -------------//
    output  logic            aud_pwm      ,
    output  logic            aud_en       ,
  //----------- Seven Segments Indicators                        -------------//
    output  logic  [ 6:0]    seg_active_n ,
    output  logic            dp_n         ,
    output  logic  [ 7:0]    anodes       ,
  //----------- Status for the sim window title                  -------------//
    output  logic  [ 3:0]    volume       ,
    output  logic            play         ,
    output  logic  [ 2:0]    note_index   ,
  //----------- VGA: pixel for the sim window                    -------------//
    output  logic  [10:0]    sdl_sx       ,
    output  logic  [ 9:0]    sdl_sy       ,
    output  logic            sdl_de       ,
    output  logic  [ 3:0]    sdl_r        ,
    output  logic  [ 3:0]    sdl_g        ,
    output  logic  [ 3:0]    sdl_b
);
//----------- Variables                                          -------------//
    wire  [15:0]  sample             ;
    wire  [19:0]  vol_mult           ;
    wire  [15:0]  sample_scaled      ;
    
    wire          valid              ;
    wire          ready              ;
     
    wire  [31:0]  fifo_wr_data       ;
    wire          fifo_wr_en         ;
    wire          fifo_full          ;
    wire  [31:0]  fifo_rd_data       ;
    wire          fifo_rd_en         ;
    wire          fifo_empty         ;
//____________________________________________________________________________//

//------------- Control logic                                    -------------//
    button_ctrl button_ctrl_inst (
      .clk         ( clk        ),
      .rst_n       ( ~sim_rst   ),
      .button_c    ( button_c   ),
      .button_u    ( button_u   ),
      .button_d    ( button_d   ),
      .button_r    ( button_r   ),
      .button_l    ( button_l   ),
      .play        ( play       ),
      .volume      ( volume     ),
      .note_index  ( note_index )
    );
//____________________________________________________________________________//

//------------- Audio data path                                  -------------//
  //----------- Tone generator                                   -----------//
    tone_generator tone_generator_inst (
      .clk         ( clk               ),
      .rst_n       ( ~sim_rst          ),
      .note_index  ( note_index        ),
      .octave_sel  ( { sw2, sw1, sw0 } ),
      .sample      ( sample            ),
      .valid       ( valid             ),
      .ready       ( ready             )
    );

    assign vol_mult      = sample * volume;
    assign sample_scaled = vol_mult [19:4];
  //----------- FIFO                                             -----------//
    // pace is set by pwm: it reads one sample per 1024 clocks (48.006 kHz);
    // the generator steps once per written sample, so the full FIFO holds
    // 256 samples = ~5.3 ms of sound (latency of note/volume/pause changes)
    assign ready       = play && !fifo_full;

    assign fifo_wr_en   = ready;
    assign fifo_wr_data = {16'b0, sample_scaled};

    fifo fifo_inst (
      .clk     ( clk          ),
      .rst_n   ( ~sim_rst     ),
      .wr_data ( fifo_wr_data ),
      .wr_en   ( fifo_wr_en   ),
      .full    ( fifo_full    ),
      .rd_data ( fifo_rd_data ),
      .rd_en   ( fifo_rd_en   ),
      .empty   ( fifo_empty   )
    );
  //----------- PWM                                              -----------//
    pwm pwm_inst (
      .clk          ( clk          ),
      .rst_n        ( ~sim_rst     ),
      .aud_pwm      ( aud_pwm      ),
      .aud_en       ( aud_en       ),
      .fifo_rd_data ( fifo_rd_data ),
      .fifo_rd_en   ( fifo_rd_en   ),
      .fifo_empty   ( fifo_empty   )
    );
//____________________________________________________________________________//

//------------- Seven Segments Indicators                        -------------//
    // the board divides clk_5mhz0d by 2^13 (610 Hz); the sim has no 5 MHz clock,
    // so clk is divided by 2^16: 49.16 MHz / 2^16 = 750 Hz
    wire  [31:0]  sevseg_32bit_hex_val ;
    logic [ 3:0]  note_hex             ;
    wire  [ 3:0]  octave_digit         ;
    reg   [15:0]  digital_clock_divider;

    always_ff @( posedge clk ) begin
      if ( sim_rst )
        digital_clock_divider <= 0;
      else
        digital_clock_divider <= digital_clock_divider + 1;
    end
    sevseg_ctrl seven_segments_controller (
      .clk                    ( digital_clock_divider [15]   ),
      .arst_n                 ( ~sim_rst                     ),
      .sevseg_32bit_hex_val   ( sevseg_32bit_hex_val         ),
      .seg_active_n           ( seg_active_n                 ),
      .don_active_n           ( dp_n                         ),
      .anodes                 ( anodes                       )
    );
    assign octave_digit = {1'b0, sw2, sw1, sw0} + 4'd1;
    always_comb begin
      case ( note_index )
        3'd0:    note_hex = 'hc;  // C
        3'd1:    note_hex = 'hd;  // D
        3'd2:    note_hex = 'he;  // E
        3'd3:    note_hex = 'hf;  // F
        3'd4:    note_hex = 'h6;  // G
        3'd5:    note_hex = 'ha;  // A
        3'd6:    note_hex = 'hb;  // B
        default: note_hex = 'hc;
      endcase
    end
    assign sevseg_32bit_hex_val = {24'b0, note_hex, octave_digit};
//____________________________________________________________________________//

//------------- VGA: player screen (the same module as on the board) -------//
    player_screen #(
      .FONT_FILE    ( "../rtl/mem/font8x16.mem"   ),   // the sim runs from src/sim
      .TEXT_FILE    ( "../rtl/mem/screen_text.mem" ),
      .SPLASH_LOG2  ( 26                          )    // shorter splash: the sim is slower
    ) player_screen (
      .aud_clk      ( clk                ),
      .aud_rst_n    ( ~sim_rst           ),
      .play         ( play               ),
      .volume       ( volume             ),
      .note_index   ( note_index         ),
      .octave       ( { sw2, sw1, sw0 }  ),
      .sample_valid ( fifo_rd_en         ),
      .sample       ( fifo_rd_data[15:0] ),
      .aud_en       ( aud_en             ),
      .track_idx    ( 3'd0               ),
      .len_bcd      ( 16'h0000           ),
      .len_valid    ( 1'b0               ),
      .progress     ( 10'd0              ),
      .time_clear   ( 1'b0               ),
      .pix_clk      ( pixel_clk          ),
      .pix_rst_n    ( ~sim_rst           ),
      .vga_r        ( sdl_r              ),
      .vga_g        ( sdl_g              ),
      .vga_b        ( sdl_b              ),
      /* verilator lint_off PINCONNECTEMPTY */
      .vga_hs       (                    ),   // the sim draws by coordinates
      .vga_vs       (                    ),
      /* verilator lint_on PINCONNECTEMPTY */
      .vga_de       ( sdl_de             ),
      .vga_h        ( sdl_sx             ),
      .vga_v        ( sdl_sy             )
    );
//____________________________________________________________________________//

endmodule