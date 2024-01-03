/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_

#include <algorithm>
#include <array>
#include <cstdint>

#include "cfu.h"
#include "cstdio"
#include "models/my_cycles.h"
#include "perf.h"
#include "playground_util/print_params.h"
#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/portable_tensor_utils.h"

extern long long unsigned my_cycles;

namespace tflite {
namespace reference_integer_ops {

// matrix multiply with matrix B in transposed form
template <int max_M, int max_K, int max_N>
int matrixMult(std::array<int32_t, max_M * max_N>& C,
               const std::array<int32_t, max_M * max_K>& A,
               const std::array<int32_t, max_K * max_N>& BT, int m, int k,
               int n) {
  for (int a = 0; a < m; ++a) {
    for (int b = 0; b < n; ++b) {
      const int o_idx = a * n + b;
      C[o_idx] = 0;
      for (int c = 0; c < k; ++c) {
        const int a_idx = a * k + c;
        const int b_idx = b * k + c;
        C[o_idx] += A[a_idx] * BT[b_idx];
      }
    }
  }
  return 0;
}

// cfu matrix multiply with matrix B in transposed form
template <int max_M, int max_K, int max_N>
int cfu_mul(std::array<int32_t, max_M * max_N>& C,
            const std::array<int8_t, max_M * max_K>& A,
            const std::array<int8_t, max_K * max_N>& BT, int m, int k, int n, int32_t B_offset) {
  const int m_blocks = (m + 3) / 4;
  const int n_blocks = (n + 3) / 4;
  int r = cfu_op0(0, 0, 0);  // reset the cfu

  for (int a = 0; a < m_blocks; ++a) {
    // load A
    int a_counter = 0;
    int row_offset = 4 * a;
    for (int i = 0; i < k; ++i) {
      for (int j = 0; j < 4; ++j) {
        const int row = row_offset + j;
        int val;
        if (row >= m) {
          val = 0;
        } else {
          val = A[row * k + i];
        }
        cfu_op1(0, a_counter++, val);
      }
    }

    for (int b = 0; b < n_blocks; ++b) {
      // load B
      int b_counter = 0;
      const int col_offset = 4 * b;
      for (int i = 0; i < k; ++i) {
        for (int j = 0; j < 4; ++j) {
          const int row = col_offset + j;
          int val;
          if (row >= n) {
            val = 0;
          } else {
            val = BT[row * k + i];
          }
          cfu_op1(1, b_counter++, val);
        }
      }

      // start compute
      r = cfu_op2(0, k, B_offset);
      // retrieve C
      int c_counter = 0;
      for (int c_r = 0; c_r < 4; ++c_r) {
        for (int c_c = 0; c_c < 4; ++c_c) {
          int32_t c = cfu_op3(0, c_counter++, 0);
          const int row = row_offset + c_r;
          const int col = col_offset + c_c;
          if (row < m && col < n) {
            C[row * n + col] = c;
          }
        }
      }
    }
  }
  return r;
}

// Fixed-point per-channel-quantization convolution reference kernel.
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data) {
  // Format is:
  // "padding_type", "padding_width", "padding_height", "padding_width_offset",
  // "padding_height_offset", "stride_width", "stride_height",
  // "dilation_width_factor", "dilation_height_factor", "input_offset",
  // "weights_offset", "output_offset", "output_multiplier", "output_shift",
  // "quantized_activation_min", "quantized_activation_max",
  // "input_batches", "input_height", "input_width", "input_depth",
  // "filter_output_depth", "filter_height", "filter_width",
  // "filter_input_depth", "output_batches", "output_height", "output_width",
  // "output_depth", print_conv_params(params, input_shape, filter_shape,
  // output_shape);

  // Get parameters.
  const int32_t input_offset = params.input_offset;  // r = s(q - Z)
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int32_t output_offset = params.output_offset;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // printf("%ld %ld %ld %ld\n", input_shape.Dims(1), input_shape.Dims(2),
  //        input_shape.Dims(3), input_shape.Dims(4));
  // printf("%ld %ld %ld %ld\n", filter_shape.Dims(1), filter_shape.Dims(2),
  //        filter_shape.Dims(3), filter_shape.Dims(4));
  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  // printf("batches %d", batches);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  // printf("output_depth %d\n", output_depth);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  // const int groups = input_depth / filter_input_depth;
  // printf("groups %d\n", groups);
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  // const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  const int MAX_M = 400;
  const int MAX_K = 900;
  const int MAX_N = 3600;

  for (int batch = 0; batch < batches; ++batch) {
    // im2col buffers
    std::array<int32_t, MAX_M * MAX_N> unrolled_output;
    std::array<int8_t, MAX_M * MAX_K> unrolled_weight;
    std::array<int8_t, MAX_K * MAX_N> unrolled_input;

    int weight_h = output_depth;                                       // M
    int weight_w = filter_height * filter_width * filter_input_depth;  // K
    int input_h = output_height * output_width;                        // N

    printf("m k n, %d %d %d\n", weight_h, weight_w, input_h);
    printf("input offset %ld\n", input_offset);

    // reorder inputs so that conv becomes matmul
    int input_counter = 0;
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;

        for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
          const int in_y = in_y_origin + dilation_height_factor * filter_y;
          for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
            const int in_x = in_x_origin + dilation_width_factor * filter_x;

            // Zero padding by omitting the areas outside the image.
            const bool is_point_inside_image =
                (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                (in_y < input_height);

            // if (!is_point_inside_image) {
            //   continue;
            // }

            for (int in_channel = 0; in_channel < filter_input_depth;
                 ++in_channel) {
              int8_t input_val = 0;
              if (is_point_inside_image) {
                input_val = input_data[Offset(input_shape, batch, in_y, in_x,
                                              in_channel)];
              }
              unrolled_input[input_counter++] = input_val;
            }
          }
        }
      }
    }

    // reorder filters so that conv becomes matmul
    int weight_counter = 0;
    for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
      // auto group = out_channel / filters_per_group;

      for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
        for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
          for (int in_channel = 0; in_channel < filter_input_depth;
               ++in_channel) {
            int8_t filter_val = filter_data[Offset(
                filter_shape, out_channel, filter_y, filter_x, in_channel)];
            unrolled_weight[weight_counter++] = filter_val;
          }
        }
      }
    }

    unsigned my_start = perf_get_mcycle();
    // doing the conv using matrix multiply
    // matrixMult<MAX_M, MAX_K, MAX_N>(unrolled_output, unrolled_weight, unrolled_input, weight_h,
    //            weight_w, input_h);
    cfu_mul<MAX_M, MAX_K, MAX_N>(unrolled_output, unrolled_weight,
                                 unrolled_input, weight_h, weight_w, input_h, input_offset);
    unsigned my_finish = perf_get_mcycle();
    my_cycles += (my_finish - my_start);

    // output write back
    for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
      for (int out_y = 0; out_y < output_height; ++out_y) {
        for (int out_x = 0; out_x < output_width; ++out_x) {
          const int idx = out_channel * output_width * output_height +
                          out_y * output_width + out_x;
          int32_t acc = unrolled_output[idx];
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          acc = MultiplyByQuantizedMultiplier(
              acc, output_multiplier[out_channel], output_shift[out_channel]);
          acc += output_offset;
          acc = std::max(acc, output_activation_min);
          acc = std::min(acc, output_activation_max);
          output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              static_cast<int8_t>(acc);
        }
      }
    }
  }
}

inline void ConvPerChannelWithPackedInt4Weights(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_input, int8_t* unpacked_filter_data,
    const RuntimeShape& bias_shape, const int32_t* bias_data,
    const RuntimeShape& output_shape, int8_t* output_data) {
  TFLITE_DCHECK(unpacked_filter_data != nullptr);
  tflite::tensor_utils::UnpackDenseInt4IntoInt8(
      filter_input, filter_shape.FlatSize(), unpacked_filter_data);
  ConvPerChannel(params, output_multiplier, output_shift, input_shape,
                 input_data, filter_shape, unpacked_filter_data, bias_shape,
                 bias_data, output_shape, output_data);
}

// Fixed-point per-channel-quantization convolution reference kernel.
// 16-bit data and 8-bit filter
template <typename AccumScalar>
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int16_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const AccumScalar* bias_data, const RuntimeShape& output_shape,
    int16_t* output_data) {
  // Get parameters.
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          auto group = out_channel / filters_per_group;
          AccumScalar acc = 0;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;

              // Zero padding by omitting the areas outside the image.
              const bool is_point_inside_image =
                  (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                  (in_y < input_height);

              if (!is_point_inside_image) {
                continue;
              }

              for (int in_channel = 0; in_channel < filter_input_depth;
                   ++in_channel) {
                int32_t input_val =
                    input_data[Offset(input_shape, batch, in_y, in_x,
                                      in_channel + group * filter_input_depth)];
                int32_t filter_val = filter_data[Offset(
                    filter_shape, out_channel, filter_y, filter_x, in_channel)];
                // Accumulate with 64 bits accumulator.
                // int64_t += int8_t * int16_t so the highest value we can
                // get from each accumulation is [-127, 127] * ([-32768,
                // 32767] -
                // [-32768, 32767]), which is [-8322945, 8322945].
                // log2(8322945) = 22.99.
                acc += filter_val * input_val;
              }
            }
          }
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          int32_t scaled_acc = MultiplyByQuantizedMultiplier(
              acc, output_multiplier[out_channel], output_shift[out_channel]);
          scaled_acc = std::max(scaled_acc, output_activation_min);
          scaled_acc = std::min(scaled_acc, output_activation_max);
          output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              static_cast<int16_t>(scaled_acc);
        }
      }
    }
  }
}

}  // namespace reference_integer_ops
}  // namespace tflite

#endif  // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
