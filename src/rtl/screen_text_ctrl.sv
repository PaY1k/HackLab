// Writes the changing text of the screen (clk_audio domain).
//
//   title     row 30, col 4,  40 chars : name of the current track (+ note on track 0)
//   source    row 1,  col 72, 12 chars : СИНТЕЗ / BRAM / SD-КАРТА / ПК / UART
//   list 4..6 rows 12/14/16, col 9, 18 chars : SD files, PC stream title
//   menu      rows 6..17, col 36, 52 chars : synth settings (SW14), cleared when off
//
// A text job is redone when what it shows changes. Characters go out one per
// clock as {addr, color, char} into a small FIFO that crosses to pixel_clk
// (player_screen) and ends in vga_ui's text RAM.
// Fixed strings come from strings.mem (tools/gen_tables.py), 32 bytes per slot.
module screen_text_ctrl #(
    parameter  STR_FILE = "strings.mem"
)(
    input  wire          clk           ,
    input  wire          rst_n         ,
    input  wire  [ 2:0]  track         ,
    input  wire  [ 2:0]  note_index    ,
    input  wire  [ 2:0]  octave        ,
  //--------- SD card                            --------//
    input  wire  [ 2:0]  sd_status     ,
    input  wire  [ 1:0]  sd_nfiles     ,
    output logic         sd_name_file  ,
    output logic [ 3:0]  sd_name_idx   ,
    input  wire  [ 7:0]  sd_name_char  ,
  //--------- PC stream title                    --------//
    output logic [ 4:0]  pc_title_idx  ,
    input  wire  [ 7:0]  pc_title_char ,
    input  wire          pc_title_valid,
    input  wire          pc_title_chg  ,
  //--------- Synth menu                         --------//
    input  wire          menu_mode     ,
    input  wire  [ 2:0]  menu_sel      ,
    input  wire  [31:0]  synth_params  ,
  //--------- Text writes                        --------//
    output logic         txt_we        ,
    output logic [24:0]  txt_word      ,   // {addr[12:0], color[3:0], char[7:0]}
    input  wire          txt_full
);

  logic [7:0] str_mem [0:1023];
  initial $readmemh( STR_FILE, str_mem );

  // string slots (see gen_tables.py)
  localparam [4:0] S_SYNTH = 5'd0, S_MEL0 = 5'd1, S_MEL1 = 5'd2, S_NOCARD = 5'd3, S_NOFILE = 5'd4,
                   S_PC = 5'd5, S_SRC0 = 5'd6, S_READING = 5'd10, S_BADFMT = 5'd11,
                   S_MENU = 5'd12, S_PNAME = 5'd13, S_WAVE = 5'd21, S_HINT = 5'd25;

  // SD status codes (sd_player.sv)
  localparam [2:0] SD_NOCARD = 3'd0, SD_MOUNT = 3'd1, SD_FMTERR = 3'd4, SD_FSERR = 3'd5;

  typedef enum logic [2:0] { J_TITLE, J_SRC, J_L3, J_L4, J_L5, J_MENU, J_NONE } job_t;

  logic [5:0] dirty;
  logic [3:0] mr;                 // menu job: row 0..11
  logic [5:0] mc;                 //           column 0..51
  job_t       job;
  logic [5:0] i;
  logic [5:0] len;
  logic [12:0] base;

//------------- What changed                                     -------------//
  logic [2:0] track_q, note_q, oct_q, sd_status_q, menu_sel_q;
  logic [1:0] sd_nfiles_q;
  logic       menu_mode_q;
  logic [31:0] params_q;
  wire        sd_track = ( track == 3'd3 ) || ( track == 3'd4 );

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      track_q     <= '0;
      note_q      <= '0;
      oct_q       <= '0;
      sd_status_q <= '0;
      sd_nfiles_q <= '0;
      menu_sel_q  <= '0;
      menu_mode_q <= 1'b0;
      params_q    <= '0;
    end
    else begin
      track_q     <= track;
      note_q      <= note_index;
      oct_q       <= octave;
      sd_status_q <= sd_status;
      sd_nfiles_q <= sd_nfiles;
      menu_sel_q  <= menu_sel;
      menu_mode_q <= menu_mode;
      params_q    <= synth_params;
    end
  end

  wire [5:0] set_dirty = {
    ( menu_mode != menu_mode_q ) || ( menu_mode && ( menu_sel != menu_sel_q || synth_params != params_q ) ),  // J_MENU
    pc_title_chg,                                                            // J_L5
    ( sd_status != sd_status_q ) || ( sd_nfiles != sd_nfiles_q ),            // J_L4
    ( sd_status != sd_status_q ) || ( sd_nfiles != sd_nfiles_q ),            // J_L3
    ( track != track_q ),                                                    // J_SRC
    ( track != track_q ) ||
      ( track == 3'd0 && ( note_index != note_q || octave != oct_q ) ) ||
      ( sd_track && ( sd_status != sd_status_q || sd_nfiles != sd_nfiles_q ) ) ||
      ( track == 3'd5 && pc_title_chg )                                      // J_TITLE
  };
//____________________________________________________________________________//

//------------- Character of the current job                     -------------//
  function automatic [7:0] note_char (input [2:0] n);
    case ( n )
      3'd0: note_char = "C";  3'd1: note_char = "D";  3'd2: note_char = "E";
      3'd3: note_char = "F";  3'd4: note_char = "G";  3'd5: note_char = "A";
      default: note_char = "B";
    endcase
  endfunction

  // slot shown instead of an SD file name
  function automatic [4:0] sd_msg (input [2:0] st);
    case ( st )
      SD_NOCARD: sd_msg = S_NOCARD;
      SD_MOUNT:  sd_msg = S_READING;
      SD_FMTERR, SD_FSERR: sd_msg = S_BADFMT;
      default:   sd_msg = S_NOFILE;
    endcase
  endfunction

  logic [7:0] ch;
  logic [3:0] color;
  logic       sd_file;          // which SD file this job shows
  logic       use_sd_name, use_pc;
  logic [4:0] slot;

  always_comb begin
    sd_file     = 1'b0;
    use_sd_name = 1'b0;
    use_pc      = 1'b0;
    slot        = S_NOFILE;
    color       = 4'd1;
    case ( job )
      J_TITLE: begin
        color = 4'd0;
        case ( track )
          3'd0: slot = S_SYNTH;
          3'd1: slot = S_MEL0;
          3'd2: slot = S_MEL1;
          3'd5: begin slot = S_PC; use_pc = pc_title_valid; end
          default: begin
            sd_file     = ( track == 3'd4 );
            // a file that cannot be played shows "SD: ошибка формата" instead of its name
            use_sd_name = ( { 1'b0, sd_file } < sd_nfiles ) && ( sd_status != SD_FMTERR );
            slot        = sd_msg( sd_status );
          end
        endcase
      end
      J_SRC: begin
        color = 4'd4;
        case ( track )
          3'd0:       slot = S_SRC0;
          3'd1, 3'd2: slot = S_SRC0 + 5'd1;
          3'd5:       slot = S_SRC0 + 5'd3;
          default:    slot = S_SRC0 + 5'd2;
        endcase
      end
      J_L3, J_L4: begin
        sd_file     = ( job == J_L4 );
        use_sd_name = ( { 1'b0, sd_file } < sd_nfiles );
        slot        = sd_msg( sd_status );
      end
      default: begin                                    // J_L5
        slot   = S_PC;
        use_pc = pc_title_valid;
      end
    endcase

    sd_name_file = sd_file;
    sd_name_idx  = i[3:0];
    pc_title_idx = i[4:0];

    if ( job == J_TITLE && track == 3'd0 && i == 6'd22 )
      ch = note_char( note_index );
    else if ( job == J_TITLE && track == 3'd0 && i == 6'd23 )
      ch = 8'h31 + 8'( octave );
    else if ( use_sd_name )
      ch = ( i < 6'd12 ) ? sd_name_char : 8'h20;
    else if ( use_pc )
      ch = ( i < 6'd18 ) ? pc_title_char : 8'h20;
    else
      ch = ( i < 6'd32 ) ? str_mem[{ slot, i[4:0] }] : 8'h20;
  end
//____________________________________________________________________________//

//------------- Menu characters                                  -------------//
  logic [7:0] m_ch;
  logic [3:0] m_color;
  logic [2:0] m_p;            // parameter of this row
  logic [3:0] m_val;
  logic [5:0] m_rel;          // column inside the value field

  always_comb begin
    m_ch    = 8'h20;
    m_color = 4'd1;
    m_p     = 3'( mr - 4'd2 );
    m_val   = synth_params[{ m_p, 2'b00 } +: 4];
    m_rel   = mc - 6'd12;
    if ( menu_mode ) begin
      if ( mr == 4'd0 ) begin
        m_color = 4'd0;
        if ( mc < 6'd32 ) m_ch = str_mem[{ S_MENU, mc[4:0] }];
      end
      else if ( mr >= 4'd2 && mr <= 4'd9 ) begin
        if ( mc < 6'd11 ) begin
          m_color = ( m_p == menu_sel ) ? 4'd0 : 4'd1;
          m_ch    = str_mem[{ S_PNAME + 5'( m_p ), mc[4:0] }];
        end
        else if ( mc >= 6'd12 ) begin
          if ( m_p == 3'd0 ) begin                                  // wave name
            m_color = 4'd4;
            if ( m_rel < 6'd16 ) m_ch = str_mem[{ S_WAVE + 5'( m_val[1:0] ), m_rel[4:0] }];
          end
          else if ( m_p == 3'd6 ) begin                             // octave -2..+2
            m_color = 4'd4;
            if ( m_rel == 6'd0 )      m_ch = ( m_val < 4'd2 ) ? "-" : ( m_val == 4'd2 ) ? " " : "+";
            else if ( m_rel == 6'd1 ) m_ch = 8'h30 + 8'( ( m_val < 4'd2 ) ? 4'd2 - m_val : m_val - 4'd2 );
          end
          else begin                                                // bar + number
            if ( m_rel < 6'd15 ) begin
              m_ch    = ( m_rel < 6'( m_val ) ) ? 8'hDB : 8'hB0;
              m_color = ( m_rel < 6'( m_val ) ) ? 4'd3 : 4'd2;
            end
            else if ( m_rel == 6'd16 ) begin m_ch = ( m_val >= 4'd10 ) ? "1" : " ";                     m_color = 4'd0; end
            else if ( m_rel == 6'd17 ) begin m_ch = 8'h30 + 8'( ( m_val >= 4'd10 ) ? m_val - 4'd10 : m_val ); m_color = 4'd0; end
          end
        end
      end
      else if ( mr == 4'd11 ) begin
        m_color = 4'd2;
        if ( mc < 6'd32 ) m_ch = str_mem[{ S_HINT, mc[4:0] }];
      end
    end
  end
//____________________________________________________________________________//

//------------- Job sequencer                                    -------------//
  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      dirty    <= '1;                  // draw everything after reset
      mr       <= '0;
      mc       <= '0;
      job      <= J_NONE;
      i        <= '0;
      len      <= '0;
      base     <= '0;
      txt_we   <= 1'b0;
      txt_word <= '0;
    end
    else begin
      txt_we <= 1'b0;
      dirty  <= dirty | set_dirty;

      if ( job == J_NONE ) begin
        i <= '0;
        if      ( dirty[0] ) begin job <= J_TITLE; len <= 6'd40; base <= 13'( 30 * 128 + 4 ); dirty[0] <= set_dirty[0]; end
        else if ( dirty[1] ) begin job <= J_SRC;   len <= 6'd12; base <= 13'( 1 * 128 + 72 ); dirty[1] <= set_dirty[1]; end
        else if ( dirty[2] ) begin job <= J_L3;    len <= 6'd18; base <= 13'( 12 * 128 + 9 ); dirty[2] <= set_dirty[2]; end
        else if ( dirty[3] ) begin job <= J_L4;    len <= 6'd18; base <= 13'( 14 * 128 + 9 ); dirty[3] <= set_dirty[3]; end
        else if ( dirty[4] ) begin job <= J_L5;    len <= 6'd18; base <= 13'( 16 * 128 + 9 ); dirty[4] <= set_dirty[4]; end
        else if ( dirty[5] ) begin job <= J_MENU;  mr <= '0; mc <= '0;                         dirty[5] <= set_dirty[5]; end
      end
      else if ( job == J_MENU ) begin
        if ( !txt_full && !txt_we ) begin
          txt_we   <= 1'b1;
          txt_word <= { { 6'( mr ) + 6'd6, 7'd0 } + 13'd36 + 13'( mc ), m_color, m_ch };
          if ( mc == 6'd51 ) begin
            mc <= '0;
            mr <= mr + 1'b1;
            if ( mr == 4'd11 ) job <= J_NONE;
          end
          else
            mc <= mc + 1'b1;
        end
      end
      else if ( !txt_full && !txt_we ) begin
        txt_we   <= 1'b1;
        txt_word <= { base + 13'( i ), color, ch };
        if ( i == len - 1'b1 ) job <= J_NONE;
        i <= i + 1'b1;
      end
    end
  end

endmodule
