// WAV player from a FAT32 microSD card (on top of sd_card.sv).
//
//   * mount: MBR (or a card formatted without partitions), FAT32 boot sector
//   * scan the root directory: the first MAX_FILES files *.WAV
//   * play: follow the cluster chain, parse the WAV header on the fly,
//     push samples (mono, signed 16-bit) into the audio FIFO.
//     8 / 16 bit, mono / stereo (mixed to mono), any sample rate: `step`
//     tells stream_reader how fast to take samples. The file loops.
//
// Everything is parsed while the bytes come from the card, no sector buffer:
// when the FIFO is nearly full `hold` pauses the card between bytes.
//
// Prepare a card: FAT32, WAV files in the root (tools/prepare_sd.sh converts
// MP3 with ffmpeg). Long names are fine, the screen shows the 8.3 name.
module sd_player #(
    parameter  FIFO_AW   = 12,
    parameter  MAX_FILES = 2
)(
    input  wire               clk         ,
    input  wire               rst_n       ,
  //--------- sd_card                          --------//
    input  wire               card_ready  ,
    output logic              rd_req      ,
    output logic       [31:0] rd_lba      ,
    output wire               hold        ,
    input  wire               rd_busy     ,
    input  wire        [ 7:0] rd_data     ,
    input  wire        [ 8:0] rd_idx      ,
    input  wire               rd_valid    ,
    input  wire               rd_done     ,
    input  wire               rd_err      ,
  //--------- Control                          --------//
    input  wire               play_start  ,   // pulse: (re)start file file_sel
    input  wire               file_sel    ,
    input  wire               play_stop   ,   // pulse: stop
  //--------- Audio FIFO, write side           --------//
    output logic              fifo_wr     ,
    output logic       [15:0] fifo_data   ,
    input  wire  [FIFO_AW:0]  fifo_level  ,
    output logic              fifo_flush  ,
  //--------- Info for the screen              --------//
    output logic       [ 1:0] nfiles      ,
    input  wire               name_file   ,
    input  wire        [ 3:0] name_idx    ,   // 0..11
    output logic       [ 7:0] name_char   ,   // "NAME.WAV" padded with spaces
    output logic       [ 2:0] status      ,
    output logic       [15:0] step        ,
    output logic       [15:0] len_bcd     ,
    output logic              len_valid   ,
    output logic       [ 9:0] progress
);

  localparam [2:0] ST_NOCARD = 3'd0, ST_MOUNT = 3'd1, ST_READY = 3'd2, ST_PLAY = 3'd3,
                   ST_FMTERR = 3'd4, ST_FSERR = 3'd5, ST_NOFILE = 3'd6;

  localparam [FIFO_AW:0] FIFO_HIGH = ( 1 << FIFO_AW ) - 8;

//------------- File system parameters                           -------------//
  logic [ 7:0] spc;                 // sectors per cluster
  logic [ 2:0] spc_shift;
  logic [15:0] rsv;
  logic [ 7:0] nfats;
  logic [31:0] fatsz, rootclus, plba, part;
  logic [ 7:0] ptype;
  logic        sig_fat32, sig_55, sig_aa;
  logic [31:0] fat_lba, data_lba;

  // files found
  logic [ 7:0] f_name [0:MAX_FILES-1][0:7];
  logic [31:0] f_clus [0:MAX_FILES-1];
  logic [31:0] f_size [0:MAX_FILES-1];

//------------- Reading modes                                    -------------//
  typedef enum logic [1:0] { M_BOOT, M_FAT, M_DIR, M_DATA } mode_t;
  mode_t       mode;
  logic [ 8:0] ent_off;             // FAT entry offset inside the sector
  logic [31:0] next_clus;

  // directory entry being received
  logic [ 7:0] e_name [0:10];
  logic [ 7:0] e_attr;
  logic [15:0] e_hi, e_lo;
  logic [31:0] e_size;
  logic        dir_end;

  // data
  logic [31:0] file_left;           // file bytes still to read
  logic        wav_byte;            // a file byte goes to the WAV parser now
  logic [ 7:0] wav_b;

  assign hold = ( mode == M_DATA ) && ( fifo_level >= FIFO_HIGH );

//------------- WAV parser                                       -------------//
  typedef enum logic [2:0] { W_RIFF, W_HDR, W_FMT, W_SKIP, W_DATA, W_END } wst_t;
  wst_t        wst;
  logic [31:0] w_cnt;               // bytes left in the current part
  logic [ 3:0] w_hi;                // header byte index
  logic [31:0] w_id, w_size;
  logic [15:0] fmt_tag, fmt_ch, fmt_bits;
  logic [31:0] fmt_rate, fmt_brate;
  logic [ 5:0] fmt_i;
  logic [31:0] data_size, data_done;
  logic [ 1:0] fr_i;                // byte inside the frame
  logic [ 7:0] lo_b;
  logic signed [15:0] left_s;
  logic        fmt_bad;
  logic        data_started;        // pulse: data chunk found

  wire         st16   = ( fmt_bits == 16'd16 );
  wire         stereo = ( fmt_ch == 16'd2 );
  wire  [1:0]  fr_last = { st16 & stereo, st16 ^ stereo };   // bytes per frame - 1

  function automatic signed [15:0] mono (input signed [15:0] a, input signed [15:0] b);
    logic signed [16:0] s;
    s    = a + b;
    mono = s[16:1];
  endfunction

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      wst          <= W_RIFF;
      w_cnt        <= '0;
      w_hi         <= '0;
      w_id         <= '0;
      w_size       <= '0;
      fmt_tag      <= '0;
      fmt_ch       <= 16'd1;
      fmt_bits     <= 16'd16;
      fmt_rate     <= 32'd48000;
      fmt_brate    <= 32'd96000;
      fmt_i        <= '0;
      data_size    <= '0;
      data_done    <= '0;
      fr_i         <= '0;
      lo_b         <= '0;
      left_s       <= '0;
      fmt_bad      <= 1'b0;
      data_started <= 1'b0;
      fifo_wr      <= 1'b0;
      fifo_data    <= '0;
    end
    else begin
      fifo_wr      <= 1'b0;
      data_started <= 1'b0;
      if ( fifo_flush ) begin                 // new file
        wst       <= W_RIFF;
        w_cnt     <= 32'd12;
        w_hi      <= '0;
        fmt_bad   <= 1'b0;
        data_done <= '0;
        fr_i      <= '0;
      end
      else if ( wav_byte ) begin
        case ( wst )
          W_RIFF: begin                       // "RIFF", size, "WAVE"
            w_cnt <= w_cnt - 1'b1;
            if ( w_cnt == 32'd1 ) begin wst <= W_HDR; w_hi <= '0; end
          end
          W_HDR: begin                        // chunk id + size
            w_hi <= w_hi + 1'b1;
            if ( w_hi < 4'd4 ) w_id   <= { w_id[23:0], wav_b };
            else               w_size <= { wav_b, w_size[31:8] };
            if ( w_hi == 4'd7 ) begin
              if ( w_id == "fmt " ) begin
                wst   <= W_FMT;
                fmt_i <= '0;
                w_cnt <= { wav_b, w_size[31:8] } + { 31'd0, w_size[8] };   // + pad byte if odd
              end
              else if ( w_id == "data" ) begin
                wst          <= W_DATA;
                w_cnt        <= { wav_b, w_size[31:8] };
                data_size    <= { wav_b, w_size[31:8] };
                data_started <= 1'b1;
                fr_i         <= '0;
                fmt_bad      <= !( ( fmt_tag == 16'd1 || fmt_tag == 16'hFFFE ) &&
                                   ( fmt_ch == 16'd1 || fmt_ch == 16'd2 ) &&
                                   ( fmt_bits == 16'd8 || fmt_bits == 16'd16 ) );
              end
              else begin
                wst   <= W_SKIP;              // other chunk: skip it (+ pad byte if odd)
                w_cnt <= { wav_b, w_size[31:8] } + { 31'd0, w_size[8] };
              end
              if ( { wav_b, w_size[31:8] } == 32'd0 && w_id != "data" )
                wst <= W_HDR;
              w_hi <= '0;
            end
          end
          W_FMT: begin
            fmt_i <= ( fmt_i == 6'd63 ) ? fmt_i : fmt_i + 1'b1;
            case ( fmt_i )
              6'd0:  fmt_tag[7:0]    <= wav_b;   6'd1:  fmt_tag[15:8]    <= wav_b;
              6'd2:  fmt_ch[7:0]     <= wav_b;   6'd3:  fmt_ch[15:8]     <= wav_b;
              6'd4:  fmt_rate[7:0]   <= wav_b;   6'd5:  fmt_rate[15:8]   <= wav_b;
              6'd6:  fmt_rate[23:16] <= wav_b;   6'd7:  fmt_rate[31:24]  <= wav_b;
              6'd8:  fmt_brate[7:0]  <= wav_b;   6'd9:  fmt_brate[15:8]  <= wav_b;
              6'd10: fmt_brate[23:16]<= wav_b;   6'd11: fmt_brate[31:24] <= wav_b;
              6'd14: fmt_bits[7:0]   <= wav_b;   6'd15: fmt_bits[15:8]   <= wav_b;
              default: ;
            endcase
            w_cnt <= w_cnt - 1'b1;
            if ( w_cnt == 32'd1 ) wst <= W_HDR;
          end
          W_SKIP: begin
            w_cnt <= w_cnt - 1'b1;
            if ( w_cnt == 32'd1 ) wst <= W_HDR;
          end
          W_DATA: if ( !fmt_bad ) begin
            w_cnt     <= w_cnt - 1'b1;
            data_done <= data_done + 1'b1;
            if ( w_cnt == 32'd1 ) wst <= W_END;
            fr_i <= ( fr_i == fr_last ) ? 2'd0 : fr_i + 1'b1;
            if ( !st16 ) begin                                 // 8 bit unsigned
              if ( !stereo ) begin
                fifo_data <= { ~wav_b[7], wav_b[6:0], 8'h00 };
                fifo_wr   <= 1'b1;
              end
              else if ( fr_i == 2'd0 )
                left_s <= { ~wav_b[7], wav_b[6:0], 8'h00 };
              else begin
                fifo_data <= mono( left_s, { ~wav_b[7], wav_b[6:0], 8'h00 } );
                fifo_wr   <= 1'b1;
              end
            end
            else begin                                         // 16 bit signed LE
              if ( !fr_i[0] )
                lo_b <= wav_b;
              else if ( !stereo || fr_i == 2'd3 ) begin
                fifo_data <= stereo ? mono( left_s, { wav_b, lo_b } ) : { wav_b, lo_b };
                fifo_wr   <= 1'b1;
              end
              else
                left_s <= { wav_b, lo_b };
            end
          end
          default: ;                                           // W_END: ignore the rest
        endcase
      end
    end
  end
//____________________________________________________________________________//

//------------- Divider for length and progress                  -------------//
  logic        div_start, div_busy;
  logic [31:0] div_a, div_b, div_q, div_r;
  logic [ 5:0] div_n;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      div_busy <= 1'b0;
      div_q    <= '0;
      div_r    <= '0;
      div_n    <= '0;
    end
    else if ( div_start && !div_busy ) begin
      div_busy <= 1'b1;
      div_q    <= div_a;
      div_r    <= '0;
      div_n    <= 6'd32;
    end
    else if ( div_busy ) begin
      // restoring division, one bit per clock
      if ( { div_r[30:0], div_q[31] } >= div_b ) begin
        div_r <= { div_r[30:0], div_q[31] } - div_b;
        div_q <= { div_q[30:0], 1'b1 };
      end
      else begin
        div_r <= { div_r[30:0], div_q[31] };
        div_q <= { div_q[30:0], 1'b0 };
      end
      div_n <= div_n - 1'b1;
      if ( div_n == 6'd1 ) div_busy <= 1'b0;
    end
  end

  // jobs: length once per file (data_size / byte_rate -> mm:ss), progress after each sector
  typedef enum logic [2:0] { D_IDLE, D_LEN, D_LEN_W, D_BCD, D_PROG, D_PROG_W } dst_t;
  dst_t        dst;
  logic        need_len, need_prog;
  logic [12:0] sec_left;
  logic [ 3:0] m10, m1, s10;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      dst       <= D_IDLE;
      div_start <= 1'b0;
      div_a     <= '0;
      div_b     <= 32'd1;
      need_len  <= 1'b0;
      need_prog <= 1'b0;
      sec_left  <= '0;
      m10 <= '0; m1 <= '0; s10 <= '0;
      len_bcd   <= '0;
      len_valid <= 1'b0;
      progress  <= '0;
    end
    else begin
      div_start <= 1'b0;
      if ( fifo_flush ) begin
        len_valid <= 1'b0;
        progress  <= '0;
      end
      if ( data_started ) need_len  <= 1'b1;
      if ( rd_done && mode == M_DATA && wst == W_DATA ) need_prog <= 1'b1;

      case ( dst )
        D_IDLE: if ( need_len ) begin
          need_len  <= 1'b0;
          div_a     <= data_size;
          div_b     <= ( fmt_brate == 0 ) ? 32'd1 : fmt_brate;
          div_start <= 1'b1;
          dst       <= D_LEN;
        end
        else if ( need_prog ) begin
          need_prog <= 1'b0;
          div_a     <= data_done;
          div_b     <= ( data_size[31:10] == 0 ) ? 32'd1 : { 10'd0, data_size[31:10] };
          div_start <= 1'b1;
          dst       <= D_PROG;
        end
        D_LEN:   dst <= D_LEN_W;
        D_LEN_W: if ( !div_busy ) begin
          sec_left <= ( div_q > 32'd5999 ) ? 13'd5999 : div_q[12:0];
          m10 <= '0; m1 <= '0; s10 <= '0;
          dst <= D_BCD;
        end
        // seconds -> mm:ss by subtraction (at most ~25 steps)
        D_BCD: begin
          if      ( sec_left >= 13'd600 ) begin sec_left <= sec_left - 13'd600; m10 <= m10 + 1'b1; end
          else if ( sec_left >= 13'd60  ) begin sec_left <= sec_left - 13'd60;  m1  <= m1  + 1'b1; end
          else if ( sec_left >= 13'd10  ) begin sec_left <= sec_left - 13'd10;  s10 <= s10 + 1'b1; end
          else begin
            len_bcd   <= { m10, m1, s10, sec_left[3:0] };
            len_valid <= 1'b1;
            dst       <= D_IDLE;
          end
        end
        D_PROG:   dst <= D_PROG_W;
        D_PROG_W: if ( !div_busy ) begin
          progress <= ( div_q > 32'd1023 ) ? 10'd1023 : div_q[9:0];
          dst      <= D_IDLE;
        end
        default: dst <= D_IDLE;
      endcase
    end
  end

  // samples per output tick: rate / 48006.5 * 65536 = rate * 89466 / 65536
  wire [34:0] step_full = 35'( fmt_rate[17:0] ) * 35'd89466;
  always_ff @( posedge clk )
    step <= ( step_full[34:16] > 19'd65535 ) ? 16'hFFFF : step_full[31:16];
//____________________________________________________________________________//

//------------- Main FSM                                         -------------//
  typedef enum logic [4:0] {
    F_WAIT, F_READ, F_READ_W, F_MBR, F_VBR, F_CALC, F_DIR, F_DIR_DONE, F_FAT_DIR,
    F_IDLE, F_PSTART, F_DREAD, F_DATA, F_FAT_DATA
  } fst_t;
  fst_t        fst, after;
  logic [31:0] cur_clus;
  logic [ 7:0] sec_i;
  logic        stop_req, start_req;
  logic        cur_file;
  logic [ 1:0] flush_cnt;

  wire [31:0] clus_lba = data_lba + ( ( cur_clus - 32'd2 ) << spc_shift ) + { 24'd0, sec_i };
  wire        eoc      = ( next_clus[27:0] >= 28'hFFFFFF8 ) || ( next_clus[27:0] < 28'd2 );

  // byte capture while a sector is coming in
  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      spc <= 8'd1; rsv <= '0; nfats <= 8'd2; fatsz <= '0; rootclus <= 32'd2;
      plba <= '0; ptype <= '0; sig_fat32 <= 1'b0; sig_55 <= 1'b0; sig_aa <= 1'b0;
      next_clus <= '0;
      e_attr <= '0; e_hi <= '0; e_lo <= '0; e_size <= '0;
      for ( int i = 0; i < 11; i++ ) e_name[i] <= 8'h20;
    end
    else if ( rd_valid ) begin
      case ( mode )
        M_BOOT: begin
          case ( rd_idx )
            9'h00D: spc            <= rd_data;
            9'h00E: rsv[7:0]       <= rd_data;
            9'h00F: rsv[15:8]      <= rd_data;
            9'h010: nfats          <= rd_data;
            9'h024: fatsz[7:0]     <= rd_data;
            9'h025: fatsz[15:8]    <= rd_data;
            9'h026: fatsz[23:16]   <= rd_data;
            9'h027: fatsz[31:24]   <= rd_data;
            9'h02C: rootclus[7:0]  <= rd_data;
            9'h02D: rootclus[15:8] <= rd_data;
            9'h02E: rootclus[23:16]<= rd_data;
            9'h02F: rootclus[31:24]<= rd_data;
            9'h052: sig_fat32      <= ( rd_data == "F" );
            9'h053: sig_fat32      <= sig_fat32 && ( rd_data == "A" );
            9'h054: sig_fat32      <= sig_fat32 && ( rd_data == "T" );
            9'h055: sig_fat32      <= sig_fat32 && ( rd_data == "3" );
            9'h056: sig_fat32      <= sig_fat32 && ( rd_data == "2" );
            9'h1C2: ptype          <= rd_data;
            9'h1C6: plba[7:0]      <= rd_data;
            9'h1C7: plba[15:8]     <= rd_data;
            9'h1C8: plba[23:16]    <= rd_data;
            9'h1C9: plba[31:24]    <= rd_data;
            9'h1FE: sig_55         <= ( rd_data == 8'h55 );
            9'h1FF: sig_aa         <= ( rd_data == 8'hAA );
            default: ;
          endcase
        end
        M_FAT: begin
          if ( rd_idx == ent_off          ) next_clus[7:0]   <= rd_data;
          if ( rd_idx == ent_off + 9'd1   ) next_clus[15:8]  <= rd_data;
          if ( rd_idx == ent_off + 9'd2   ) next_clus[23:16] <= rd_data;
          if ( rd_idx == ent_off + 9'd3   ) next_clus[31:24] <= rd_data;
        end
        M_DIR: begin
          case ( rd_idx[4:0] )
            5'd11:   e_attr       <= rd_data;
            5'd20:   e_hi[7:0]    <= rd_data;
            5'd21:   e_hi[15:8]   <= rd_data;
            5'd26:   e_lo[7:0]    <= rd_data;
            5'd27:   e_lo[15:8]   <= rd_data;
            5'd28:   e_size[7:0]  <= rd_data;
            5'd29:   e_size[15:8] <= rd_data;
            5'd30:   e_size[23:16]<= rd_data;
            5'd31:   e_size[31:24]<= rd_data;
            default: if ( rd_idx[4:0] < 5'd11 ) e_name[rd_idx[4:0]] <= rd_data;
          endcase
        end
        default: ;
      endcase
    end
  end

  // directory entry complete at byte 31: is it a WAV file?
  wire e_last  = rd_valid && mode == M_DIR && rd_idx[4:0] == 5'd31 && !dir_end;
  wire e_is_wav = ( e_name[0] != 8'h00 ) && ( e_name[0] != 8'hE5 ) && ( e_attr != 8'h0F ) &&
                  ( ( e_attr & 8'h18 ) == 8'h00 ) &&
                  ( e_name[8] == "W" ) && ( e_name[9] == "A" ) && ( e_name[10] == "V" );

  assign wav_byte = rd_valid && mode == M_DATA && file_left != 32'd0 && !stop_req;
  assign wav_b    = rd_data;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      fst        <= F_WAIT;
      after      <= F_WAIT;
      mode       <= M_BOOT;
      rd_req     <= 1'b0;
      rd_lba     <= '0;
      status     <= ST_NOCARD;
      nfiles     <= '0;
      dir_end    <= 1'b0;
      part       <= '0;
      fat_lba    <= '0;
      data_lba   <= '0;
      spc_shift  <= '0;
      ent_off    <= '0;
      cur_clus   <= '0;
      sec_i      <= '0;
      stop_req   <= 1'b0;
      start_req  <= 1'b0;
      cur_file   <= 1'b0;
      file_left  <= '0;
      fifo_flush <= 1'b0;
      flush_cnt  <= '0;
      for ( int f = 0; f < MAX_FILES; f++ ) begin
        f_clus[f] <= '0;
        f_size[f] <= '0;
        for ( int i = 0; i < 8; i++ ) f_name[f][i] <= 8'h20;
      end
    end
    else begin
      rd_req <= 1'b0;

      // FIFO flush: 2 clocks
      if ( flush_cnt != 0 ) flush_cnt <= flush_cnt - 1'b1;
      fifo_flush <= ( flush_cnt != 0 );

      if ( play_start ) begin start_req <= 1'b1; cur_file <= file_sel; stop_req <= 1'b0; end
      if ( play_stop )  begin stop_req  <= 1'b1; start_req <= 1'b0; end

      if ( wav_byte ) file_left <= file_left - 1'b1;

      if ( e_last && e_name[0] == 8'h00 ) dir_end <= 1'b1;
      if ( e_last && e_is_wav && nfiles < 2'( MAX_FILES ) ) begin
        for ( int i = 0; i < 8; i++ ) f_name[nfiles][i] <= e_name[i];
        f_clus[nfiles] <= { e_hi, e_lo };
        f_size[nfiles] <= e_size;
        nfiles <= nfiles + 1'b1;
      end

      if ( rd_err ) begin                      // card lost: mount again
        fst    <= F_WAIT;
        status <= ST_NOCARD;
        nfiles <= '0;
      end
      else case ( fst )
        F_WAIT: begin
          status <= ST_NOCARD;
          if ( card_ready ) begin
            status <= ST_MOUNT;
            nfiles <= '0;
            mode   <= M_BOOT;
            rd_lba <= 32'd0;
            after  <= F_MBR;
            fst    <= F_READ;
          end
        end

        // read one sector at rd_lba in `mode`, then go to `after`
        F_READ: if ( !card_ready ) fst <= F_WAIT;
                else if ( !rd_busy ) begin rd_req <= 1'b1; fst <= F_READ_W; end
        F_READ_W: if ( rd_done ) fst <= after;
                  else if ( !card_ready ) fst <= F_WAIT;

        F_MBR: begin
          if ( sig_fat32 ) begin               // no partition table: the card starts with the boot sector
            part <= 32'd0;
            fst  <= F_CALC;
          end
          else if ( sig_55 && sig_aa && ( ptype == 8'h0B || ptype == 8'h0C ) ) begin
            part   <= plba;
            rd_lba <= plba;
            after  <= F_VBR;
            fst    <= F_READ;
          end
          else begin
            status <= ST_FSERR;
            fst    <= F_IDLE;
          end
        end

        F_VBR: begin
          if ( sig_fat32 ) fst <= F_CALC;
          else begin status <= ST_FSERR; fst <= F_IDLE; end
        end

        F_CALC: begin
          fat_lba  <= part + { 16'd0, rsv };
          data_lba <= part + { 16'd0, rsv } + ( ( nfats == 8'd2 ) ? { fatsz[30:0], 1'b0 } : fatsz );
          case ( spc )
            8'd1: spc_shift <= 3'd0;   8'd2: spc_shift <= 3'd1;   8'd4: spc_shift <= 3'd2;
            8'd8: spc_shift <= 3'd3;   8'd16: spc_shift <= 3'd4;  8'd32: spc_shift <= 3'd5;
            8'd64: spc_shift <= 3'd6;  default: spc_shift <= 3'd7;
          endcase
          cur_clus <= rootclus;
          sec_i    <= '0;
          dir_end  <= 1'b0;
          fst      <= F_DIR_DONE;      // F_DIR_DONE with sec_i = 0 starts the first read
          after    <= F_DIR;
        end

        // directory sector done (or the first one to read)
        F_DIR: begin
          if ( dir_end || nfiles == 2'( MAX_FILES ) )
            fst <= F_IDLE;
          else if ( sec_i == spc - 1'b1 ) begin           // end of cluster: next one from the FAT
            mode    <= M_FAT;
            rd_lba  <= fat_lba + { 7'd0, cur_clus[31:7] };
            ent_off <= { cur_clus[6:0], 2'b00 };
            after   <= F_FAT_DIR;
            fst     <= F_READ;
          end
          else begin
            sec_i <= sec_i + 1'b1;
            fst   <= F_DIR_DONE;
          end
        end
        F_DIR_DONE: begin                                  // read sector sec_i of cur_clus
          mode   <= M_DIR;
          rd_lba <= clus_lba;
          after  <= F_DIR;
          fst    <= F_READ;
        end
        F_FAT_DIR: begin
          if ( eoc ) fst <= F_IDLE;
          else begin
            cur_clus <= { 4'd0, next_clus[27:0] };
            sec_i    <= '0;
            fst      <= F_DIR_DONE;
          end
        end

        F_IDLE: begin
          mode <= M_BOOT;
          if ( status == ST_MOUNT || status == ST_PLAY || status == ST_READY )
            status <= ( nfiles == 0 ) ? ST_NOFILE : ST_READY;
          if ( start_req ) begin
            start_req <= 1'b0;
            if ( { 1'b0, cur_file } < nfiles ) begin
              flush_cnt <= 2'd2;
              fst       <= F_PSTART;
            end
          end
          stop_req <= 1'b0;
        end

        // start (or loop) the file: FIFO and WAV parser are flushed first
        F_PSTART: if ( flush_cnt == 0 && !fifo_flush ) begin
          status    <= ST_PLAY;
          cur_clus  <= f_clus[cur_file];
          file_left <= f_size[cur_file];
          sec_i     <= '0;
          mode      <= M_DATA;
          fst       <= F_DREAD;
        end

        F_DREAD: begin                                     // read sector sec_i of cur_clus
          mode   <= M_DATA;
          rd_lba <= clus_lba;
          after  <= F_DATA;
          fst    <= F_READ;
        end

        F_DATA: begin                                      // a data sector is done
          if ( stop_req || start_req ) begin
            flush_cnt <= 2'd2;
            stop_req  <= 1'b0;
            status    <= ST_READY;
            fst       <= F_IDLE;                           // F_IDLE takes a pending start
          end
          else if ( fmt_bad ) begin
            status <= ST_FMTERR;
            fst    <= F_IDLE;
          end
          else if ( file_left == 32'd0 || wst == W_END ) begin
            flush_cnt <= 2'd2;                             // end of file: play it again
            fst       <= F_PSTART;
          end
          else if ( sec_i == spc - 1'b1 ) begin
            mode    <= M_FAT;
            rd_lba  <= fat_lba + { 7'd0, cur_clus[31:7] };
            ent_off <= { cur_clus[6:0], 2'b00 };
            after   <= F_FAT_DATA;
            fst     <= F_READ;
          end
          else begin
            sec_i <= sec_i + 1'b1;
            fst   <= F_DREAD;
          end
        end

        F_FAT_DATA: begin
          if ( eoc ) begin
            flush_cnt <= 2'd2;
            fst       <= F_PSTART;
          end
          else begin
            cur_clus <= { 4'd0, next_clus[27:0] };
            sec_i    <= '0;
            fst      <= F_DREAD;
          end
        end

        default: fst <= F_WAIT;
      endcase
    end
  end
//____________________________________________________________________________//

//------------- File name for the screen: "NAME.WAV"             -------------//
  logic [3:0] nlen;
  always_comb begin
    nlen = 4'd8;
    for ( int i = 7; i >= 0; i-- )
      if ( f_name[name_file][i] == 8'h20 ) nlen = 4'( i );
    if ( { 1'b0, name_file } >= nfiles )   name_char = 8'h20;
    else if ( name_idx < nlen )            name_char = f_name[name_file][name_idx[2:0]];
    else if ( name_idx == nlen )           name_char = ".";
    else if ( name_idx == nlen + 4'd1 )    name_char = "W";
    else if ( name_idx == nlen + 4'd2 )    name_char = "A";
    else if ( name_idx == nlen + 4'd3 )    name_char = "V";
    else                                   name_char = 8'h20;
  end

endmodule
