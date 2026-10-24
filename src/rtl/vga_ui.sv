// Music player screen, SVGA 800x600, pixel_clk domain.
//
// Layers (top to bottom priority):
//   splash (logo + loading bar, first ~3.4 s after reset)
//   text      : 100x37 cells of 8x16 font, CP866 (Russian), screen_text.mem
//   big time  : mm:ss, font scaled x4
//   scope     : 512 samples with trigger, glow around the line
//   progress bar + knob, play / prev / next buttons, volume bars
//   piano     : 3 octaves, keys from key_mask light up
//   playlist  : highlight of the current track + animated mini equalizer
//   panels    : rounded rectangles, header with gradient accent line
//   background: vertical gradient
// Colors are mixed with 8 bits per channel (constants are written as 6-bit
// values) and reduced to the 4-bit VGA DAC with 4x4 ordered (Bayer) dithering,
// so gradients have no visible bands.
//
// Pipeline: color for (h_coord, v_coord) appears LATENCY clocks later.
// h_sync / v_sync / disp_enbl / coordinates are delayed by the same amount
// and come out as out_*: register them in the top together with the color.
//
// Text cells that change at run time are written by this module during the
// vertical blanking (status, note, volume, track length). Other modules can
// write any cell through txt_we / txt_addr / txt_data (addr = row*128 + col,
// data = {color[3:0], cp866_char[7:0]}), e.g. track names from the SD card.
module vga_ui #(
    parameter  FONT_FILE   = "font8x16.mem",
    parameter  TEXT_FILE   = "screen_text.mem",
    parameter  SPLASH_LOG2 = 27                  // splash 2^27 / 39.941 MHz = 3.4 s
)(
  //--------- Clock & Reset                      --------//
    input  wire           pixel_clk   ,
    input  wire           rst_n       ,
  //--------- From display_ctrl                  --------//
    input  wire  [10:0]   h_coord     ,
    input  wire  [ 9:0]   v_coord     ,
    input  wire           h_sync      ,
    input  wire           v_sync      ,
    input  wire           disp_enbl   ,
  //--------- Player status (pixel domain!)      --------//
    input  wire           play        ,
    input  wire  [ 3:0]   volume      ,   // 0..15
    input  wire  [ 2:0]   note_index  ,   // 0..6 = C D E F G A B
    input  wire  [ 2:0]   octave      ,   // 0..7, shown as 1..8
    input  wire  [15:0]   time_bcd    ,   // elapsed mm:ss
    input  wire  [15:0]   len_bcd     ,   // track length mm:ss
    input  wire           len_valid   ,   // 0: length unknown, shows --:--
    input  wire  [ 9:0]   progress    ,   // 0..1023 = position in the track
    input  wire  [ 2:0]   track_idx   ,   // highlighted playlist row 0..5
    input  wire  [35:0]   key_mask    ,   // piano keys to light, bit = octave*12 + semitone
  //--------- Oscilloscope buffer                --------//
    output wire  [ 8:0]   scope_addr  ,
    input  wire  [ 7:0]   scope_data  ,   // 1 clock latency, 128 = silence
    output logic          frame_start ,   // one pulse per frame, at line 600
  //--------- External text write                --------//
    input  wire           txt_we      ,
    input  wire  [12:0]   txt_addr    ,
    input  wire  [11:0]   txt_data    ,
  //--------- Output, delayed by LATENCY          --------//
    output logic [ 3:0]   red         ,
    output logic [ 3:0]   green       ,
    output logic [ 3:0]   blue        ,
    output logic          out_hs      ,
    output logic          out_vs      ,
    output logic          out_de      ,
    output logic [10:0]   out_h       ,
    output logic [ 9:0]   out_v
);

  localparam LATENCY = 4;

//------------- Delay lines for coordinates and sync             -------------//
  logic [10:0] h_d  [1:LATENCY];
  logic [ 9:0] v_d  [1:LATENCY];
  logic        hs_d [1:LATENCY];
  logic        vs_d [1:LATENCY];
  logic        de_d [1:LATENCY];

  always_ff @( posedge pixel_clk ) begin
    h_d[1] <= h_coord;  v_d[1] <= v_coord;  hs_d[1] <= h_sync;  vs_d[1] <= v_sync;  de_d[1] <= disp_enbl;
    for ( int i = 2; i <= LATENCY; i++ ) begin
      h_d[i] <= h_d[i-1];  v_d[i] <= v_d[i-1];  hs_d[i] <= hs_d[i-1];  vs_d[i] <= vs_d[i-1];  de_d[i] <= de_d[i-1];
    end
  end

  wire [10:0] h0 = h_coord;  wire [9:0] v0 = v_coord;   // stage 0
  wire [10:0] h1 = h_d[1];   wire [9:0] v1 = v_d[1];    // stage 1
  wire [10:0] h2 = h_d[2];   wire [9:0] v2 = v_d[2];    // stage 2: layers are mixed here
  wire [10:0] h3 = h_d[3];   wire [9:0] v3 = v_d[3];    // stage 3: dithering

  assign out_h  = h_d[LATENCY];
  assign out_v  = v_d[LATENCY];
  assign out_hs = hs_d[LATENCY];
  assign out_vs = vs_d[LATENCY];
  assign out_de = de_d[LATENCY];
//____________________________________________________________________________//

//------------- Helpers                                          -------------//
  // 6-bit components -> 8-bit color {r, g, b}
  function automatic [23:0] rgb (input [5:0] r, input [5:0] g, input [5:0] b);
    rgb = { r, r[5:4], g, g[5:4], b, b[5:4] };
  endfunction

  function automatic [10:0] absdiff11 (input [10:0] a, input [10:0] b);
    absdiff11 = ( a >= b ) ? a - b : b - a;
  endfunction

  // Rounded rectangle [x0, x1) x [y0, y1), corner radius 8: {inside, border}
  function automatic [1:0] rrect (input [10:0] x, input [9:0] y,
                                  input [10:0] x0, input [10:0] x1, input [9:0] y0, input [9:0] y1);
    logic [2:0] dx, dy;
    logic [6:0] r2;
    logic       in_box;
    in_box = ( x >= x0 ) && ( x < x1 ) && ( y >= y0 ) && ( y < y1 );
    dx = ( x < x0 + 11'd8 ) ? 3'( x0 + 11'd7 - x ) : ( x >= x1 - 11'd8 ) ? 3'( x - ( x1 - 11'd8 ) ) : 3'd0;
    dy = ( y < y0 + 10'd8 ) ? 3'( y0 + 10'd7 - y ) : ( y >= y1 - 10'd8 ) ? 3'( y - ( y1 - 10'd8 ) ) : 3'd0;
    r2 = dx * dx + dy * dy;
    rrect[1] = in_box && ( r2 <= 7'd56 );
    rrect[0] = in_box && ( r2 <= 7'd56 ) && ( r2 > 7'd36 );
  endfunction

  // Text color palette, attr -> 6-bit RGB
  function automatic [23:0] palette (input [3:0] attr);
    case ( attr )
      4'd1:    palette = rgb( 38, 42, 52 );   // grey
      4'd2:    palette = rgb( 22, 26, 38 );   // dim
      4'd3:    palette = rgb( 16, 54, 26 );   // green
      4'd4:    palette = rgb( 12, 48, 60 );   // cyan
      4'd5:    palette = rgb( 62, 52, 14 );   // yellow
      4'd6:    palette = rgb( 62, 20, 20 );   // red
      4'd7:    palette = rgb(  4,  6, 10 );   // dark
      default: palette = rgb( 58, 60, 62 );   // white
    endcase
  endfunction
//____________________________________________________________________________//

//------------- Frame counter, splash timer                      -------------//
  logic [7:0]             frame_cnt;
  logic [SPLASH_LOG2:0]   splash_cnt;
  wire                    splash = !splash_cnt[SPLASH_LOG2];

  always_ff @( posedge pixel_clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      frame_cnt   <= '0;
      splash_cnt  <= '0;
      frame_start <= 1'b0;
    end
    else begin
      frame_start <= ( v0 == 10'd600 ) && ( h0 == 11'd0 );
      if ( frame_start )
        frame_cnt <= frame_cnt + 1'b1;
      if ( splash )
        splash_cnt <= splash_cnt + 1'b1;
    end
  end
//____________________________________________________________________________//

//------------- Font ROM (2 read ports) and text RAM             -------------//
  logic [7:0]  font_mem [0:4095];          // {char, row} -> 8 pixels, bit 7 = left
  logic [11:0] text_mem [0:5119];          // row*128 + col -> {attr, char}

  initial begin
    $readmemh( FONT_FILE, font_mem );
    $readmemh( TEXT_FILE, text_mem );
  end

  // Dynamic cells, written during vertical blanking
  localparam N_DYN = 20;
  logic [4:0]  dyn_idx;
  logic        dyn_active;
  logic [12:0] dyn_addr;
  logic [11:0] dyn_data;

  // CP866 codes for the status text
  function automatic [7:0] status_char (input playing, input [3:0] i);
    // " ИГРАЕТ" / " ПАУЗА" after the icon
    case ( i )
      4'd0:    status_char = playing ? 8'h02 : 8'h03;              // play / pause icon
      4'd2:    status_char = playing ? 8'h88 : 8'h8F;              // И / П
      4'd3:    status_char = playing ? 8'h83 : 8'h80;              // Г / А
      4'd4:    status_char = playing ? 8'h90 : 8'h93;              // Р / У
      4'd5:    status_char = playing ? 8'h80 : 8'h87;              // А / З
      4'd6:    status_char = playing ? 8'h85 : 8'h80;              // Е / А
      4'd7:    status_char = playing ? 8'h92 : 8'h20;              // Т
      default: status_char = 8'h20;
    endcase
  endfunction

  function automatic [7:0] note_char (input [2:0] n);
    case ( n )
      3'd0: note_char = "C";  3'd1: note_char = "D";  3'd2: note_char = "E";
      3'd3: note_char = "F";  3'd4: note_char = "G";  3'd5: note_char = "A";
      default: note_char = "B";
    endcase
  endfunction

  always_comb begin
    dyn_addr = 13'd0;
    dyn_data = 12'h020;
    if ( dyn_idx < 5'd11 ) begin                                   // row 1, col 84..94: status
      dyn_addr = 13'( 1 * 128 + 84 ) + 13'( dyn_idx );
      dyn_data = { play ? 4'd3 : 4'd5, status_char( play, dyn_idx[3:0] ) };
    end
    else if ( dyn_idx == 5'd11 ) begin                             // row 30, col 26: note
      dyn_addr = 13'( 30 * 128 + 26 );
      dyn_data = { 4'd4, note_char( note_index ) };
    end
    else if ( dyn_idx == 5'd12 ) begin                             // row 30, col 27: octave
      dyn_addr = 13'( 30 * 128 + 27 );
      dyn_data = { 4'd4, 8'h31 + 8'( octave ) };
    end
    else if ( dyn_idx == 5'd13 ) begin                             // row 30, col 70..71: volume
      dyn_addr = 13'( 30 * 128 + 70 );
      dyn_data = { 4'd0, ( volume >= 4'd10 ) ? 8'h31 : 8'h30 };
    end
    else if ( dyn_idx == 5'd14 ) begin
      dyn_addr = 13'( 30 * 128 + 71 );
      dyn_data = { 4'd0, 8'h30 + 8'( ( volume >= 4'd10 ) ? volume - 4'd10 : volume ) };
    end
    else begin                                                     // row 33, col 92..96: length
      dyn_addr = 13'( 33 * 128 + 92 ) + 13'( dyn_idx - 5'd15 );
      case ( dyn_idx - 5'd15 )
        5'd0:    dyn_data = { 4'd1, len_valid ? 8'h30 + 8'( len_bcd[15:12] ) : 8'h2D };
        5'd1:    dyn_data = { 4'd1, len_valid ? 8'h30 + 8'( len_bcd[11: 8] ) : 8'h2D };
        5'd2:    dyn_data = { 4'd1, 8'h3A };
        5'd3:    dyn_data = { 4'd1, len_valid ? 8'h30 + 8'( len_bcd[ 7: 4] ) : 8'h2D };
        default: dyn_data = { 4'd1, len_valid ? 8'h30 + 8'( len_bcd[ 3: 0] ) : 8'h2D };
      endcase
    end
  end

  always_ff @( posedge pixel_clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      dyn_idx    <= '0;
      dyn_active <= 1'b0;
    end
    else if ( frame_start ) begin
      dyn_idx    <= '0;
      dyn_active <= 1'b1;
    end
    else if ( dyn_active && !txt_we ) begin                        // external writes go first
      dyn_idx <= dyn_idx + 1'b1;
      if ( dyn_idx == 5'( N_DYN - 1 ) )
        dyn_active <= 1'b0;
    end
  end

  // Text RAM: one write port, one read port
  always_ff @( posedge pixel_clk ) begin
    if ( txt_we )
      text_mem[txt_addr] <= txt_data;
    else if ( dyn_active )
      text_mem[dyn_addr] <= dyn_data;
  end

  // Stage 0 -> 1: text cell
  logic [11:0] text_q;                      // stage 1
  wire  [12:0] text_raddr = { v0[9:4], h0[9:3] };     // v0 <= 627 -> row <= 39 -> addr < 5120
  always_ff @( posedge pixel_clk )
    text_q <= text_mem[text_raddr];

  // Stage 1 -> 2: glyph row of the text cell (font port A)
  logic [7:0]  glyph_q;                     // stage 2
  logic [3:0]  attr2;
  always_ff @( posedge pixel_clk ) begin
    glyph_q <= font_mem[{ text_q[7:0], v1[3:0] }];
    attr2   <= text_q[11:8];
  end
  wire text_px2 = glyph_q[3'd7 - h2[2:0]];

  // Big time digits mm:ss, x4: x 32..191, y 504..567 (font port B)
  localparam BIG_X0 = 11'd32, BIG_Y0 = 10'd504;
  wire [10:0] big_dx0  = h0 - BIG_X0;
  wire [ 9:0] big_dy0  = v0 - BIG_Y0;
  wire [ 2:0] big_ci0  = big_dx0[7:5];
  logic [7:0] big_code0;
  always_comb begin
    case ( big_ci0 )
      3'd0:    big_code0 = 8'h30 + 8'( time_bcd[15:12] );
      3'd1:    big_code0 = 8'h30 + 8'( time_bcd[11: 8] );
      3'd2:    big_code0 = ( play || frame_cnt[5] ) ? 8'h3A : 8'h20;   // colon blinks on pause
      3'd3:    big_code0 = 8'h30 + 8'( time_bcd[ 7: 4] );
      default: big_code0 = 8'h30 + 8'( time_bcd[ 3: 0] );
    endcase
  end

  logic [7:0] big_q;                         // stage 1
  always_ff @( posedge pixel_clk )
    big_q <= font_mem[{ big_code0, big_dy0[5:2] }];

  wire [10:0] big_dx1 = h1 - BIG_X0;
  wire        big_area1 = ( h1 >= BIG_X0 ) && ( h1 < BIG_X0 + 11'd160 ) &&
                          ( v1 >= BIG_Y0 ) && ( v1 < BIG_Y0 + 10'd64 );
  wire        big_px1 = big_area1 && big_q[3'd7 - big_dx1[4:2]];
//____________________________________________________________________________//

//------------- Scope                                            -------------//
  localparam SC_X0 = 11'd268, SC_Y0 = 10'd96;    // 512 x 240 area
  assign scope_addr = 9'( h0 - SC_X0 );

  // stage 1: sample -> y (0..239 inside the area)
  wire [7:0] sc_inv1 = 8'd255 - scope_data;
  wire [9:0] sc_y1   = SC_Y0 + 10'( sc_inv1 - ( sc_inv1 >> 4 ) );

  logic [9:0] sc_y_cur2, sc_y_prev2;          // stage 2: this column and the previous one
  logic       sc_first2;
  always_ff @( posedge pixel_clk ) begin
    sc_y_cur2  <= sc_y1;
    sc_y_prev2 <= sc_y_cur2;
    sc_first2  <= ( h1 == SC_X0 );
  end
//____________________________________________________________________________//

//------------- Logo ROM (splash)                                -------------//
  localparam LOGO_X0 = 11'd336, LOGO_Y0 = 10'd236;
  wire [10:0] logo_dx1 = h1 - LOGO_X0;
  wire [ 9:0] logo_dy1 = v1 - LOGO_Y0;
  wire [11:0] logo_word2;                    // {B, G, R}, 0 = transparent, stage 2

  sber_logo_rom sber_logo_rom (
    .clk  ( pixel_clk                      ),
    .addr ( { logo_dy1[6:0], logo_dx1[6:0] } ),
    .word ( logo_word2                     )
  );
//____________________________________________________________________________//

//------------- Stage 1: geometry (status is static within a frame) -----------//
  // Everything here depends only on coordinates and slow status signals,
  // it is computed one stage early and registered to keep stage 2 short.
  typedef struct packed {
    logic        header, accent;
    logic [1:0]  list, scope_p, piano_p, bottom;     // {inside, border}
    logic        scope_area, scope_grid, scope_mid;
    logic [1:0]  item;                               // active playlist row
    logic        item_bar, eq_bar;
    logic        key_white, key_black, key_gap, key_shade, key_lit;
    logic        vol_bar, vol_lit;
    logic [1:0]  vol_zone;                           // 0 green, 1 yellow, 2 red
    logic        pb_track, pb_fill, knob, knob_glow;
    logic        btn_circle, btn_glow, btn_icon, side_icon;
    logic        big;
    logic        logo_area, splash_bar, splash_fill;
  } geo_t;

  geo_t g1, g2;

  // Piano: 21 white keys x 32 px at x 64..735, y 360..431; black keys 20 x 48
  localparam PK_X0 = 11'd64, PK_Y0 = 10'd360;

  function automatic [3:0] white_semi (input [2:0] w);
    case ( w )
      3'd0: white_semi = 4'd0;   3'd1: white_semi = 4'd2;   3'd2: white_semi = 4'd4;
      3'd3: white_semi = 4'd5;   3'd4: white_semi = 4'd7;   3'd5: white_semi = 4'd9;
      default: white_semi = 4'd11;
    endcase
  endfunction

  logic [10:0] pk_dx;
  logic [4:0]  pk_wk;            // white key 0..20
  logic [1:0]  pk_oct;
  logic [2:0]  pk_w;             // white key inside the octave
  logic [4:0]  pk_px;            // x inside the white key
  logic        pk_black_r, pk_black_l;
  logic [5:0]  pk_key;           // key number = octave*12 + semitone
  logic [10:0] knob_x;
  logic [10:0] kdx;
  logic [9:0]  kdy;
  logic [10:0] bdx;
  logic [9:0]  bdy;
  logic [10:0] vdx;
  logic [3:0]  vk;
  logic [4:0]  vh;
  logic [9:0]  item_y0;
  logic [4:0]  eq_h0, eq_h1, eq_h2, eq_h;
  logic [10:0] eq_dx;
  logic [4:0]  wave0, wave1, wave2;

  function automatic [4:0] tri5 (input [4:0] t);  // triangle wave 0..15..0
    tri5 = t[4] ? 5'( ~t[3:0] ) : 5'( t[3:0] );
  endfunction

  always_comb begin
    g1 = '0;

    // header and panels
    g1.header  = ( v1 < 10'd48 );
    g1.accent  = ( v1 == 10'd46 ) || ( v1 == 10'd47 );
    g1.list    = rrect( h1, v1, 11'd16,  11'd248, 10'd56,  10'd344 );
    g1.scope_p = rrect( h1, v1, 11'd264, 11'd784, 10'd56,  10'd344 );
    g1.piano_p = rrect( h1, v1, 11'd16,  11'd784, 10'd352, 10'd440 );
    g1.bottom  = rrect( h1, v1, 11'd16,  11'd784, 10'd448, 10'd596 );

    // scope area and grid (every 64 px horizontally, 40 px vertically, dotted)
    g1.scope_area = ( h1 >= SC_X0 ) && ( h1 < SC_X0 + 11'd512 ) && ( v1 >= SC_Y0 ) && ( v1 < SC_Y0 + 10'd240 );
    g1.scope_mid  = ( v1 == SC_Y0 + 10'd120 );
    g1.scope_grid = ( ( ( h1 - SC_X0 ) & 11'd63 ) == 11'd0 || ( ( v1 - SC_Y0 ) % 10'd40 ) == 10'd0 ) && ( h1[1:0] == v1[1:0] );

    // playlist: active row highlight 24..240 x (88 + 32*i) .. +32
    item_y0  = 10'd88 + { 2'b0, track_idx, 5'b0 };
    g1.item  = rrect( h1, v1, 11'd24, 11'd240, item_y0, item_y0 + 10'd32 );
    g1.item_bar = g1.item[1] && ( h1 < 11'd27 );
    // mini equalizer: 3 bars x 4 px at x 216, 223, 230; bottom at item_y0 + 24
    wave0  = tri5( frame_cnt[4:0] );
    wave1  = tri5( frame_cnt[4:0] + 5'd11 );
    wave2  = tri5( frame_cnt[4:0] + 5'd23 );
    eq_h0 = play ? 5'd3 + wave0 : 5'd2;
    eq_h1 = play ? 5'd3 + wave1 : 5'd2;
    eq_h2 = play ? 5'd3 + wave2 : 5'd2;
    eq_dx = h1 - 11'd216;
    eq_h  = ( eq_dx < 11'd7 ) ? eq_h0 : ( eq_dx < 11'd14 ) ? eq_h1 : eq_h2;
    g1.eq_bar = ( h1 >= 11'd216 ) && ( eq_dx < 11'd18 ) && ( ( eq_dx % 11'd7 ) < 11'd4 ) &&
                ( v1 <  item_y0 + 10'd24 ) && ( v1 >= item_y0 + 10'd24 - 10'( eq_h ) );

    // piano
    pk_dx  = h1 - PK_X0;
    pk_wk  = pk_dx[9:5];
    pk_oct = ( pk_wk >= 5'd14 ) ? 2'd2 : ( pk_wk >= 5'd7 ) ? 2'd1 : 2'd0;
    pk_w   = 3'( pk_wk - 5'( pk_oct ) * 5'd7 );
    pk_px  = pk_dx[4:0];
    pk_black_r = ( pk_px >= 5'd22 ) && ( pk_w != 3'd2 ) && ( pk_w != 3'd6 ) && ( pk_wk != 5'd20 );
    pk_black_l = ( pk_px <  5'd10 ) && ( pk_w != 3'd0 ) && ( pk_w != 3'd3 );
    if ( ( h1 >= PK_X0 ) && ( h1 < PK_X0 + 11'd672 ) && ( v1 >= PK_Y0 ) && ( v1 < PK_Y0 + 10'd72 ) ) begin
      if ( ( pk_black_r || pk_black_l ) && ( v1 < PK_Y0 + 10'd48 ) ) begin
        g1.key_black = 1'b1;
        pk_key = 6'( pk_oct ) * 6'd12 + 6'( white_semi( pk_w ) ) + ( pk_black_r ? 6'd1 : -6'd1 );
      end
      else begin
        g1.key_white = 1'b1;
        g1.key_gap   = ( pk_px == 5'd31 ) || ( pk_px == 5'd0 );
        g1.key_shade = ( v1 >= PK_Y0 + 10'd64 );
        pk_key = 6'( pk_oct ) * 6'd12 + 6'( white_semi( pk_w ) );
      end
      g1.key_lit = key_mask[pk_key];
    end
    else
      pk_key = '0;

    // volume: 16 bars, pitch 8 px, x 648..775, bottom at y 494, height 6..28
    vdx = h1 - 11'd648;
    vk  = vdx[6:3];
    vh  = 5'd6 + 5'( vk ) + 5'( vk >> 1 );
    g1.vol_bar  = ( h1 >= 11'd648 ) && ( h1 < 11'd776 ) && ( vdx[2:0] < 3'd5 ) &&
                  ( v1 < 10'd494 ) && ( v1 >= 10'd494 - 10'( vh ) );
    g1.vol_lit  = ( vk < volume );
    g1.vol_zone = ( vk >= 4'd12 ) ? 2'd2 : ( vk >= 4'd8 ) ? 2'd1 : 2'd0;

    // progress bar x 216..727, y 530..536, knob r = 7 at (216 + progress/2, 533)
    knob_x      = 11'd216 + 11'( progress[9:1] );
    g1.pb_track = ( h1 >= 11'd216 ) && ( h1 < 11'd728 ) && ( v1 >= 10'd530 ) && ( v1 < 10'd537 );
    g1.pb_fill  = ( h1 <= knob_x );
    kdx = absdiff11( h1, knob_x );
    kdy = 10'( absdiff11( 11'( v1 ), 11'd533 ) );
    if ( kdx < 11'd11 && kdy < 10'd11 ) begin
      g1.knob      = ( kdx * kdx + kdy * kdy ) <= 11'd49;
      g1.knob_glow = ( kdx * kdx + kdy * kdy ) <= 11'd100;
    end

    // buttons: play/pause circle r = 16 at (400, 574), prev at 352, next at 448
    bdx = absdiff11( h1, 11'd400 );
    bdy = 10'( absdiff11( 11'( v1 ), 11'd574 ) );
    if ( bdx < 11'd21 && bdy < 10'd21 ) begin
      g1.btn_circle = ( bdx * bdx + bdy * bdy ) <= 11'd256;
      g1.btn_glow   = ( bdx * bdx + bdy * bdy ) <= 11'd400;
    end
    if ( play )       // pause: two bars
      g1.btn_icon = ( bdy <= 10'd7 ) && ( ( h1 >= 11'd393 && h1 < 11'd398 ) || ( h1 >= 11'd402 && h1 < 11'd407 ) );
    else              // play: triangle pointing right, x 394..409
      g1.btn_icon = ( h1 >= 11'd394 ) && ( h1 < 11'd410 ) && ( 11'( bdy ) <= ( ( 11'd410 - h1 ) >> 1 ) );
    // prev: bar + triangle pointing left; next: mirror
    g1.side_icon = ( bdy <= 10'd8 ) && (
        ( h1 >= 11'd340 && h1 < 11'd343 ) ||
        ( h1 >= 11'd343 && h1 < 11'd359 && 11'( bdy ) <= ( ( h1 - 11'd343 ) >> 1 ) ) ||
        ( h1 >= 11'd441 && h1 < 11'd457 && 11'( bdy ) <= ( ( 11'd457 - h1 ) >> 1 ) ) ||
        ( h1 >= 11'd457 && h1 < 11'd460 ) );

    g1.big = big_px1;

    // splash: logo 128x128 in the center, loading bar below
    g1.logo_area   = ( h1 >= LOGO_X0 ) && ( h1 < LOGO_X0 + 11'd128 ) && ( v1 >= LOGO_Y0 ) && ( v1 < LOGO_Y0 + 10'd128 );
    g1.splash_bar  = ( h1 >= LOGO_X0 ) && ( h1 < LOGO_X0 + 11'd128 ) && ( v1 >= 10'd392 ) && ( v1 < 10'd396 );
    g1.splash_fill = ( logo_dx1[6:0] <= splash_cnt[SPLASH_LOG2-1 -: 7] );
  end

  always_ff @( posedge pixel_clk )
    g2 <= g1;
//____________________________________________________________________________//

//------------- Stage 2: mix the layers                          -------------//
  logic [23:0] c2, c3;
  logic [7:0]  bg_r, bg_g, bg_b;
  logic [9:0]  sc_lo, sc_hi, sc_d;
  logic [5:0]  acc_b;
  logic [5:0]  big_r;

  always_comb begin
    // background: vertical gradient, dark navy, 8-bit precision
    bg_r = 8'd26 - 8'( ( 13'( v2 ) * 13'd3  ) >> 7  );   // 26 -> 12
    bg_g = 8'd34 - 8'( ( 16'( v2 ) * 16'd37 ) >> 10 );   // 34 -> 13
    bg_b = 8'd82 - 8'( ( 13'( v2 ) * 13'd5  ) >> 6  );   // 82 -> 36
    acc_b = 6'd12 + 6'( h2[9:4] );                          // accent: green -> cyan along x
    big_r = 6'd58 - 6'( ( v2 - BIG_Y0 ) >> 3 );

    // scope line: distance from the segment between this and the previous sample
    sc_lo = sc_first2 ? sc_y_cur2 : ( ( sc_y_cur2 < sc_y_prev2 ) ? sc_y_cur2 : sc_y_prev2 );
    sc_hi = sc_first2 ? sc_y_cur2 : ( ( sc_y_cur2 > sc_y_prev2 ) ? sc_y_cur2 : sc_y_prev2 );
    sc_d  = ( v2 < sc_lo ) ? sc_lo - v2 : ( v2 > sc_hi ) ? v2 - sc_hi : 10'd0;

    c2 = { bg_r, bg_g, bg_b };

    if ( splash ) begin
      if ( g2.logo_area && logo_word2 != 12'h000 )
        c2 = { logo_word2[3:0], logo_word2[3:0], logo_word2[7:4], logo_word2[7:4], logo_word2[11:8], logo_word2[11:8] };
      else if ( g2.splash_bar )
        c2 = g2.splash_fill ? rgb( 6, 44, acc_b ) : rgb( 12, 16, 32 );
    end
    else if ( text_px2 )
      c2 = ( g2.item[1] && attr2 == 4'd1 ) ? palette( 4'd0 ) : palette( attr2 );   // active row is white
    else if ( g2.big )
      c2 = rgb( big_r, 62, 63 );
    else if ( g2.scope_area && sc_d == 10'd0 )
      c2 = rgb( 28, 63, 54 );
    else if ( g2.scope_area && sc_d == 10'd1 )
      c2 = rgb( 14, 46, 42 );
    else if ( g2.scope_area && sc_d <= 10'd4 )
      c2 = rgb( 5, 20 - 6'( sc_d << 1 ), 22 - 6'( sc_d << 1 ) );
    else if ( g2.scope_area )
      c2 = g2.scope_mid ? rgb( 14, 20, 38 ) : g2.scope_grid ? rgb( 12, 16, 32 ) : rgb( 5, 7, 16 );
    else if ( g2.knob )
      c2 = rgb( 60, 62, 63 );
    else if ( g2.knob_glow && play )
      c2 = rgb( 6, 30, 22 );
    else if ( g2.pb_track )
      c2 = g2.pb_fill ? rgb( 6, 44, acc_b ) : rgb( 14, 18, 34 );
    else if ( g2.btn_circle )
      c2 = g2.btn_icon ? rgb( 2, 8, 4 ) : rgb( 10, 48, 22 );
    else if ( g2.btn_glow && play )
      c2 = rgb( 6, 22, 14 );
    else if ( g2.side_icon )
      c2 = rgb( 40, 44, 54 );
    else if ( g2.vol_bar )
      c2 = !g2.vol_lit         ? rgb( 12, 15, 28 ) :
           g2.vol_zone == 2'd2 ? rgb( 60, 22, 18 ) :
           g2.vol_zone == 2'd1 ? rgb( 60, 50, 14 ) : rgb( 14, 52, 24 );
    else if ( g2.key_black )
      c2 = g2.key_lit ? ( play ? rgb( 10, 46, 20 ) : rgb( 8, 26, 14 ) ) : rgb( 4, 5, 9 );
    else if ( g2.key_white )
      c2 = g2.key_gap   ? rgb( 16, 18, 28 ) :
           g2.key_lit   ? ( play ? rgb( 18, 58, 30 ) : rgb( 22, 40, 28 ) ) :
           g2.key_shade ? rgb( 42, 44, 50 ) : rgb( 54, 56, 60 );
    else if ( g2.eq_bar )
      c2 = rgb( 16, 56, 28 );
    else if ( g2.item_bar )
      c2 = rgb( 10, 48, 20 );
    else if ( g2.item[1] )
      c2 = rgb( 6, 18, 14 );
    else if ( g2.list[0] || g2.scope_p[0] || g2.piano_p[0] || g2.bottom[0] )
      c2 = rgb( 18, 24, 46 );                                // panel border
    else if ( g2.list[1] || g2.scope_p[1] || g2.piano_p[1] || g2.bottom[1] )
      c2 = rgb( 9, 12, 26 );                                 // panel fill
    else if ( g2.accent )
      c2 = rgb( 6, 42, acc_b );
    else if ( g2.header )
      c2 = rgb( 9, 11, 24 );
  end

  always_ff @( posedge pixel_clk )
    c3 <= c2;
//____________________________________________________________________________//

//------------- Stage 3: ordered dithering 8 -> 4 bits per channel ----------//
  function automatic [3:0] bayer4 (input [1:0] y, input [1:0] x);
    case ( { y, x } )
      4'h0: bayer4 =  0;  4'h1: bayer4 =  8;  4'h2: bayer4 =  2;  4'h3: bayer4 = 10;
      4'h4: bayer4 = 12;  4'h5: bayer4 =  4;  4'h6: bayer4 = 14;  4'h7: bayer4 =  6;
      4'h8: bayer4 =  3;  4'h9: bayer4 = 11;  4'ha: bayer4 =  1;  4'hb: bayer4 =  9;
      4'hc: bayer4 = 15;  4'hd: bayer4 =  7;  4'he: bayer4 = 13;  default: bayer4 = 5;
    endcase
  endfunction

  function automatic [3:0] dither (input [7:0] c, input [3:0] t);
    logic [8:0] s;
    s = 9'( c ) + 9'( t );
    dither = s[8] ? 4'hF : s[7:4];
  endfunction

  wire [3:0] th3 = bayer4( v3[1:0], h3[1:0] );

  always_ff @( posedge pixel_clk ) begin
    red   <= dither( c3[23:16], th3 );
    green <= dither( c3[15: 8], th3 );
    blue  <= dither( c3[ 7: 0], th3 );
  end
//____________________________________________________________________________//

endmodule
