`timescale 1ns / 1ps

// Behavioral SDHC card in SPI mode, for simulation only.
// Answers CMD0, CMD8, CMD55/ACMD41 (busy twice, then ready), CMD58 (CCS = 1),
// CMD16 and CMD17 (512-byte block from the image file, one byte per line).
module sd_card_model #(
    parameter  IMG_FILE  = "sd.mem",
    parameter  IMG_BYTES = 1048576
)(
    input  wire  cs,
    input  wire  sck,
    input  wire  mosi,
    output logic miso
);
  logic [7:0] img [0:IMG_BYTES-1];
  initial $readmemh( IMG_FILE, img );

  // response bytes waiting to be sent
  logic [7:0] q [0:1023];
  int         q_head = 0, q_tail = 0;
  task automatic push (input [7:0] b);
    q[q_tail] = b;
    q_tail    = ( q_tail + 1 ) % 1024;
  endtask

  logic [7:0] rx_sh, tx_sh;
  int         bit_n   = 0;
  logic [7:0] cmd [0:5];
  int         cmd_n   = 0;
  int         acmd41_n = 0;
  logic       app     = 0;
  int         reads   = 0;

  initial begin
    miso  = 1'b1;
    tx_sh = 8'hFF;
  end

  always @( negedge cs ) begin
    bit_n = 0;
    miso  = tx_sh[7];
  end

  // master samples before the falling edge, we change after it
  always @( posedge sck ) if ( !cs ) begin
    rx_sh = { rx_sh[6:0], mosi };
    bit_n++;
    if ( bit_n == 8 ) begin
      bit_n = 0;
      byte_in( rx_sh );
      // next byte to send
      if ( q_head != q_tail ) begin
        tx_sh  = q[q_head];
        q_head = ( q_head + 1 ) % 1024;
      end
      else
        tx_sh = 8'hFF;
    end
    else
      tx_sh = { tx_sh[6:0], 1'b1 };
  end

  always @( negedge sck ) if ( !cs ) miso = tx_sh[7];

  task automatic byte_in (input [7:0] b);
    logic [31:0] arg;
    if ( cmd_n == 0 && b[7:6] != 2'b01 ) return;
    cmd[cmd_n] = b;
    cmd_n++;
    if ( cmd_n < 6 ) return;
    cmd_n = 0;
    arg   = { cmd[1], cmd[2], cmd[3], cmd[4] };
    push( 8'hFF );                                   // Ncr: one byte of delay
    case ( cmd[0][5:0] )
      6'd0:  push( 8'h01 );
      6'd8:  begin push( 8'h01 ); push( 8'h00 ); push( 8'h00 ); push( 8'h01 ); push( arg[7:0] ); end
      6'd55: begin push( acmd41_n >= 2 ? 8'h00 : 8'h01 ); app = 1; end
      6'd41: begin
        if ( app ) begin acmd41_n++; push( acmd41_n > 2 ? 8'h00 : 8'h01 ); end
        else push( 8'h05 );
        app = 0;
      end
      6'd58: begin push( 8'h00 ); push( 8'hC0 ); push( 8'hFF ); push( 8'h80 ); push( 8'h00 ); end
      6'd16: push( 8'h00 );
      6'd17: begin
        push( 8'h00 );
        repeat ( 3 ) push( 8'hFF );                   // access time
        push( 8'hFE );
        for ( int i = 0; i < 512; i++ )
          push( ( arg * 512 + i < IMG_BYTES ) ? img[arg * 512 + i] : 8'h00 );
        push( 8'h12 ); push( 8'h34 );                 // CRC (ignored)
        reads++;
      end
      default: push( 8'h04 );                         // illegal command
    endcase
  endtask
endmodule
