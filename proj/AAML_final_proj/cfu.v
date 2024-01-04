`timescale 1ns/10ps
// `include "/home/kie/MyProjects/aaml/CFU-Playground/proj/lab5/RTL/TPU.v"
`include "/home/kie/MyProjects/aaml/aaml-final-project/proj/AAML_final_proj/RTL/systolic.v"
`include "/home/kie/MyProjects/aaml/aaml-final-project/proj/AAML_final_proj/RTL/global_buffer.v"

// Copyright 2021 The CFU-Playground Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

module Cfu (
  input               cmd_valid,
  output              cmd_ready,
  input      [9:0]    cmd_payload_function_id,
  input      [31:0]   cmd_payload_inputs_0,
  input      [31:0]   cmd_payload_inputs_1,
  output reg          rsp_valid,
  input               rsp_ready,
  output reg [31:0]   rsp_payload_outputs_0,
  input               reset,
  input               clk
);

  wire            batch_mode;

  reg             A_wr_en = 0;
  wire [15:0]     A_index_w;
  wire [31:0]     A_data_out;
  reg  [31:0]     A_data_in;

  reg             B_wr_en = 0;
  wire [15:0]     B_index_w;
  wire [31:0]     B_data_out;
  reg  [31:0]     B_data_in;

  wire            C_wr_en;
  wire [15:0]     C_index_w;
  wire [127:0]    C_data_out;
  wire [127:0]    C_data_in;

  reg             TPU_enable = 0;
  wire [15:0]     K;
  wire            TPU_busy;

  reg  [15:0]     A_index_CFU = 0;
  reg  [15:0]     B_index_CFU = 0;
  reg  [15:0]     C_index_CFU = 0;

  wire [15:0]     A_index_TPU;
  wire [15:0]     B_index_TPU;
  wire [15:0]     C_index_TPU;

  wire            cmd_pulse;
  wire signed [31:0] B_offset;

  assign K = cmd_inputs_0[15:0];
  assign B_offset = cmd_inputs_1;

  SystolicArray my_tpu(
    .clk(clk),
    .K(K),
    .B_offset(B_offset),
    .A_index(A_index_TPU),
    .A_data(A_data_out),
    .B_index(B_index_TPU),
    .B_data(B_data_out),
    .C_index(C_index_TPU),
    .C_data_out(C_data_in),
    .C_wr_en(C_wr_en),
    .enable(TPU_enable),
    .busy(TPU_busy)
  );


  global_buffer #(
      .ADDR_BITS(14),
      .DATA_BITS(8)
  )
  gbuff_A(
      .clk(clk),
      .wr_en(A_wr_en),
      .batch_mode(batch_mode),
      .index(A_index_w),
      .data_in(A_data_in),
      .data_out(A_data_out)
  );

  global_buffer #(
      .ADDR_BITS(14),
      .DATA_BITS(8)
  ) gbuff_B(
      .clk(clk),
      .wr_en(B_wr_en),
      .batch_mode(batch_mode),
      .index(B_index_w),
      .data_in(B_data_in),
      .data_out(B_data_out)
  );


  global_buffer #(
      .ADDR_BITS(12),
      .DATA_BITS(32)
  ) gbuff_C(
      .clk(clk),
      .wr_en(C_wr_en),
      .batch_mode(batch_mode),
      .index(C_index_w),
      .data_in(C_data_in),
      .data_out(C_data_out)
  );

  wire [31:0] cmd_inputs_0;
  wire [31:0] cmd_inputs_1;
  wire [6:0]  funct_id;
  wire [2:0]  opcode;

  reg [31:0] cmd_inputs_0_reg = 0;
  reg [31:0] cmd_inputs_1_reg = 0;
  reg [6:0]  funct_id_reg = 0;
  reg [2:0]  opcode_reg = 0;

  assign cmd_ready = cur_state == STATE_IDLE;
  assign cmd_pulse = (cmd_valid && cur_state == STATE_IDLE);
  assign opcode =  cmd_pulse ? cmd_payload_function_id[2:0] : opcode_reg;
  assign funct_id = cmd_pulse ? cmd_payload_function_id[9:3] : funct_id_reg;
  assign cmd_inputs_0 = cmd_pulse ? cmd_payload_inputs_0 : cmd_inputs_0_reg;
  assign cmd_inputs_1 = cmd_pulse ? cmd_payload_inputs_1 : cmd_inputs_1_reg;
  assign batch_mode = (cur_state == STATE_EXEC);
  
  localparam STATE_IDLE = 0;
  localparam STATE_EXEC = 1;
  localparam STATE_READ_MEM = 2;
  localparam STATE_RSP_READY = 7;

  localparam OP_NOOP = 0;
  localparam OP_WRITE_MEM = 1;
  localparam OP_COMPUTE = 2;
  localparam OP_READ_MEM = 3;
  localparam OP_DEBUG_OUT = 7;

  localparam DEBUG_READ_A = 0;
  localparam DEBUG_READ_B = 1;

  reg [2:0] cur_state = STATE_IDLE;
  reg [2:0] next_state = STATE_IDLE;

  always @(posedge clk, posedge reset) begin
    if (reset) begin
      cmd_inputs_0_reg <= 32'b0;
      cmd_inputs_1_reg <= 32'b0;
    end
    else if (cmd_pulse) begin
      cmd_inputs_0_reg <= cmd_payload_inputs_0;
      cmd_inputs_1_reg <= cmd_payload_inputs_1;
      funct_id_reg <= cmd_payload_function_id[9:3];
      opcode_reg <= cmd_payload_function_id[2:0];
    end
    else if(cur_state == STATE_RSP_READY) begin
      cmd_inputs_0_reg <= 0;
      cmd_inputs_1_reg <= 0;
      funct_id_reg <= 0;
      opcode_reg <= OP_NOOP;

    end
  end

  always @(posedge clk, posedge reset) begin
    if (reset) begin
      cur_state <= STATE_IDLE;
    end
    else begin
      cur_state <= next_state;
    end
  end

  always @(*) begin
    case (cur_state)
      STATE_IDLE: begin
        if (cmd_valid) begin
          if (opcode == OP_COMPUTE) next_state = STATE_EXEC;
          else if (opcode == OP_READ_MEM || opcode == OP_DEBUG_OUT) next_state = STATE_READ_MEM;
          else next_state = STATE_RSP_READY;
        end
        else next_state = STATE_IDLE;
        rsp_valid = 0;

      end
      STATE_EXEC: begin
        if (~TPU_busy) next_state = STATE_RSP_READY;
        else next_state = STATE_EXEC;
        rsp_valid = 0;

      end
      STATE_READ_MEM: begin
        next_state = STATE_RSP_READY;
        rsp_valid = 0;
      end
      STATE_RSP_READY: begin
        rsp_valid = 1;
        if (rsp_valid && rsp_ready) next_state = STATE_IDLE;
        else next_state = STATE_RSP_READY;

      end

      default:;
    endcase
  end

  reg [31:0] counter = 0;
  assign A_index_w = cur_state == STATE_EXEC ? A_index_TPU: A_index_CFU;
  assign B_index_w = cur_state == STATE_EXEC ? B_index_TPU: B_index_CFU;
  assign C_index_w = cur_state == STATE_EXEC ? C_index_TPU: C_index_CFU;

  always @(*) begin
    if (opcode == OP_READ_MEM) begin
      rsp_payload_outputs_0 = C_data_out[31:0];
    end
    else if (opcode == OP_DEBUG_OUT) begin
      if (funct_id == DEBUG_READ_A) rsp_payload_outputs_0 = A_data_out;
      else if (funct_id == DEBUG_READ_B) rsp_payload_outputs_0 = B_data_out;
      else rsp_payload_outputs_0 = 300 + opcode;
    end
  else if (opcode == OP_COMPUTE) begin
    rsp_payload_outputs_0 = counter;
  end
    else begin
      rsp_payload_outputs_0 = 0;
    end
  end

  always @(*) begin
    if (cur_state == STATE_IDLE && opcode == OP_WRITE_MEM && cmd_pulse) begin
      if (funct_id == 0) begin
        A_wr_en = 1;
        B_wr_en = 0;
      end
      else if (funct_id == 1) begin
        A_wr_en = 0;
        B_wr_en = 1;
      end
      else begin
        A_wr_en = 0;
        B_wr_en = 0;
      end
    end
    else begin
      A_wr_en = 0;
      B_wr_en = 0;
    end

  end

  always @(*) begin
    if (cur_state == STATE_IDLE && opcode == OP_WRITE_MEM) begin
      A_data_in = cmd_inputs_1;
      B_data_in = cmd_inputs_1;
    end
    else begin
      A_data_in = 0;
      B_data_in = 0;
    end
  end

  always @(*) begin
    A_index_CFU = cmd_inputs_0[15:0];
    B_index_CFU = cmd_inputs_0[15:0];
    C_index_CFU = cmd_inputs_0[15:0];
  end


  // for testing
  // assign C_wr_en = cur_state == STATE_EXEC;
  // assign C_data_in = A_data_out * B_data_out;

  always @(posedge clk) begin
    case (cur_state)
      STATE_IDLE: begin
        if (opcode == OP_NOOP && cmd_valid && funct_id == 0) begin
          counter <= 0;
        end
        else if (opcode == OP_COMPUTE && cmd_valid) begin
          TPU_enable <= 1;
        end

      end
      STATE_EXEC: begin
        TPU_enable <= 0;

        // for testing only
        counter <= counter + 1;
      end
      STATE_READ_MEM: begin
        // nothing... waiting for data
      end
      STATE_RSP_READY: begin
        // waiting for CPU to accept data
      end

      default:;
    endcase
  end

endmodule
