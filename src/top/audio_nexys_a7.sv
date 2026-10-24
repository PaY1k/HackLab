 audio_nexys_a7 
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
    input   logic            PS2_CLK,
    input   logic            PS2_DATA,
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
;

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
  //------------- MIDI
    logic [7:0]   byte_data;
    logic         byte_valid;
    logic         frame_error;
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
  //----------- VGA Controller                                   -----------//
    wire  [10:0]  h_coord       ;   // pixel coordinates, 0..1055
    wire  [ 9:0]  v_coord       ;   //                    0..627
    wire  [ 3:0]  red, green, blue; // pixel color
    // Timing signals - don't touch these:
    wire          h_sync, v_sync;   // horizontal & vertical synchronization
    wire          disp_enbl     ;   // image output is allowed
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
  //------------- Control logic                                  -----------//
    button_ctrl button_ctrl_inst (
      .clk         ( clk_audio  ),
      .rst_n       ( aud_rst_n  ),
      .button_c    ( button_c_d ),
      .button_u    ( button_u_d ),
      .button_d    ( button_d_d ),
      .button_r    ( button_r_d ),
      .button_l    ( button_l_d ),
      // .play        ( play       ),
      .volume      ( volume     )
      // .note_index  ( note_index )
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
      .octave_sel  ( SW [2:0]    ),
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

//------------- VGA                                              -------------//
  //----------- Picture: Sber logo, then text                    -----------//
    vga_demo vga_demo (
      .pixel_clk  ( pixel_clk ),
      .rst_n      ( pix_rst_n ),
      .h_coord    ( h_coord   ),
      .v_coord    ( v_coord   ),
      .red        ( red       ),
      .green      ( green     ),
      .blue       ( blue      )
    );
  //----------- VGA controller (SVGA 800x600@60 timing)          -----------//
    display_ctrl display_ctrl (
      .pixel_clk  ( pixel_clk ), // Pixel clock 39.941 MHz
      .rst_n      ( pix_rst_n ), // Active low synchronous reset
      .h_sync     ( h_sync    ), // horizontal sync signal
      .v_sync     ( v_sync    ), // vertical sync signal
      .disp_enbl  ( disp_enbl ), // display enable (0 = all colors must be blank)
      .h_coord    ( h_coord   ), // horizontal pixel coordinate
      .v_coord    ( v_coord   )  // vertical pixel coordinate
    );
//MIDI CONTROLLER
    ps2_rx ps2_rx (
    .clk         (clk_audio),
    .rst_n       (aud_rst_n),
    .ps2_clk     (PS2_CLK),
    .ps2_data    (PS2_DATA),
    .byte_data   (byte_data),
    .byte_valid  (byte_valid),
    .frame_error (frame_error)
    );
    
    midi_decoder midi_decoder (
    .clk        (clk_audio),
    .rst_n      (aud_rst_n),
    .midi_data  (byte_data),
    .midi_valid (byte_valid),
    .note_index (note_index),
    .play       (play)
    );
  //----------- VGA reg                                          -----------//
      always_ff @(posedge pixel_clk) begin
        if (disp_enbl == 1'b1) begin
          VGA_R <= red  ;
          VGA_B <= blue ;
          VGA_G <= green;
        end
        else begin
          VGA_R <= 4'd0;
          VGA_B <= 4'd0;
          VGA_G <= 4'd0;
        end
          VGA_HS <= h_sync;
          VGA_VS <= v_sync;
      end
//____________________________________________________________________________//


