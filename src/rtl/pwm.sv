module pwm #(
    parameter    FIFO_DATA_WIDTH = 32,                        
    parameter    SAMPLE_WIDTH    = 16,           
    parameter    PWM_WIDTH       = 10            
)(
    input  wire                        clk          ,
    input  wire                        rst_n        ,
    output wire                        aud_pwm      ,
    output reg                         aud_en       ,

    input  wire [FIFO_DATA_WIDTH-1:0]  fifo_rd_data ,
    output wire                        fifo_rd_en   ,
    input  wire                        fifo_empty
);

    reg [PWM_WIDTH-1:0] count;           // f_sample = 49.15865 MHz / 2^PWM_WIDTH = 48.006 kHz
    reg [PWM_WIDTH-1:0] duty;

    assign fifo_rd_en = !fifo_empty && ( &count );

    always_ff @( posedge clk or negedge rst_n ) begin
      if ( !rst_n ) begin
        count  <= {PWM_WIDTH{1'b0}};
        duty   <= {PWM_WIDTH{1'b0}};
        aud_en <= 1'b0;
      end
      else if ( &count ) begin
        count <= {PWM_WIDTH{1'b0}};
        if ( !fifo_empty ) begin
          aud_en <= 1'b1;
          duty   <= fifo_rd_data [SAMPLE_WIDTH-1 -: PWM_WIDTH];
        end
        else begin
          aud_en <= 1'b0;
        end
      end
      else begin
        count <= count + 1'b1;
      end
    end

    assign aud_pwm = ( count <= duty );

endmodule
