`include "/home/kie/MyProjects/aaml/CFU-Playground/proj/lab5/RTL/systolic.v"

module TPU(
  input clk,
  input rst_n,
  input              in_valid,
  input [7:0]        K,
  input [7:0]        M,
  input [7:0]        N,
  output reg         busy,

  output             A_wr_en,
  output [15:0]      A_index,
  output [31:0]      A_data_in,
  input  [31:0]      A_data_out,

  output             B_wr_en,
  output [15:0]      B_index,
  output [31:0]      B_data_in,
  input  [31:0]      B_data_out,

  output             C_wr_en,
  output [15:0]      C_index,
  output [127:0]     C_data_in,
  input  [127:0]     C_data_out
);
//* Implement your design here

parameter STATE_RESET = 0;
parameter STATE_CAL   = 1;
parameter STATE_SHIFT = 2;
parameter STATE_IDLE  = 4;


reg [7:0]    K_reg;
reg [7:0]    M_reg;
reg [7:0]    N_reg;
reg [7:0]    M_seg;
reg [7:0]    N_seg;
reg [2:0]    cur_state = STATE_IDLE;
reg [2:0]    next_state = STATE_IDLE;
reg [6:0]    A_segment = 0;
reg [6:0]    B_segment = 0;
wire [15:0]  A_relindex;
wire [15:0]  B_relindex;
wire [15:0]  C_relindex;
wire         array_busy;
reg          array_enable;
reg [16:0]   counter = 0;


SystolicArray u_s(
  .clk(clk),
  .M(M_reg),
  .N(N_reg),
  .K(K_reg),
  .A_index(A_relindex),
  .B_index(B_relindex),
  .C_index(C_relindex),
  .A_data(A_data_out),
  .B_data(B_data_out),
  .C_data_out(C_data_in),
  .C_wr_en(C_wr_en),
  .enable(array_enable),
  .busy(array_busy)
);

assign A_index = A_relindex + (A_segment * K_reg);
assign B_index = B_relindex + (B_segment * K_reg);
assign C_index = (A_segment << 2) + C_relindex + (B_segment * M_reg);
assign A_wr_en = 1'b0;
assign B_wr_en = 1'b0;

always @(posedge in_valid) begin
  K_reg = K;
  M_reg = M;
  N_reg = N;
  M_seg = ((M+3) >> 2);
  N_seg = ((N+3) >> 2);
end

always @(posedge clk, negedge rst_n, posedge in_valid) begin
  if (cur_state == STATE_SHIFT 
    || cur_state == STATE_CAL
    || cur_state == STATE_RESET
    || in_valid) begin
    busy = 1;
  end
  else begin
    busy = 0;
  end
end

always @(posedge clk) begin
  cur_state <= next_state;
end

always @(*) begin
case (cur_state)
  STATE_RESET: begin
    next_state = STATE_CAL;
  end
  STATE_CAL: begin
    if (array_busy) begin
      next_state = STATE_CAL;
    end
    else if (counter < M_seg * N_seg - 1) begin
      next_state = STATE_SHIFT;
    end
    else begin
      next_state = STATE_IDLE;
    end
  end
  STATE_SHIFT: begin
    next_state = STATE_CAL;
  end
  STATE_IDLE: begin
    if (in_valid) begin
      next_state = STATE_RESET;
    end
    else begin
      next_state = STATE_IDLE;
    end
  end
  default:;
endcase

end


always @(posedge clk) begin
case (cur_state) 
  STATE_RESET: begin
    array_enable <= 1;
    counter <= 0;
    A_segment <= 0;
    B_segment <= 0;

  end
  STATE_CAL: begin
    array_enable <= 0;
  end
  STATE_SHIFT: begin
    counter <= counter + 1;
    array_enable <= 1;
    A_segment <= (counter + 1) % M_seg;
    B_segment <= (counter + 1) / M_seg;
  end
  STATE_IDLE: begin
    array_enable <= 0;
    counter <= 0;
    A_segment <= 0;
    B_segment <= 0;


  end
  default:;
endcase

end
endmodule
