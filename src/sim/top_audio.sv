// Top for the Verilator simulator: the same player_top as on the board,
// without PLL and debouncers (main_audio.cpp gives clocks and one-clock button
// pulses). No SD card (MISO idle high) and no PC (UART idle) in the sim.
module top_audio (
  //----------- Clock & Reset                                    -------------//
    input   logic            clk          ,  // clk_audio
    input   logic            pixel_clk    ,
    input   logic            sim_rst      ,
  //----------- Buttons (one-clock pulses from main_audio.cpp)   -------------//
    input   logic            button_c     ,
    input   logic            button_u     ,
    input   logic            button_d     ,
    input   logic            button_r     ,
    input   logic            button_l     ,
  //----------- Switches                                         -------------//
    input   logic            sw0          ,  // octave
    input   logic            sw1          ,
    input   logic            sw2          ,
    input   logic            sw3          ,  // waveform
    input   logic            sw4          ,
    input   logic            sw15         ,  // BTNL/BTNR play notes
  //----------- Audio                                            -------------//
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
    output  logic  [ 2:0]    track        ,
  //----------- VGA: pixel for the sim window                    -------------//
    output  logic  [10:0]    sdl_sx       ,
    output  logic  [ 9:0]    sdl_sy       ,
    output  logic            sdl_de       ,
    output  logic  [ 3:0]    sdl_r        ,
    output  logic  [ 3:0]    sdl_g        ,
    output  logic  [ 3:0]    sdl_b
);

    wire  [ 2:0]  octave;

    player_top #(
      .FONT_FILE   ( "../rtl/mem/font8x16.mem"    ),   // the sim runs from src/sim
      .TEXT_FILE   ( "../rtl/mem/screen_text.mem" ),
      .SINE_FILE   ( "../rtl/mem/sine1024.mem"    ),
      .NOTE_FILE   ( "../rtl/mem/note_inc.mem"    ),
      .MEL_FILE    ( "../rtl/mem/melodies.mem"    ),
      .INFO_FILE   ( "../rtl/mem/melody_info.mem" ),
      .STR_FILE    ( "../rtl/mem/strings.mem"     ),
      .SPLASH_LOG2 ( 26                           )    // shorter splash: the sim is slower
    ) player (
      .aud_clk    ( clk           ),
      .aud_rst_n  ( ~sim_rst      ),
      .pix_clk    ( pixel_clk     ),
      .pix_rst_n  ( ~sim_rst      ),
      .btn_c      ( button_c      ),
      .btn_u      ( button_u      ),
      .btn_d      ( button_d      ),
      .btn_l      ( button_l      ),
      .btn_r      ( button_r      ),
      .sw         ( { sw15, 10'd0, sw4, sw3, sw2, sw1, sw0 } ),
      .aud_pwm    ( aud_pwm       ),
      .uart_rx    ( 1'b1          ),
      /* verilator lint_off PINCONNECTEMPTY */
      .uart_tx    (               ),
      .sd_reset   (               ),
      .sd_cs      (               ),
      .sd_sck     (               ),
      .sd_mosi    (               ),
      .vga_hs     (               ),   // the sim draws by coordinates
      .vga_vs     (               ),
      /* verilator lint_on PINCONNECTEMPTY */
      .sd_miso    ( 1'b1          ),
      .vga_r      ( sdl_r         ),
      .vga_g      ( sdl_g         ),
      .vga_b      ( sdl_b         ),
      .vga_de     ( sdl_de        ),
      .vga_h      ( sdl_sx        ),
      .vga_v      ( sdl_sy        ),
      .play       ( play          ),
      .volume     ( volume        ),
      .note_index ( note_index    ),
      .track      ( track         ),
      .octave     ( octave        ),
      /* verilator lint_off PINCONNECTEMPTY */
      .leds       (               )
      /* verilator lint_on PINCONNECTEMPTY */
    );

    assign aud_en = 1'b1;

//------------- Seven Segments Indicators                        -------------//
    // the board divides clk_5mhz0d by 2^13 (610 Hz); the sim has no 5 MHz clock,
    // so clk is divided by 2^16: 49.16 MHz / 2^16 = 750 Hz
    reg   [15:0]  digital_clock_divider;
    logic [ 3:0]  note_hex;

    always_ff @( posedge clk ) begin
      if ( sim_rst )
        digital_clock_divider <= 0;
      else
        digital_clock_divider <= digital_clock_divider + 1;
    end

    always_comb begin
      case ( note_index )
        3'd0:    note_hex = 'hc;
        3'd1:    note_hex = 'hd;
        3'd2:    note_hex = 'he;
        3'd3:    note_hex = 'hf;
        3'd4:    note_hex = 'h6;
        3'd5:    note_hex = 'ha;
        default: note_hex = 'hb;
      endcase
    end

    sevseg_ctrl seven_segments_controller (
      .clk                    ( digital_clock_divider [15]   ),
      .arst_n                 ( ~sim_rst                     ),
      .sevseg_32bit_hex_val   ( { 16'h0, 4'( track ) + 4'd1, volume, note_hex, 4'( octave ) + 4'd1 } ),
      .seg_active_n           ( seg_active_n                 ),
      .don_active_n           ( dp_n                         ),
      .anodes                 ( anodes                       )
    );
//____________________________________________________________________________//

endmodule
