/*
 * Copyright 2026 Yusuf Rençber
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

module store_buffer #(
    parameter int DEPTH = 4
) (
    input logic clk,
    input logic rst,

    input logic push,
    input logic [20:0] push_address,
    input logic [31:0] push_data,
    input logic [3:0] push_dqm,

    input logic pop,
    output logic empty,
    output logic full,
    output logic [20:0] head_address,
    output logic [31:0] head_data,
    output logic [3:0] head_dqm
);
    localparam int POINTER_BITS = $clog2(DEPTH);

    logic [20:0] addresses [0:DEPTH - 1];
    logic [31:0] data [0:DEPTH - 1];
    logic [3:0] dqms [0:DEPTH - 1];
    logic [POINTER_BITS - 1:0] head;
    logic [POINTER_BITS - 1:0] tail;
    logic [POINTER_BITS:0] count;

    assign empty = count == 0;
    assign full = count == DEPTH;
    assign head_address = addresses[head];
    assign head_data = data[head];
    assign head_dqm = dqms[head];

    always_ff @(posedge clk) begin
        if (push) begin
            addresses[tail] <= push_address;
            data[tail] <= push_data;
            dqms[tail] <= push_dqm;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            head <= '0;
            tail <= '0;
            count <= '0;
        end else begin
            if (push)
                tail <= tail + 1'b1;

            if (pop)
                head <= head + 1'b1;

            if (push && !pop)
                count <= count + 1'b1;
            else if (pop && !push)
                count <= count - 1'b1;
        end
    end
endmodule
