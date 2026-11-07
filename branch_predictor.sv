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

module branch_predictor #(
    parameter int ENTRIES = 64,
    parameter int RETURN_DEPTH = 8
) (
    input logic clk,
    input logic rst,

    input logic [31:0] fetch_pc,
    input logic fetch_advance,
    output logic predict_taken,
    output logic [31:0] predict_target,
    output logic predict_hit,
    output logic [1:0] predict_counter,

    input logic redirect,

    input logic update,
    input logic [31:0] update_pc,
    input logic update_taken,
    input logic [31:0] update_target,
    input logic update_call,
    input logic update_return,
    input logic update_hit,
    input logic [1:0] update_counter,
    input logic [31:0] return_address
);
    localparam int INDEX_BITS = $clog2(ENTRIES);
    localparam int TAG_BITS = 12;
    localparam int RETURN_BITS = $clog2(RETURN_DEPTH);

    localparam logic [1:0] KIND_JUMP = 2'd0;
    localparam logic [1:0] KIND_CALL = 2'd1;
    localparam logic [1:0] KIND_RETURN = 2'd2;

    logic [ENTRIES - 1:0] valid;
    logic [TAG_BITS - 1:0] tags [0:ENTRIES - 1];
    logic [29:0] targets [0:ENTRIES - 1];
    logic [1:0] counters [0:ENTRIES - 1];
    logic [1:0] kinds [0:ENTRIES - 1];

    logic [29:0] returns [0:RETURN_DEPTH - 1];
    logic [RETURN_BITS - 1:0] return_top;
    logic [RETURN_BITS - 1:0] committed_top;

    function automatic logic [TAG_BITS - 1:0] tag_of(input logic [31:0] pc);
        return {pc[31:30], pc[2 + INDEX_BITS +: TAG_BITS - 2]};
    endfunction

    wire [INDEX_BITS - 1:0] fetch_index = fetch_pc[2 +: INDEX_BITS];
    wire [INDEX_BITS - 1:0] update_index = update_pc[2 +: INDEX_BITS];
    wire [1:0] fetch_kind = kinds[fetch_index];

    assign predict_hit = valid[fetch_index] && tags[fetch_index] == tag_of(fetch_pc);
    assign predict_counter = counters[fetch_index];
    assign predict_taken = predict_hit && predict_counter[1];
    assign predict_target = {fetch_kind == KIND_RETURN ? returns[return_top] : targets[fetch_index], 2'b00};

    wire push = fetch_advance && predict_taken && fetch_kind == KIND_CALL;
    wire pop = fetch_advance && predict_taken && fetch_kind == KIND_RETURN;
    wire commit_push = update && update_call;
    wire commit_pop = update && update_return;
    wire [RETURN_BITS - 1:0] committed_next = commit_push ? committed_top + 1'b1 : (commit_pop ? committed_top - 1'b1 : committed_top);

    wire write = update && (update_taken || update_hit);
    logic [1:0] next_counter;

    always_comb begin
        if (!update_hit)
            next_counter = 2'b10;
        else if (update_taken)
            next_counter = update_counter == 2'b11 ? 2'b11 : update_counter + 2'b01;
        else
            next_counter = update_counter == 2'b00 ? 2'b00 : update_counter - 2'b01;
    end

    always_ff @(posedge clk) begin
        if (write) begin
            tags[update_index] <= tag_of(update_pc);
            targets[update_index] <= update_target[31:2];
            counters[update_index] <= next_counter;
            kinds[update_index] <= update_return ? KIND_RETURN : (update_call ? KIND_CALL : KIND_JUMP);
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            valid <= '0;
            return_top <= '0;
            committed_top <= '0;

            for (int i = 0; i < RETURN_DEPTH; i++)
                returns[i] <= '0;
        end else begin
            if (write)
                valid[update_index] <= 1'b1;

            if (redirect) begin
                if (commit_push)
                    returns[committed_next] <= return_address[31:2];
            end else if (push) begin
                returns[return_top + 1'b1] <= fetch_pc[31:2] + 30'd1;
            end

            committed_top <= committed_next;

            if (redirect)
                return_top <= committed_next;
            else if (push)
                return_top <= return_top + 1'b1;
            else if (pop)
                return_top <= return_top - 1'b1;
        end
    end
endmodule
