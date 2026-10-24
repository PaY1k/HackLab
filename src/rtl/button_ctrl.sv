module button_ctrl (
    input  wire         clk       ,
    input  wire         rst_n     ,

    input  wire         button_c  ,
    input  wire         button_u  ,
    input  wire         button_d  ,
    input  wire         button_r  ,
    input  wire         button_l  ,

    output reg          play      ,
    output reg [3:0]    volume    ,
    output reg [2:0]    note_index  
);
  //----------- Play/Pause                                       -----------//
    always_ff @( posedge clk ) begin
      if ( !rst_n )
        play <= 1'b0;
      else if ( button_c )
        play <= ~play;
    end
  //----------- Volume control                                   -----------//
    always_ff @( posedge clk ) begin
      if ( !rst_n )
        volume <= 4'd8;
      else if ( button_u && ( volume < 4'd15 ) )
        volume <= volume + 4'd1;
      else if ( button_d && ( volume > 4'd0 ) )
        volume <= volume - 4'd1;
    end
  //----------- Note switching                                  -----------//
    always_ff @( posedge clk ) begin
      if ( !rst_n )
        note_index <= 3'd0;
      else if ( button_r ) begin
        if ( note_index == 3'd6 )
          note_index <= 3'd0;
        else
          note_index <= note_index + 3'd1;
      end
      else if ( button_l ) begin
        if ( note_index == 3'd0 )
          note_index <= 3'd6;
        else
          note_index <= note_index - 3'd1;
      end
    end

endmodule