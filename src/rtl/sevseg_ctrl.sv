module sevseg_ctrl (
  input  wire           clk                  ,
  input  wire           arst_n               ,
  input  wire   [31:0]  sevseg_32bit_hex_val ,

  output logic  [6:0]   seg_active_n         ,
  output logic          don_active_n         ,
  output logic  [7:0]   anodes
);
  reg [2:0]  sevseg_cntr;

  always @(posedge clk or negedge arst_n) begin
    if ( !arst_n ) begin
      seg_active_n    <= hex_to_seg(0);
      don_active_n    <= ~0;
      anodes          <= ~8'b00000001;
      sevseg_cntr     <= 3'b0;
    end else begin
      seg_active_n    <= hex_to_seg(sevseg_32bit_hex_val[sevseg_cntr*4 +: 4]);  //https://www.francisz.cn/download/IEEE_Standard_1800-2012%20SystemVerilog.pdf 11.5.1 Vector bit-select and part-select addressing
      don_active_n    <= ~0;
      anodes          <= ~(1 << sevseg_cntr);
      sevseg_cntr     <= sevseg_cntr +1'b1;
    end
  end

//------------- Functions                                        -------------//
  function [6:0] hex_to_seg (input [3:0] hex);
    case (hex)
      'h0: hex_to_seg = 'b1000000;  // g f e d c b a
      'h1: hex_to_seg = 'b1111001;
      'h2: hex_to_seg = 'b0100100;  //   --a--
      'h3: hex_to_seg = 'b0110000;  //  |     |
      'h4: hex_to_seg = 'b0011001;  //  f     b
      'h5: hex_to_seg = 'b0010010;  //  |     |
      'h6: hex_to_seg = 'b0000010;  //   --g--
      'h7: hex_to_seg = 'b1111000;  //  |     |
      'h8: hex_to_seg = 'b0000000;  //  e     c
      'h9: hex_to_seg = 'b0011000;  //  |     |
      'ha: hex_to_seg = 'b0001000;  //   --d--
      'hb: hex_to_seg = 'b0000011;
      'hc: hex_to_seg = 'b1000110;
      'hd: hex_to_seg = 'b0100001;
      'he: hex_to_seg = 'b0000110;
      'hf: hex_to_seg = 'b0001110;
    endcase
  endfunction
//____________________________________________________________________________//
endmodule
