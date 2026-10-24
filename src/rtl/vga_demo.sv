module vga_demo #(
  parameter              LOGO_CLKS  = 28'd200_000_000 ,  // logo time after reset: 200M / 39.941 MHz = 5 s
  parameter [8*16-1:0]   TEXT_LINE0 = " AUDIO NEXYS A7 " ,  // exactly 16 chars, see font_rom for the charset
  parameter [8*16-1:0]   TEXT_LINE1 = "  800X600 60HZ  " ,
  parameter [11:0]       BG_COLOR   = 12'h002 ,          // {R, G, B}, dark blue
  parameter [11:0]       TEXT_COLOR = 12'h2A3            // {R, G, B}, green
)(
  //--------- Clock & Reset                      --------//
    input  wire           pixel_clk ,  // 39.941 MHz
    input  wire           rst_n     ,  // active low, deasserted synchronously to pixel_clk
  //--------- Pixel coordinates                  --------//
    input  wire  [10:0]   h_coord   ,  // 0..799 visible
    input  wire  [ 9:0]   v_coord   ,  // 0..599 visible
  //--------- Pixel color                        --------//
    output logic [ 3:0]   red       ,
    output logic [ 3:0]   green     ,
    output logic [ 3:0]   blue
);

//------------- Logo timer                                       -------------//
  logic [27:0]  logo_counter;
  wire          logo_active ;

  always_ff @( posedge pixel_clk or negedge rst_n ) begin
    if      ( !rst_n )
      logo_counter <= 28'd0;
    else if ( logo_active )
      logo_counter <= logo_counter + 1'b1;
  end
  assign logo_active = ( logo_counter < LOGO_CLKS );
//____________________________________________________________________________//

//------------- Sber logo 128x128 in the center                  -------------//
  // Logo corner: h = (800-128)/2 = 336, v = (600-128)/2 = 236.
  // The ROM answers one clock later, so the address is taken for the next pixel (h+1).
  localparam LOGO_X0 = 11'd336;
  localparam LOGO_Y0 = 10'd236;

  wire  [10:0]  logo_h_next = h_coord - ( LOGO_X0 - 1'b1 );
  wire  [ 9:0]  logo_v      = v_coord -   LOGO_Y0;
  wire  [11:0]  logo_word   ;          // {B, G, R}, 12'h000 = transparent
  wire          logo_area   ;
  wire          logo_pixel  ;

  sber_logo_rom sber_logo_rom (
    .clk  ( pixel_clk                         ),
    .addr ( { logo_v[6:0], logo_h_next[6:0] } ),  // row * 128 + column
    .word ( logo_word                         )
  );

  assign logo_area  = ( h_coord >= LOGO_X0 ) && ( h_coord < LOGO_X0 + 11'd128 ) &&
                      ( v_coord >= LOGO_Y0 ) && ( v_coord < LOGO_Y0 + 10'd128 );
  assign logo_pixel = logo_area && ( logo_word != 12'h000 );
//____________________________________________________________________________//

//------------- Text: 2 lines x 16 chars                         -------------//
  // Each 8x8 glyph is scaled x4 to 32x32 pixels, lines go every 64 pixels.
  // Text block: 16*32 = 512 x (64+32) = 96 pixels, corner h = (800-512)/2 = 144, v = (600-96)/2 = 252.
  localparam TEXT_X0 = 11'd144;
  localparam TEXT_Y0 = 10'd252;

  wire  [10:0]  text_h      = h_coord - TEXT_X0;
  wire  [ 9:0]  text_v      = v_coord - TEXT_Y0;
  wire  [ 3:0]  char_col    = text_h[8:5];        // char number in the line
  wire          char_line   = text_v[6];          // line number
  wire  [ 2:0]  glyph_col   = text_h[4:2];        // pixel inside the glyph (scaled /4)
  wire  [ 2:0]  glyph_row   = text_v[4:2];
  wire  [ 7:0]  char_code   ;
  wire  [ 7:0]  glyph_bits  ;
  wire          text_area   ;
  wire          text_pixel  ;

  // Char 0 is the leftmost one, it sits in the top byte of the string
  assign char_code = char_line ? TEXT_LINE1[8*(15-char_col) +: 8]
                               : TEXT_LINE0[8*(15-char_col) +: 8];

  font_rom font_rom (
    .char_code ( char_code  ),
    .row       ( glyph_row  ),
    .bits      ( glyph_bits )
  );

  assign text_area  = ( h_coord >= TEXT_X0 ) && ( h_coord < TEXT_X0 + 11'd512 ) &&
                      ( v_coord >= TEXT_Y0 ) && ( v_coord < TEXT_Y0 + 10'd96  ) &&
                      !text_v[5];                 // lower half of each 64-pixel line is a gap
  assign text_pixel = text_area && glyph_bits[7 - glyph_col];
//____________________________________________________________________________//

//------------- RGB MUX                                          -------------//
  always_comb begin
    if      ( logo_active && logo_pixel )
      { blue, green, red } = logo_word;
    else if ( !logo_active && text_pixel )
      { red, green, blue } = TEXT_COLOR;
    else
      { red, green, blue } = BG_COLOR;
  end
//____________________________________________________________________________//

endmodule
