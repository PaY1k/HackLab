// microSD card in SPI mode: power-up, initialization, single block reads.
//
//   * init at 400 kHz: CMD0, CMD8, ACMD41 (loop), CMD58 (SDHC?), CMD16 for old cards
//   * then 12.3 MHz (clk / 4)
//   * read: rd_req + rd_lba (block number) -> 512 data bytes come out one by
//     one (data, idx, valid); the next byte is not clocked in while hold = 1,
//     so a slow consumer simply pauses the card. rd_done or rd_err at the end.
//   * on any error the card is initialized again after ~0.3 s; card_ready
//     goes low meanwhile.
//
// Nexys A7 pins: SD_RESET (low = card powered), SD_SCK, SD_CMD (MOSI),
// SD_DAT[0] (MISO), SD_DAT[3] (CS).
module sd_card #(
    parameter  SLOW_HALF = 8'd62,     // 49.15865 MHz / (2*62) = 396 kHz
    parameter  FAST_HALF = 8'd2,      // 49.15865 MHz / 4      = 12.3 MHz
    parameter  WAIT_BITS = 24         // power-up / retry pause: 2^24 clocks = 0.34 s
)(
    input  wire          clk        ,
    input  wire          rst_n      ,
  //--------- Pins                               --------//
    output logic         sd_reset   ,
    output logic         sd_cs      ,
    output logic         sd_sck     ,
    output logic         sd_mosi    ,
    input  wire          sd_miso    ,
  //--------- Block read                         --------//
    output logic         card_ready ,
    output logic         card_sdhc  ,
    input  wire          rd_req     ,   // pulse, only when card_ready && !rd_busy
    input  wire  [31:0]  rd_lba     ,
    input  wire          hold       ,   // pause between data bytes
    output logic         rd_busy    ,
    output logic [ 7:0]  rd_data    ,
    output logic [ 8:0]  rd_idx     ,
    output logic         rd_valid   ,
    output logic         rd_done    ,
    output logic         rd_err
);

//------------- SPI byte engine (mode 0)                         -------------//
  logic       fast;
  logic       x_start, x_done, x_busy;
  logic [7:0] x_tx, x_rx, x_sh, x_in;
  logic [7:0] x_cnt;
  logic [3:0] x_bit;
  (* ASYNC_REG = "TRUE" *) logic [1:0] miso_s;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      sd_sck  <= 1'b0;
      sd_mosi <= 1'b1;
      x_busy  <= 1'b0;
      x_done  <= 1'b0;
      x_cnt   <= '0;
      x_bit   <= '0;
      x_sh    <= '1;
      x_in    <= '0;
      x_rx    <= '0;
      miso_s  <= 2'b11;
    end
    else begin
      miso_s <= { miso_s[0], sd_miso };
      x_done <= 1'b0;
      if ( !x_busy ) begin
        if ( x_start ) begin
          x_busy  <= 1'b1;
          x_sh    <= { x_tx[6:0], 1'b1 };
          sd_mosi <= x_tx[7];
          x_bit   <= '0;
          x_cnt   <= fast ? FAST_HALF : SLOW_HALF;
        end
      end
      else if ( x_cnt != 8'd1 )
        x_cnt <= x_cnt - 1'b1;
      else begin
        x_cnt <= fast ? FAST_HALF : SLOW_HALF;
        if ( !sd_sck )
          sd_sck <= 1'b1;
        else begin
          // sample just before the falling edge: data is stable the whole high phase
          sd_sck <= 1'b0;
          x_in   <= { x_in[6:0], miso_s[1] };
          if ( x_bit == 4'd7 ) begin
            x_busy <= 1'b0;
            x_done <= 1'b1;
            x_rx   <= { x_in[6:0], miso_s[1] };
            sd_mosi <= 1'b1;
          end
          else begin
            sd_mosi <= x_sh[7];
            x_sh    <= { x_sh[6:0], 1'b1 };
            x_bit   <= x_bit + 1'b1;
          end
        end
      end
    end
  end
//____________________________________________________________________________//

//------------- Card FSM                                         -------------//
  typedef enum logic [5:0] {
    PWR_WAIT, DUMMY, CMD0, CMD8, CMD8_R, ACMD55, ACMD41, ACMD41_R, CMD58, CMD58_R, CMD16, CMD16_R, INIT_OK,
    READY, RD_CMD, RD_TOKEN, RD_DATA, RD_CRC, RD_END,
    C_FF, C_SEND, C_RESP, C_RET,                  // command "subroutine"
    END_CS, FAIL
  } st_t;

  st_t         st, ret_st;
  logic [WAIT_BITS-1:0] wait_cnt;
  logic [ 7:0] n;                 // byte counter
  logic [15:0] tries;
  logic [47:0] cmd;               // command frame being sent
  logic [ 2:0] cmd_i;
  logic [ 7:0] r1;
  logic [31:0] resp;              // R3 / R7 payload
  logic        sdv1;
  logic [16:0] tok_wait;
  logic [31:0] lba_q;

  function automatic [47:0] frame (input [5:0] idx, input [31:0] arg, input [7:0] crc);
    frame = { 2'b01, idx, arg, crc };
  endfunction

  // start a byte transfer (only from a state that waits for it)
  task automatic xfer (input [7:0] b);
    x_tx    <= b;
    x_start <= 1'b1;
  endtask

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      st         <= PWR_WAIT;
      ret_st     <= PWR_WAIT;
      wait_cnt   <= '0;
      sd_reset   <= 1'b1;
      sd_cs      <= 1'b1;
      fast       <= 1'b0;
      x_start    <= 1'b0;
      x_tx       <= 8'hFF;
      n          <= '0;
      tries      <= '0;
      cmd        <= '0;
      cmd_i      <= '0;
      r1         <= 8'hFF;
      resp       <= '0;
      sdv1       <= 1'b0;
      card_ready <= 1'b0;
      card_sdhc  <= 1'b0;
      rd_busy    <= 1'b0;
      rd_data    <= '0;
      rd_idx     <= '0;
      rd_valid   <= 1'b0;
      rd_done    <= 1'b0;
      rd_err     <= 1'b0;
      tok_wait   <= '0;
      lba_q      <= '0;
    end
    else begin
      x_start  <= 1'b0;
      rd_valid <= 1'b0;
      rd_done  <= 1'b0;
      rd_err   <= 1'b0;

      case ( st )
        // power the card (SD_RESET low) and wait for the supply to settle
        PWR_WAIT: begin
          sd_reset   <= 1'b0;
          sd_cs      <= 1'b1;
          fast       <= 1'b0;
          card_ready <= 1'b0;
          rd_busy    <= 1'b0;
          wait_cnt   <= wait_cnt + 1'b1;
          if ( &wait_cnt ) begin
            n  <= '0;
            st <= DUMMY;
            xfer( 8'hFF );
          end
        end

        // >= 74 clocks with CS high
        DUMMY: if ( x_done ) begin
          if ( n == 8'd11 ) begin
            tries <= '0;
            st    <= CMD0;
          end
          else begin
            n <= n + 1'b1;
            xfer( 8'hFF );
          end
        end

        CMD0: begin
          cmd <= frame( 6'd0, 32'h0, 8'h95 );  ret_st <= CMD8;  st <= C_FF;  sd_cs <= 1'b0;  xfer( 8'hFF );
        end

        CMD8: begin
          if ( r1 != 8'h01 ) begin             // not idle yet: CS high, try again
            tries  <= tries + 1'b1;
            if ( tries == 16'd100 ) st <= FAIL; else st <= END_CS;
            ret_st <= CMD0;
            sd_cs  <= 1'b1;  xfer( 8'hFF );
          end
          else begin
            cmd <= frame( 6'd8, 32'h1AA, 8'h87 );  ret_st <= CMD8_R;  st <= C_FF;  sd_cs <= 1'b0;  xfer( 8'hFF );
          end
        end

        // R7: 4 more bytes after R1; illegal command -> SD v1 card
        CMD8_R: begin
          if ( r1[2] ) begin
            sdv1  <= 1'b1;
            tries <= '0;
            st    <= END_CS;  ret_st <= ACMD55;
            sd_cs <= 1'b1;    xfer( 8'hFF );
          end
          else if ( x_done || n == 8'd0 ) begin
            if ( n != 8'd0 ) resp <= { resp[23:0], x_rx };
            if ( n == 8'd4 ) begin
              sdv1  <= 1'b0;
              tries <= '0;
              if ( ( { resp[23:0], x_rx } & 32'hFFF ) == 32'h1AA ) st <= END_CS; else st <= FAIL;
              ret_st <= ACMD55;
              sd_cs <= 1'b1;
              xfer( 8'hFF );
            end
            else begin
              n <= n + 1'b1;
              xfer( 8'hFF );
            end
          end
        end

        ACMD55: begin
          cmd <= frame( 6'd55, 32'h0, 8'h65 );  ret_st <= ACMD41;  st <= C_FF;  sd_cs <= 1'b0;  xfer( 8'hFF );
        end

        ACMD41: begin                          // after CMD55: send CMD41 (HCS for v2 cards)
          cmd <= frame( 6'd41, sdv1 ? 32'h0 : 32'h4000_0000, 8'h77 );
          ret_st <= ACMD41_R;
          st  <= C_FF;  sd_cs <= 1'b0;  xfer( 8'hFF );
        end

        ACMD41_R: begin
          if ( r1 == 8'h00 ) begin             // card is ready
            n  <= '0;
            st <= END_CS;  if ( sdv1 ) ret_st <= CMD16; else ret_st <= CMD58;
            sd_cs <= 1'b1;  xfer( 8'hFF );
          end
          else begin
            n     <= '0;
            tries <= tries + 1'b1;
            if ( tries == 16'd20000 ) st <= FAIL; else st <= END_CS;
            ret_st <= ACMD55;
            sd_cs <= 1'b1;  xfer( 8'hFF );
          end
        end

        CMD58: begin
          cmd <= frame( 6'd58, 32'h0, 8'hFD );  ret_st <= CMD58_R;  st <= C_FF;  sd_cs <= 1'b0;  xfer( 8'hFF );
        end

        CMD58_R: if ( x_done || n == 8'd0 ) begin
          if ( n != 8'd0 ) resp <= { resp[23:0], x_rx };
          if ( n == 8'd4 ) begin
            card_sdhc <= resp[22];             // byte 1 bit 6 = CCS (resp holds 3 bytes + x_rx)
            n  <= '0;
            st <= END_CS;  if ( resp[22] ) ret_st <= INIT_OK; else ret_st <= CMD16;
            sd_cs <= 1'b1;  xfer( 8'hFF );
          end
          else begin
            n <= n + 1'b1;
            xfer( 8'hFF );
          end
        end

        CMD16: begin                           // block length 512 (old byte-addressed cards)
          cmd <= frame( 6'd16, 32'd512, 8'h15 );
          ret_st <= CMD16_R;
          st  <= C_FF;  sd_cs <= 1'b0;  xfer( 8'hFF );
        end

        CMD16_R: begin
          n  <= '0;
          st <= END_CS;  ret_st <= INIT_OK;
          sd_cs <= 1'b1;  xfer( 8'hFF );
        end

        INIT_OK: begin
          fast       <= 1'b1;
          card_ready <= 1'b1;
          st         <= READY;
        end

        READY: if ( rd_req ) begin
          rd_busy <= 1'b1;
          lba_q   <= rd_lba;
          st      <= RD_CMD;
        end

        RD_CMD: begin
          cmd <= frame( 6'd17, card_sdhc ? lba_q : { lba_q[22:0], 9'd0 }, 8'h01 );
          ret_st   <= RD_TOKEN;
          tok_wait <= '0;
          st <= C_FF;  sd_cs <= 1'b0;  xfer( 8'hFF );
        end

        // R1 must be 0, then wait for the data token 0xFE
        RD_TOKEN: begin
          if ( r1 != 8'h00 )
            st <= FAIL;
          else if ( x_done || tok_wait == 17'd0 ) begin
            tok_wait <= tok_wait + 1'b1;
            if ( tok_wait != 17'd0 && x_rx == 8'hFE ) begin
              n      <= '0;
              rd_idx <= '1;                     // first byte gets index 0
              st     <= RD_DATA;
            end
            else if ( &tok_wait )
              st <= FAIL;
            else
              xfer( 8'hFF );
          end
        end

        // 512 data bytes; hold pauses before starting the next one
        RD_DATA: begin
          if ( x_done ) begin
            rd_data  <= x_rx;
            rd_idx   <= rd_idx + 1'b1;
            rd_valid <= 1'b1;
            if ( rd_idx == 9'd510 ) begin       // that was byte 511
              n  <= '0;
              st <= RD_CRC;
            end
          end
          else if ( !x_busy && !x_start && !hold && !( rd_valid && rd_idx == 9'd511 ) )
            xfer( 8'hFF );
        end

        RD_CRC: if ( !x_busy && !x_start ) begin
          if ( x_done || n == 8'd0 ) begin
            if ( n == 8'd2 ) begin
              sd_cs <= 1'b1;
              st    <= RD_END;
              xfer( 8'hFF );
            end
            else begin
              n <= n + 1'b1;
              xfer( 8'hFF );
            end
          end
        end

        RD_END: if ( x_done ) begin
          rd_busy <= 1'b0;
          rd_done <= 1'b1;
          st      <= READY;
        end

        //----- command: 0xFF, 6 bytes of the frame, then up to 16 bytes for R1
        C_FF: if ( x_done ) begin
          cmd_i <= '0;
          st    <= C_SEND;
          xfer( cmd[47:40] );
          cmd   <= { cmd[39:0], 8'hFF };
        end

        C_SEND: if ( x_done ) begin
          if ( cmd_i == 3'd5 ) begin
            n  <= '0;
            st <= C_RESP;
            xfer( 8'hFF );
          end
          else begin
            cmd_i <= cmd_i + 1'b1;
            xfer( cmd[47:40] );
            cmd   <= { cmd[39:0], 8'hFF };
          end
        end

        C_RESP: if ( x_done ) begin
          if ( !x_rx[7] ) begin
            r1 <= x_rx;
            n  <= '0;
            st <= C_RET;
          end
          else if ( n == 8'd15 ) begin
            r1 <= 8'hFF;
            n  <= '0;
            st <= C_RET;
          end
          else begin
            n <= n + 1'b1;
            xfer( 8'hFF );
          end
        end

        C_RET: st <= ret_st;                    // CS stays low: the caller decides

        // CS high + 8 clocks, then go on
        END_CS: if ( x_done ) begin
          n  <= '0;
          st <= ret_st;
        end

        FAIL: begin
          sd_cs      <= 1'b1;
          card_ready <= 1'b0;
          if ( rd_busy ) begin
            rd_busy <= 1'b0;
            rd_err  <= 1'b1;
          end
          wait_cnt <= '0;
          sd_reset <= 1'b0;
          st       <= PWR_WAIT;
        end

        default: st <= FAIL;
      endcase
    end
  end
//____________________________________________________________________________//

endmodule
