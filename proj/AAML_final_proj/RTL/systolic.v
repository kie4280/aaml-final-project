module SystolicArray 
#(parameter A_bits=8, parameter A_depth=14, parameter B_bits=9, 
  parameter B_depth=14, parameter C_depth=2, parameter ar_size=4)
(
  input wire                clk,
  input wire [15:0]         K,
  input      [31:0]         B_offset,
  output reg [A_depth-1:0]  A_index,
  input wire [4*A_bits-1:0] A_data,
  output reg [B_depth-1:0]  B_index,
  input wire [4*B_bits-1:0] B_data,
  output reg [C_depth-1:0]  C_index,
  output reg [127:0]        C_data_out,
  output wire               C_wr_en,
  input  wire               enable,
  output reg                busy
);


localparam STATE_IDLE       = 0;
localparam STATE_BUSY       = 1;
localparam STATE_WRITE      = 2;

reg [15:0] counter;
reg [15:0] counter_stop;
reg [2:0] cur_state = STATE_IDLE;
reg [2:0] next_state = STATE_IDLE;

wire [B_bits-1:0] inter_row [0:ar_size][0:ar_size-1];
wire [A_bits-1:0] inter_col [0:ar_size-1][0:ar_size];
reg [B_bits-1:0] top_data [0:ar_size-1][0:ar_size-1];
reg [A_bits-1:0] left_data [0:ar_size-1][0:ar_size-1];
wire [31:0] results [0:ar_size][0:ar_size];

reg PE_clear = 1;
reg PE_enable = 1;

generate
genvar gi, gj;
  for(gi=0; gi < ar_size; gi=gi+1) begin 
    for(gj=0; gj < ar_size; gj=gj+1) begin
      PE u_pe(
        clk,
        PE_clear, 
        PE_enable,
        B_offset,
        inter_col[gi][gj],
        inter_row[gi][gj],
        inter_col[gi][gj+1],
        inter_row[gi+1][gj],
        results[gi][gj]
      );
    end
  end

  for(gi=0; gi < ar_size; gi=gi+1) begin
    assign inter_col[gi][0] = left_data[gi][0];
  end
  for (gj=0; gj < ar_size; gj=gj+1) begin
    assign inter_row[0][gj] = top_data[0][gj];
  end
endgenerate


assign C_wr_en = cur_state == STATE_WRITE;

always @(*) begin
  if (cur_state == STATE_WRITE 
    || cur_state == STATE_BUSY
    || enable) begin
    busy = 1;
  end
  else begin
    busy = 0;
  end
end

always @(*) begin
  if (cur_state == STATE_BUSY) begin
    PE_enable = 1;
    PE_clear = 0;
  end
  else if (cur_state == STATE_WRITE) begin
    PE_enable = 0;
    PE_clear = 0;
  end
  else begin
    PE_enable = 0;
    PE_clear = 1;
  end
end

always @(*) begin
  C_data_out = {
    results[counter][3],
    results[counter][2],
    results[counter][1],
    results[counter][0]
  };
end

always @(*) begin
  if (cur_state == STATE_WRITE || cur_state == STATE_BUSY) begin
    A_index = counter;
    B_index = counter;
    C_index = counter;
  end
  else begin
    A_index = 0;
    B_index = 0;
    C_index = 0;
  end

end
integer ai;

always @(*) begin
  for (ai=0; ai < ar_size; ai=ai+1) begin
    top_data[ai][ai] = (counter <= K ? B_data[ai*B_bits +: B_bits] : 0);
    left_data[ai][ai] = (counter <= K ? A_data[ai*A_bits +: A_bits] : 0);
  end

end

always @(posedge clk) begin
  cur_state <= next_state; 
end

always @(*) begin
case (cur_state)
  
  STATE_IDLE: begin
    counter_stop = 0;
    if (enable) next_state = STATE_BUSY;
    else next_state = STATE_IDLE;
  end

  STATE_BUSY: begin
    counter_stop = K + (2*ar_size - 1);
    if (counter >= counter_stop) begin
      next_state = STATE_WRITE;
    end
    else next_state = STATE_BUSY;
  end

  STATE_WRITE: begin
    counter_stop = ar_size-1;
    if (counter >= counter_stop) begin
      next_state = STATE_IDLE;
    end
    else next_state = STATE_WRITE;
  end
  default: begin
    next_state = STATE_IDLE;
    counter_stop = 0;
  end

endcase
end

integer i, j;

always @(posedge clk) begin
case (cur_state)

  STATE_IDLE: begin
    if (enable) counter <= 1;
    else counter <= 0;
  end

  STATE_BUSY: begin
    if (counter >= counter_stop) begin
      counter <= 0;
    end
    else begin
      counter <= counter + 1;
    end

    for (i=0; i < ar_size; i=i+1) begin
      for (j=0; j < i; j=j+1) begin
        top_data[j][i] <= top_data[j+1][i];
        left_data[i][j] <= left_data[i][j+1];
      end
    end
  end

  STATE_WRITE: begin
    counter <= counter + 1;

  end
  default: ;
endcase
end

endmodule


module PE #(parameter A_bits=8, parameter B_bits=9)(
  input wire clk,
  input wire clear,
  input wire enable,
  input wire signed [31:0]       B_offset,
  input wire        [A_bits-1:0] left,
  input wire        [B_bits-1:0] top,
  output reg        [A_bits-1:0] right,
  output reg        [B_bits-1:0] bottom,
  output reg signed [31:0]       result
); 

wire signed [31:0] mul;
assign mul = $signed(left) * ($signed(top[B_bits-2:0]) + B_offset);

always @(posedge clk) begin
  if (clear == 1) begin
    result <= 0;
    right <= 0;
    bottom <= 0;
  end 
  else if (enable) begin
    right <= left;
    bottom <= top;
    if (top[B_bits-1]) result <= result + mul;
    else result <= result;
  end
end
endmodule
