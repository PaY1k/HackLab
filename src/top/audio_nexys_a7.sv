// Board top: clocks, resets, button debouncers, pins. The player itself is
// src/rtl/player_top.sv (the same module runs in the Verilator simulator).
module audio_nexys_a7 (
  //----------- CLOCK                                            -------------//
    input   logic            CLK100MHZ   ,
  //----------- Switches                                         -------------//
    input   logic  [15:0]    SW          ,
  //----------- Buttons                                          -------------//
    input   logic            BTNC        ,
    input   logic            BTNU        ,
    input   logic            BTNL        ,
    input   logic            BTNR        ,
    input   logic            BTND        ,
    input   logic            CPU_RESETN  ,
  //----------- LEDs: 0 UART byte, 1 command understood, 2 note sounding, 3 SD ready //
    output  logic  [ 3:0]    LED         ,
  //----------- Seven Segments Indicators                        -------------//
    output  logic            DP, CG, CF, CE, CD, CC, CB, CA,
    output  logic  [ 7:0]    AN          ,
  //----------- Audio                                            -------------//
    output  logic            AUD_PWM     ,
    output  logic            AUD_SD      ,
  //----------- VGA                                              -------------//
    output  logic  [ 3:0]    VGA_R       ,
    output  logic  [ 3:0]    VGA_G       ,
    output  logic  [ 3:0]    VGA_B       ,
    output  logic            VGA_HS      ,
    output  logic            VGA_VS      ,
  //----------- USB-UART (names as seen from the PC)              -------------//
    input   logic            UART_TXD_IN ,   // PC -> FPGA
    output  logic            UART_RXD_OUT,   // FPGA -> PC
  //----------- microSD (SPI mode)                               -------------//
    output  logic            SD_RESET    ,   // 0 = card powered
    output  logic            SD_SCK      ,
    output  logic            SD_CMD      ,   // MOSI
    input   logic            SD_DAT0     ,   // MISO
    output  logic            SD_DAT3         // CS
);

//------------- Signals declaration                              -------------//
    wire          clk_audio    ;     // 49.15865 MHz, phase 0 degrees
    wire          clk_5mhz0d   ;     // 4.993 MHz,    phase 0 degrees
    wire          pixel_clk    ;     // 39.941 MHz,   SVGA 800x600@60 pixel clock
    wire          pll_locked   ;
    wire          pll_rst_n    ;
    wire          rst_n        ;     // reset in the 5 MHz domain
    wire          aud_rst_n    ;     // rst_n released synchronously to clk_audio
    wire          pix_rst_n    ;     // rst_n released synchronously to pixel_clk

    logic         button_c, button_c_d, button_c_u;
    logic         button_u, button_u_d, button_u_u;
    logic         button_d, button_d_d, button_d_u;
    logic         button_l, button_l_d, button_l_u;
    logic         button_r, button_r_d, button_r_u;

    wire          play          ;
    wire  [ 3:0]  volume        ;
    wire  [ 2:0]  note_index    ;
    wire  [ 2:0]  track         ;
    wire  [ 2:0]  octave        ;
    wire          aud_pwm_loc   ;
//____________________________________________________________________________//

//------------- Clock & Reset                                      -----------//
    clk_wiz_0 clk_gen (
      .clk_in1  ( CLK100MHZ       ),
      .resetn   ( pll_rst_n       ),
      .clk_out1 ( clk_audio       ),  // 49.15865 MHz
      .clk_out2 ( clk_5mhz0d      ),  // 4.993 MHz
      .clk_out3 ( pixel_clk       ),  // 39.941 MHz
      .locked   ( pll_locked      )
    );

    reset_button_debouncer reset (
      .clk_100mhz   ( CLK100MHZ  ),
      .clk_5mhz     ( clk_5mhz0d ),
      .reset_button ( CPU_RESETN ),
      .pll_rst_n    ( pll_rst_n  ),
      .pll_locked   ( pll_locked ),
      .rst_n        ( rst_n      )
    );

    // rst_n comes from the 5 MHz domain, the other clocks are asynchronous to it
    reset_sync audio_reset_sync (
      .clk      ( clk_audio  ),
      .arst_n   ( rst_n      ),
      .rst_n    ( aud_rst_n  )
    );

    reset_sync pixel_reset_sync (
      .clk      ( pixel_clk  ),
      .arst_n   ( rst_n      ),
      .rst_n    ( pix_rst_n  )
    );
//____________________________________________________________________________//

//------------- Debouncers for Buttons                           -------------//
    button_debouncer dbns_center (
      .clk ( clk_audio ), .arst_n ( aud_rst_n ), .sw_i ( BTNC ),
      .sw_state_o ( button_c ), .sw_down_o ( button_c_d ), .sw_up_o ( button_c_u )
    );
    button_debouncer dbns_up (
      .clk ( clk_audio ), .arst_n ( aud_rst_n ), .sw_i ( BTNU ),
      .sw_state_o ( button_u ), .sw_down_o ( button_u_d ), .sw_up_o ( button_u_u )
    );
    button_debouncer dbns_left (
      .clk ( clk_audio ), .arst_n ( aud_rst_n ), .sw_i ( BTNL ),
      .sw_state_o ( button_l ), .sw_down_o ( button_l_d ), .sw_up_o ( button_l_u )
    );
    button_debouncer dbns_right (
      .clk ( clk_audio ), .arst_n ( aud_rst_n ), .sw_i ( BTNR ),
      .sw_state_o ( button_r ), .sw_down_o ( button_r_d ), .sw_up_o ( button_r_u )
    );
    button_debouncer dbns_down (
      .clk ( clk_audio ), .arst_n ( aud_rst_n ), .sw_i ( BTND ),
      .sw_state_o ( button_d ), .sw_down_o ( button_d_d ), .sw_up_o ( button_d_u )
    );
//____________________________________________________________________________//

//------------- The player                                       -------------//
    player_top player (
      .aud_clk    ( clk_audio    ),
      .aud_rst_n  ( aud_rst_n    ),
      .pix_clk    ( pixel_clk    ),
      .pix_rst_n  ( pix_rst_n    ),
      .btn_c      ( button_c_d   ),
      .btn_u      ( button_u_d   ),
      .btn_d      ( button_d_d   ),
      .btn_l      ( button_l_d   ),
      .btn_r      ( button_r_d   ),
      .sw         ( SW           ),
      .aud_pwm    ( aud_pwm_loc  ),
      .uart_rx    ( UART_TXD_IN  ),
      .uart_tx    ( UART_RXD_OUT ),
      .sd_reset   ( SD_RESET     ),
      .sd_cs      ( SD_DAT3      ),
      .sd_sck     ( SD_SCK       ),
      .sd_mosi    ( SD_CMD       ),
      .sd_miso    ( SD_DAT0      ),
      .vga_r      ( VGA_R        ),
      .vga_g      ( VGA_G        ),
      .vga_b      ( VGA_B        ),
      .vga_hs     ( VGA_HS       ),
      .vga_vs     ( VGA_VS       ),
      /* verilator lint_off PINCONNECTEMPTY */
      .vga_de     (              ),
      .vga_h      (              ),
      .vga_v      (              ),
      /* verilator lint_on PINCONNECTEMPTY */
      .play       ( play         ),
      .volume     ( volume       ),
      .note_index ( note_index   ),
      .track      ( track        ),
      .octave     ( octave       ),
      .leds       ( LED          )
    );

    // open-drain output: '1' is set by the on-board pull-up to the clean analog 3.3V rail
    assign AUD_PWM = aud_pwm_loc ? 1'bz : 1'b0;
    // amplifier always on: silence is the middle level, so there is no pop
    assign AUD_SD  = 1'b1;
//____________________________________________________________________________//

//------------- Seven Segments Indicators                        -------------//
    // track number, volume (hex), note and octave of the synth:  "...1 A C4"
    reg   [12:0]  digital_clock_divider;
    logic [ 3:0]  note_hex;

    always_ff @( posedge clk_5mhz0d ) begin
      if ( !rst_n )
        digital_clock_divider <= 0;
      else
        digital_clock_divider <= digital_clock_divider + 1;
    end

    always_comb begin
      case ( note_index )
        3'd0:    note_hex = 'hc;  // C
        3'd1:    note_hex = 'hd;  // D
        3'd2:    note_hex = 'he;  // E
        3'd3:    note_hex = 'hf;  // F
        3'd4:    note_hex = 'h6;  // G
        3'd5:    note_hex = 'ha;  // A
        default: note_hex = 'hb;  // b
      endcase
    end

    // values change rarely; the display only shows them, a glitch for one refresh is invisible
    sevseg_ctrl seven_segments_controller (
      .clk                    ( digital_clock_divider [12]   ),
      .arst_n                 ( rst_n                        ),
      .sevseg_32bit_hex_val   ( { 16'h0, 4'( track ) + 4'd1, volume, note_hex, 4'( octave ) + 4'd1 } ),
      .seg_active_n           ( {CG, CF, CE, CD, CC, CB, CA} ),
      .don_active_n           ( DP                           ),
      .anodes                 ( AN                           )
    );
//____________________________________________________________________________//

endmodule
