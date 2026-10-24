module tone_generator (
    input  wire         clk        ,
    input  wire         rst_n      ,
    input  wire  [2:0]  note_index ,
    input  wire  [2:0]  octave_sel ,
    output wire  [15:0] sample     ,
    output wire         valid      ,
    input  wire         ready
);

    localparam ACCUMULATOR_DEPTH = 32;
    
    // increment = f_tone * 2^32 / f_sample, f_sample = 49.15825 MHz / 1024 = 48006.1 Hz
    // (clk_audio is now 49.15865 MHz: +8 ppm = 0.014 cent, not worth recalculating)
    localparam [31:0] INCREMENT_C4 = 32'h01652AB0;   // 261.63 Hz
    localparam [31:0] INCREMENT_D4 = 32'h0190E48F;   // 293.66 Hz
    localparam [31:0] INCREMENT_E4 = 32'h01C1FF63;   // 329.63 Hz
    localparam [31:0] INCREMENT_F4 = 32'h01DCC136;   // 349.23 Hz
    localparam [31:0] INCREMENT_G4 = 32'h02172483;   // 392.00 Hz
    localparam [31:0] INCREMENT_A4 = 32'h0258AB98;   // 440.00 Hz
    localparam [31:0] INCREMENT_B4 = 32'h02A239A0;   // 493.88 Hz

    assign valid = 1'b1;   // data is always valid

  //------------- Choice of increment depends on note            -------------//
    reg  [ACCUMULATOR_DEPTH-1:0] base_increment;

    always_comb begin
      base_increment = INCREMENT_C4;
      case ( note_index )
        3'd0:    base_increment = INCREMENT_C4;
        3'd1:    base_increment = INCREMENT_D4;
        3'd2:    base_increment = INCREMENT_E4;
        3'd3:    base_increment = INCREMENT_F4;
        3'd4:    base_increment = INCREMENT_G4;
        3'd5:    base_increment = INCREMENT_A4;
        3'd6:    base_increment = INCREMENT_B4;
        default: base_increment = INCREMENT_C4;
      endcase
    end
 //------------- Choice of increment depends on octave           -------------//
    reg  [ACCUMULATOR_DEPTH-1:0] increment;

    always_comb begin
      increment = base_increment;
      case ( octave_sel )
        3'd0:    increment = base_increment >> 3;
        3'd1:    increment = base_increment >> 2;
        3'd2:    increment = base_increment >> 1;
        3'd3:    increment = base_increment     ;
        3'd4:    increment = base_increment << 1;
        3'd5:    increment = base_increment << 2;
        3'd6:    increment = base_increment << 3;
        3'd7:    increment = base_increment << 4;
        default: increment = base_increment     ;
      endcase
    end
 //------------- DDS generator                                   -------------//
    reg  [ACCUMULATOR_DEPTH-1:0] duty;

    always_ff @( posedge clk or negedge rst_n ) begin
      if ( !rst_n )
        duty <= {ACCUMULATOR_DEPTH{1'b0}};
      else if ( valid && ready )
        duty <= duty + increment;
    end

    assign sample = duty [ACCUMULATOR_DEPTH-1:ACCUMULATOR_DEPTH-16];

endmodule