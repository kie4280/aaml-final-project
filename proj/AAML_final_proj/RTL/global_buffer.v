//============================================================================//
// AIC2021 Project1 - TPU Design                                              //
// file: global_buffer.v                                                      //
// description: global buffer read write behavior module                      //
// authors: kaikai (deekai9139@gmail.com)                                     //
//          suhan  (jjs93126@gmail.com)                                       //
//============================================================================//
module global_buffer #(parameter ADDR_BITS=8, parameter DATA_BITS=8)
(
  input clk,
  input wr_en, // Write enable: 1->write 0->read
  input batch_mode,
  input      [ADDR_BITS+1:0] index,
  input      [4*DATA_BITS-1:0] data_in,
  output reg [4*DATA_BITS-1:0] data_out
);

  parameter DEPTH = 2**ADDR_BITS;

  reg wr_en_reg [3:0];
  reg [DATA_BITS-1:0] data_in_reg [3:0];
  wire [DATA_BITS-1:0] data_out_w [3:0];
  reg [ADDR_BITS-1:0] index_internal;
  wire [3*DATA_BITS-1:0] zero_padding = 0;
  
  integer i;

  always @(*) begin
    if (batch_mode) begin
      wr_en_reg[0] = wr_en;
      wr_en_reg[1] = wr_en;
      wr_en_reg[2] = wr_en;
      wr_en_reg[3] = wr_en;
    end
    else begin
      wr_en_reg[0] = wr_en & (index[1:0] == 0);
      wr_en_reg[1] = wr_en & (index[1:0] == 1);
      wr_en_reg[2] = wr_en & (index[1:0] == 2);
      wr_en_reg[3] = wr_en & (index[1:0] == 3);
    end

  end
  always @(*) begin
    if(batch_mode) begin
      index_internal = index[ADDR_BITS-1:0];
    end
    else begin
      index_internal = index[ADDR_BITS+1:2];
    end
  end

  always @(*) begin
    if (batch_mode) begin
      data_in_reg[0] = data_in[DATA_BITS-1:0];
      data_in_reg[1] = data_in[2*DATA_BITS-1:DATA_BITS];
      data_in_reg[2] = data_in[3*DATA_BITS-1:2*DATA_BITS];
      data_in_reg[3] = data_in[4*DATA_BITS-1:3*DATA_BITS];
    end
    else begin
      data_in_reg[0] = data_in[DATA_BITS-1:0];
      data_in_reg[1] = data_in[DATA_BITS-1:0];
      data_in_reg[2] = data_in[DATA_BITS-1:0];
      data_in_reg[3] = data_in[DATA_BITS-1:0];
    end
  end


  always @(*) begin
    if (batch_mode) begin
      data_out = {data_out_w[3], data_out_w[2], data_out_w[1], data_out_w[0]};
    end
    else begin
      data_out = {zero_padding, data_out_w[index[1:0]]};
    end

  end
  

  BRAM #(ADDR_BITS, DATA_BITS)
  block0 (
    .clk(clk), 
    .wr_en(wr_en_reg[0]),
    .index(index_internal),
    .data_in(data_in_reg[0]),
    .data_out(data_out_w[0])
  );
  BRAM #(ADDR_BITS, DATA_BITS)
  block1 (
    .clk(clk), 
    .wr_en(wr_en_reg[1]),
    .index(index_internal),
    .data_in(data_in_reg[1]),
    .data_out(data_out_w[1])
  );
  BRAM #(ADDR_BITS, DATA_BITS)
  block2 (
    .clk(clk), 
    .wr_en(wr_en_reg[2]),
    .index(index_internal),
    .data_in(data_in_reg[2]),
    .data_out(data_out_w[2])
  );
  BRAM #(ADDR_BITS, DATA_BITS)
  block3 (
    .clk(clk), 
    .wr_en(wr_en_reg[3]),
    .index(index_internal),
    .data_in(data_in_reg[3]),
    .data_out(data_out_w[3])
  );


endmodule


module BRAM #(parameter ADDR_BITS=8, parameter DATA_BITS=8)
(
  input clk,
  input wr_en, // Write enable: 1->write 0->read
  input      [ADDR_BITS-1:0] index,
  input      [DATA_BITS-1:0] data_in,
  output reg [DATA_BITS-1:0] data_out
);

  parameter DEPTH = 2**ADDR_BITS;

  reg [DATA_BITS-1:0] ram [DEPTH-1:0];

  //----------------------------------------------------------------------------//
  // Global buffer read write behavior                                          //
  //----------------------------------------------------------------------------//

  always @ (posedge clk) begin
    if (wr_en) begin
      ram[index] <= data_in;
    end
    data_out <= ram[index];
  end


endmodule
