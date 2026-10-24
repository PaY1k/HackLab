module audio_nexys_a7 (
  //----------- CLOCK                                            -------------//
    input   logic            CLK100MHZ ,
  //----------- Switches                                         -------------//
    input   logic  [15:0]    SW        ,
  //----------- Buttons                                          -------------//
    input   logic            BTNC      ,
    input   logic            BTNU      ,
    input   logic            BTNL      ,
    input   logic            BTNR      ,
    input   logic            BTND      ,
    input   logic            CPU_RESETN,
  //----------- Seven Segments Indicators                        -------------//
    output  logic            DP, CG, CF, CE, CD, CC, CB, CA,
    output  logic  [ 7:0]    AN        ,
  //----------- Audio                                            -------------//
    output  logic            AUD_PWM   ,
    output  logic            AUD_SD    ,
  //----------- VGA                                              -------------//
    output  logic  [ 3:0]    VGA_R     ,
    output  logic  [ 3:0]    VGA_G     ,
    output  logic  [ 3:0]    VGA_B     ,
    output  logic            VGA_HS    ,
    output  logic            VGA_VS
);

//------------- Signals declaration                              -------------//
  //----------- Clocks                                           -----------//
    wire          clk_audio    ;     // 49.15865 MHz, phase 0 degrees
    wire          clk_5mhz0d   ;     // 4.993 MHz,    phase 0 degrees
    wire          pixel_clk    ;     // 39.941 MHz,   SVGA 800x600@60 pixel clock
    wire          pll_locked   ;
    wire          pll_rst_n    ;
    wire          rst_n        ;     // reset in the 5 MHz domain
    wire          aud_rst_n    ;     // rst_n released synchronously to clk_audio
    wire          pix_rst_n    ;     // rst_n released synchronously to pixel_clk
  //----------- Buttons state                                    -----------//
    logic         button_c, button_c_d, button_c_u;
    logic         button_u, button_u_d, button_u_u;
    logic         button_d, button_d_d, button_d_u;
    logic         button_l, button_l_d, button_l_u;
    logic         button_r, button_r_d, button_r_u;
  //----------- Audio management registers                       -----------//
    reg           play        ;
    reg  [3:0]    volume      ;
    reg  [2:0]    note_index  ;
  //----------- Audio data path                                  -----------//
    wire  [15:0]  sample        ;
    wire          valid         ;
    wire          ready         ;
    wire  [19:0]  vol_mult      ;
    wire  [15:0]  sample_scaled ;
    wire  [31:0]  fifo_wr_data  ;
    wire          fifo_wr_en    ;
    wire          fifo_full     ;
    wire  [31:0]  fifo_rd_data  ;
    wire          fifo_rd_en    ;
    wire          fifo_empty    ;
    wire          aud_pwm_loc   ;
  //----------- Seven Segments Indicators                        -----------//
    wire  [31:0]  sevseg_32bit_hex_val ;
    logic [ 3:0]  note_hex             ;   // note letter as a hex digit: C, D, E, F, 6 = G, A, b
    wire  [ 3:0]  octave_digit         ;   // octave number 1..8
  //----------- Switches synchronized to clk_audio               -----------//
    (* ASYNC_REG = "TRUE" *) logic [2:0] sw_sync1, sw_sync2;
    wire  [ 2:0]  octave        ;   // SW[2:0] in the clk_audio domain
//____________________________________________________________________________//

//------------- Clock & Reset                                      -----------//
  //----------- PLL                                              ---------//
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

  //----------- Reset synchronizers                              ---------//
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

//------------- IO Pads assertions                               -------------//
  //----------- Debouncers for Buttons                           -----------//
    button_debouncer dbns_center (
      .clk         ( clk_audio  ),
      .arst_n      ( aud_rst_n  ),
      .sw_i        ( BTNC       ),
      .sw_state_o  ( button_c   ),
      .sw_down_o   ( button_c_d ),
      .sw_up_o     ( button_c_u )
    );
    button_debouncer dbns_up (
      .clk         ( clk_audio  ),
      .arst_n      ( aud_rst_n  ),
      .sw_i        ( BTNU       ),
      .sw_state_o  ( button_u   ),
      .sw_down_o   ( button_u_d ),
      .sw_up_o     ( button_u_u )
    );
    button_debouncer dbns_left (
      .clk         ( clk_audio  ),
      .arst_n      ( aud_rst_n  ),
      .sw_i        ( BTNL       ),
      .sw_state_o  ( button_l   ),
      .sw_down_o   ( button_l_d ),
      .sw_up_o     ( button_l_u )
    );
    button_debouncer dbns_right (
      .clk         ( clk_audio  ),
      .arst_n      ( aud_rst_n  ),
      .sw_i        ( BTNR       ),
      .sw_state_o  ( button_r   ),
      .sw_down_o   ( button_r_d ),
      .sw_up_o     ( button_r_u )
    );
    button_debouncer dbns_down (
      .clk         ( clk_audio  ),
      .arst_n      ( aud_rst_n  ),
      .sw_i        ( BTND       ),
      .sw_state_o  ( button_d   ),
      .sw_down_o   ( button_d_d ),
      .sw_up_o     ( button_d_u )
    );
  //----------- Switches: 2-FF synchronizer                      -----------//
    // SW are asynchronous to clk_audio; feeding them straight into logic
    // may cause rare glitches (metastability)
    always_ff @( posedge clk_audio ) begin
      sw_sync1 <= SW [2:0];
      sw_sync2 <= sw_sync1;
    end
    assign octave = sw_sync2;
  //------------- Control logic                                  -----------//
    button_ctrl button_ctrl_inst (
      .clk         ( clk_audio  ),
      .rst_n       ( aud_rst_n  ),
      .button_c    ( button_c_d ),
      .button_u    ( button_u_d ),
      .button_d    ( button_d_d ),
      .button_r    ( button_r_d ),
      .button_l    ( button_l_d ),
      .play        ( play       ),
      .volume      ( volume     ),
      .note_index  ( note_index )
    );
//____________________________________________________________________________//

//------------- Seven Segments Indicators                        -------------//
  //----------- Digital clock divider                            -----------//
    reg [12:0] digital_clock_divider;

    always_ff @( posedge clk_5mhz0d ) begin
      if ( !rst_n )
        digital_clock_divider <= 0;
      else
        digital_clock_divider <= digital_clock_divider + 1;
    end

  //----------- Seven Segments logic                             -----------//
    sevseg_ctrl seven_segments_controller (
      .clk                    ( digital_clock_divider [12]   ),
      .arst_n                 ( rst_n                        ),
      .sevseg_32bit_hex_val   ( sevseg_32bit_hex_val         ),
      .seg_active_n           ( {CG, CF, CE, CD, CC, CB, CA} ),
      .don_active_n           ( DP                           ),
      .anodes                 ( AN                           )
    );
    assign octave_digit = {1'b0, SW [2:0]} + 4'd1;
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

//------------- Audio data path                                  -------------//
  //----------- Tone generator                                   -----------//
    tone_generator tone_generator_inst (
      .clk         ( clk_audio   ),
      .rst_n       ( aud_rst_n   ),
      .note_index  ( note_index  ),
      .octave_sel  ( octave      ),
      .sample      ( sample      ),
      .valid       ( valid       ),
      .ready       ( ready       )
    );
    
    assign vol_mult      = sample * volume;
    assign sample_scaled = vol_mult [19:4];
  //----------- FIFO                                             -----------//
    // Tempo is set by pwm: it reads one sample per 1024 clocks (48.006 kHz);
    // the generator steps once per written sample, so the full FIFO holds
    // 256 samples = ~5.3 ms of sound (latency of note/volume/pause changes) 
    // but even student can't catch the 5.3 ms

    assign ready = play && !fifo_full;

    assign fifo_wr_en   = ready;
    assign fifo_wr_data = {16'b0, sample_scaled};

    fifo fifo_inst (
      .clk     ( clk_audio    ),
      .rst_n   ( aud_rst_n    ),
      .wr_data ( fifo_wr_data ),
      .wr_en   ( fifo_wr_en   ),
      .full    ( fifo_full    ),
      .rd_data ( fifo_rd_data ),
      .rd_en   ( fifo_rd_en   ),
      .empty   ( fifo_empty   )
    );
  //----------- PWM                                              -----------//
    pwm pwm_inst (
      .clk          ( clk_audio    ),
      .rst_n        ( aud_rst_n    ),
      .aud_pwm      ( aud_pwm_loc  ),
      .aud_en       ( AUD_SD       ),
      .fifo_rd_data ( fifo_rd_data ),
      .fifo_rd_en   ( fifo_rd_en   ),
      .fifo_empty   ( fifo_empty   )
    );
    // open-drain output: '1' is set by the on-board pull-up to the clean analog 3.3V rail
    assign AUD_PWM = aud_pwm_loc ? 1'bz : 1'b0;
//____________________________________________________________________________//

//------------- VGA: player screen                              -------------//
    // status crosses to pixel_clk inside player_screen (cdc_bus)
    player_screen player_screen (
      .aud_clk      ( clk_audio          ),
      .aud_rst_n    ( aud_rst_n          ),
      .play         ( play               ),
      .volume       ( volume             ),
      .note_index   ( note_index         ),
      .octave       ( octave             ),
      .sample_valid ( fifo_rd_en         ),
      .sample       ( fifo_rd_data[15:0] ),
      .aud_en       ( AUD_SD             ),
      .track_idx    ( 3'd0               ),
      .len_bcd      ( 16'h0000           ),
      .len_valid    ( 1'b0               ),
      .progress     ( 10'd0              ),
      .time_clear   ( 1'b0               ),
      .pix_clk      ( pixel_clk          ),
      .pix_rst_n    ( pix_rst_n          ),
      .vga_r        ( VGA_R              ),
      .vga_g        ( VGA_G              ),
      .vga_b        ( VGA_B              ),
      .vga_hs       ( VGA_HS             ),
      .vga_vs       ( VGA_VS             ),
      /* verilator lint_off PINCONNECTEMPTY */
      .vga_de       (                    ),
      .vga_h        (                    ),
      .vga_v        (                    )
      /* verilator lint_on PINCONNECTEMPTY */
    );
//____________________________________________________________________________//

endmodule
