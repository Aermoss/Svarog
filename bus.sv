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

module bus #(
    parameter int CORES = 2
) (
    input logic clk,
    input logic rst,

    input logic [CORES - 1:0][31:0] cpu_fetch_addr,
    output logic [CORES - 1:0][31:0] cpu_fetch_read,
    output logic [CORES - 1:0] cpu_fetch_fault,

    input logic [CORES - 1:0] cpu_mem_access,
    input logic [CORES - 1:0] cpu_atomic,
    input logic [CORES - 1:0][3:0] cpu_atomic_op,
    input logic [CORES - 1:0] cpu_fence,
    input logic [CORES - 1:0] cpu_reservation_clear,
    input logic [CORES - 1:0][3:0] cpu_mem_we,
    input logic [CORES - 1:0][31:0] cpu_mem_addr,
    input logic [CORES - 1:0][31:0] cpu_mem_write,
    output logic [CORES - 1:0][31:0] cpu_mem_read,
    output logic [CORES - 1:0] cpu_stall,

    input logic [CORES - 1:0] cpu_user_mode,
    input logic [CORES - 1:0] io_conflict,

    output logic [3:0] bram_we,
    output logic [31:0] bram_addr,
    output logic [31:0] bram_write,
    input logic [31:0] bram_read,
    output logic [31:0] bram_fetch_addr,
    input logic [31:0] bram_fetch_read,

    output logic flash_req,
    output logic [23:0] flash_addr,
    input logic [31:0] flash_rdata,
    input logic flash_ready,

    output logic sdram_start,
    output logic sdram_write,
    output logic [1:0] sdram_length,
    output logic [20:0] sdram_address,
    output logic [31:0] sdram_data,
    output logic [3:0] sdram_dqm,
    input logic sdram_ready,
    input logic sdram_valid,
    input logic [31:0] sdram_read_data,

    output logic store_check,
    output logic [CORES - 1:0] store_owner,
    output logic [20:0] store_address,
    output logic [31:0] store_data,
    output logic [3:0] store_dqm,
    output logic [20:0] store_push_address,

    output logic [CORES - 1:0] icache_request,
    output logic [CORES - 1:0][10:0] icache_tag,
    input logic [CORES - 1:0] icache_lookup,
    input logic [CORES - 1:0][31:0] icache_read,
    input logic [CORES - 1:0] icache_fill_request,
    input logic [CORES - 1:0] icache_clearing,
    output logic [CORES - 1:0] icache_grant,
    input logic [CORES - 1:0] icache_start,
    input logic [CORES - 1:0][20:0] icache_address,
    input logic [CORES - 1:0] icache_word,
    input logic [CORES - 1:0] icache_done,

    output logic [CORES - 1:0] dcache_request,
    output logic [CORES - 1:0][10:0] dcache_tag,
    input logic [CORES - 1:0] dcache_lookup,
    input logic [CORES - 1:0][31:0] dcache_read,
    input logic [CORES - 1:0] dcache_fill_request,
    input logic [CORES - 1:0] dcache_clearing,
    output logic [CORES - 1:0] dcache_grant,
    input logic [CORES - 1:0] dcache_start,
    input logic [CORES - 1:0][20:0] dcache_address,
    input logic [CORES - 1:0] dcache_word,
    input logic [CORES - 1:0] dcache_done,

    input logic [CORES - 1:0][10:0] mmu_fetch_frame,
    input logic [CORES - 1:0] mmu_fetch_fault,
    input logic [CORES - 1:0] mmu_fetch_request,
    input logic [CORES - 1:0][10:0] mmu_data_frame,
    input logic [CORES - 1:0] mmu_data_request,
    input logic [CORES - 1:0] mmu_data_denied,
    output logic [CORES - 1:0] mmu_grant_data,
    output logic [CORES - 1:0] mmu_grant_fetch,
    input logic [CORES - 1:0] mmu_start,
    input logic [CORES - 1:0][20:0] mmu_address,
    input logic [CORES - 1:0] mmu_walk_done,
    input logic [CORES - 1:0] mmu_walk_failed
);
    localparam int OWNER_BITS = CORES > 1 ? $clog2(CORES) : 1;

    localparam logic [3:0] ATOMIC_SWAP = 4'd0;
    localparam logic [3:0] ATOMIC_ADD = 4'd1;
    localparam logic [3:0] ATOMIC_XOR = 4'd2;
    localparam logic [3:0] ATOMIC_AND = 4'd3;
    localparam logic [3:0] ATOMIC_OR = 4'd4;
    localparam logic [3:0] ATOMIC_MIN = 4'd5;
    localparam logic [3:0] ATOMIC_MAX = 4'd6;
    localparam logic [3:0] ATOMIC_MINU = 4'd7;
    localparam logic [3:0] ATOMIC_MAXU = 4'd8;
    localparam logic [3:0] ATOMIC_LOAD_RESERVED = 4'd9;
    localparam logic [3:0] ATOMIC_STORE_CONDITIONAL = 4'd10;

    logic [CORES - 1:0] fetch_window;
    logic [CORES - 1:0] data_window;
    logic [CORES - 1:0] fetch_denied;
    logic [CORES - 1:0] is_sdram_fetch;
    logic [CORES - 1:0] is_sdram_data;
    logic [CORES - 1:0] is_sdram_load;
    logic [CORES - 1:0] is_sdram_store;
    logic [CORES - 1:0] is_sdram_atomic;
    logic [CORES - 1:0] is_flash_data;
    logic [CORES - 1:0] is_bram_data;
    logic [CORES - 1:0][10:0] data_frame;
    logic [CORES - 1:0][20:0] sdram_word_addr;
    logic [CORES - 1:0] store_conflict;

    genvar lane;

    generate
        for (lane = 0; lane < CORES; lane++) begin : decode
            wire [31:0] fetch_address = cpu_fetch_addr[lane];
            wire [31:0] data_address = cpu_mem_addr[lane];

            assign fetch_window[lane] = fetch_address[31:30] == 2'b11;
            assign data_window[lane] = data_address[31:30] == 2'b11;
            assign fetch_denied[lane] = cpu_user_mode[lane] && !fetch_window[lane];

            assign is_sdram_fetch[lane] = (fetch_address[31:30] == 2'b01 || fetch_window[lane]) && !fetch_denied[lane];
            assign is_sdram_data[lane] = cpu_mem_access[lane] && (data_address[31:30] == 2'b01 || data_window[lane]);
            assign is_sdram_load[lane] = is_sdram_data[lane] && (cpu_mem_we[lane] == 4'b0000) && !cpu_atomic[lane];
            assign is_sdram_atomic[lane] = is_sdram_data[lane] && cpu_atomic[lane];
            assign is_sdram_store[lane] = is_sdram_data[lane] && (cpu_mem_we[lane] != 4'b0000);
            assign is_flash_data[lane] = cpu_mem_access[lane] && (data_address[31:30] == 2'b10) && (cpu_mem_we[lane] == 4'b0000);
            assign is_bram_data[lane] = cpu_mem_access[lane] && (data_address[31:30] == 2'b00);

            assign data_frame[lane] = data_window[lane] ? mmu_data_frame[lane] : data_address[22:12];
            assign sdram_word_addr[lane] = {data_frame[lane], data_address[11:2]};

            assign icache_request[lane] = is_sdram_fetch[lane];
            assign icache_tag[lane] = fetch_window[lane] ? mmu_fetch_frame[lane] : fetch_address[22:12];
            assign dcache_request[lane] = is_sdram_load[lane];
            assign dcache_tag[lane] = data_frame[lane];

            assign store_conflict[lane] = store_check && store_owner[lane] && is_sdram_data[lane] && data_address[11:2] == store_address[9:0];
        end
    endgenerate

    typedef enum logic [3:0] {
        S_IDLE,
        S_DCACHE,
        S_WALK_DATA,
        S_ICACHE,
        S_WALK_FETCH,
        S_FLASH_WAIT,
        S_FLASH_DONE,
        S_ATOMIC_READ,
        S_ATOMIC_WRITE,
        S_ATOMIC_DONE
    } state_t;

    state_t state;
    logic [OWNER_BITS - 1:0] owner;
    logic [OWNER_BITS - 1:0] last_owner;

    logic [31:0] flash_read_reg;
    logic [CORES - 1:0] flash_read_active;

    logic [31:0] atomic_old;
    logic [31:0] atomic_result;
    logic [31:0] atomic_new;
    logic [CORES - 1:0] atomic_active;
    logic atomic_issued;
    logic atomic_push;
    logic atomic_success;
    logic [CORES - 1:0] reservation_valid;
    logic [CORES - 1:0][20:0] reservation_address;
    wire [3:0] atomic_op = cpu_atomic_op[owner];
    wire [31:0] atomic_source = cpu_mem_write[owner];
    wire [20:0] atomic_address = sdram_word_addr[owner];

    logic [CORES - 1:0][31:0] read_data;
    logic [CORES - 1:0][31:0] read_hold;
    logic [CORES - 1:0] read_held;

    logic [CORES - 1:0][31:0] fetch_data;
    logic [CORES - 1:0][31:0] fetch_hold;
    logic [CORES - 1:0] fetch_held;
    logic [CORES - 1:0] fetch_fault_hold;
    logic [CORES - 1:0] fetch_fault_now;
    logic [CORES - 1:0] fetch_outside;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            fetch_outside <= '0;
        end else begin
            for (int c = 0; c < CORES; c++) begin
                if (!cpu_stall[c])
                    fetch_outside[c] <= c != 0 && !is_sdram_fetch[c];
            end
        end
    end


    logic buffer_empty;
    logic buffer_full;
    logic [20:0] buffer_address;
    logic [31:0] buffer_data;
    logic [3:0] buffer_dqm;

    logic [3:0][18:0] buffer_lines;
    logic [3:0] buffer_valid;
    logic [CORES - 1:0] dcache_conflict;
    logic [CORES - 1:0] icache_conflict;
    logic [CORES - 1:0] dcache_ready;
    logic [CORES - 1:0] icache_ready;
    logic [CORES - 1:0] other_ready;
    logic [CORES - 1:0] store_accept;
    logic [OWNER_BITS - 1:0] store_core;
    logic [CORES - 1:0] bram_conflict;
    logic [CORES - 1:0] store_blocked;
    logic [OWNER_BITS - 1:0] bram_core;

    wire any_store = |store_accept;
    wire any_push = any_store || atomic_push;
    wire drain = state == S_IDLE && !buffer_empty && sdram_ready;
    wire [20:0] push_address = atomic_push ? atomic_address : sdram_word_addr[store_core];
    wire [31:0] push_data = atomic_push ? atomic_new : cpu_mem_write[store_core];
    wire [3:0] push_dqm = atomic_push ? 4'b0000 : ~cpu_mem_we[store_core];

    always_comb begin
        case (atomic_op)
            ATOMIC_ADD: atomic_new = atomic_old + atomic_source;
            ATOMIC_XOR: atomic_new = atomic_old ^ atomic_source;
            ATOMIC_AND: atomic_new = atomic_old & atomic_source;
            ATOMIC_OR: atomic_new = atomic_old | atomic_source;
            ATOMIC_MIN: atomic_new = $signed(atomic_old) < $signed(atomic_source) ? atomic_old : atomic_source;
            ATOMIC_MAX: atomic_new = $signed(atomic_old) > $signed(atomic_source) ? atomic_old : atomic_source;
            ATOMIC_MINU: atomic_new = atomic_old < atomic_source ? atomic_old : atomic_source;
            ATOMIC_MAXU: atomic_new = atomic_old > atomic_source ? atomic_old : atomic_source;
            default: atomic_new = atomic_source;
        endcase

        atomic_success = reservation_valid[owner] && reservation_address[owner] == atomic_address;
        atomic_push = state == S_ATOMIC_WRITE && (atomic_op != ATOMIC_STORE_CONDITIONAL || atomic_success);
    end

    store_buffer store_buffer0 (
        .clk(clk),
        .rst(rst),
        .push(any_push),
        .push_address(push_address),
        .push_data(push_data),
        .push_dqm(push_dqm),
        .pop(drain),
        .empty(buffer_empty),
        .full(buffer_full),
        .head_address(buffer_address),
        .head_data(buffer_data),
        .head_dqm(buffer_dqm),
        .entry_lines(buffer_lines),
        .entry_valid(buffer_valid)
    );

    assign store_push_address = push_address;

    generate
        for (lane = 0; lane < CORES; lane++) begin : conflicts
            wire [18:0] dcache_line = dcache_address[lane][20:2];
            wire [18:0] icache_line = icache_address[lane][20:2];

            always_comb begin
                dcache_conflict[lane] = 1'b0;
                icache_conflict[lane] = 1'b0;

                for (int i = 0; i < 4; i++) begin
                    if (buffer_valid[i] && buffer_lines[i] == dcache_line)
                        dcache_conflict[lane] = 1'b1;

                    if (buffer_valid[i] && buffer_lines[i] == icache_line)
                        icache_conflict[lane] = 1'b1;
                end
            end
        end
    endgenerate

    always_comb begin
        for (int c = 0; c < CORES; c++) begin
            dcache_ready[c] = dcache_fill_request[c] && !dcache_conflict[c];
            icache_ready[c] = icache_fill_request[c] && !icache_conflict[c];
            other_ready[c] = buffer_empty && (mmu_data_request[c] || mmu_fetch_request[c] || is_flash_data[c] ||
                (is_sdram_atomic[c] && !mmu_data_denied[c]));
        end
    end

    always_comb begin
        for (int c = 0; c < CORES; c++) begin
            icache_grant[c] = state == S_ICACHE && owner == c;
            dcache_grant[c] = state == S_DCACHE && owner == c;
            mmu_grant_data[c] = state == S_WALK_DATA && owner == c;
            mmu_grant_fetch[c] = state == S_WALK_FETCH && owner == c;
            fetch_fault_now[c] = mmu_fetch_fault[c] || fetch_outside[c];
            cpu_fetch_fault[c] = fetch_held[c] ? fetch_fault_hold[c] : fetch_fault_now[c];
        end
    end

    logic [CORES - 1:0] wants_bus;
    logic [OWNER_BITS - 1:0] next_owner;
    logic next_found;
    wire [31:0] next_owner_address = cpu_mem_addr[next_owner];

    always_comb begin
        for (int c = 0; c < CORES; c++)
            wants_bus[c] = dcache_ready[c] || icache_ready[c] || other_ready[c];

        next_owner = '0;
        next_found = 1'b0;

        for (int step = 1; step <= CORES; step++) begin
            int candidate;
            candidate = (int'(last_owner) + step) % CORES;

            if (!next_found && wants_bus[candidate]) begin
                next_owner = candidate[OWNER_BITS - 1:0];
                next_found = 1'b1;
            end
        end
    end

    always_comb begin
        sdram_start = 1'b0;
        sdram_write = 1'b0;
        sdram_length = 2'd0;
        sdram_address = sdram_word_addr[0];
        sdram_data = cpu_mem_write[0];
        sdram_dqm = 4'b0000;

        case (state)
            S_IDLE: begin
                sdram_start = drain;
                sdram_write = 1'b1;
                sdram_address = buffer_address;
                sdram_data = buffer_data;
                sdram_dqm = buffer_dqm;
            end

            S_DCACHE: begin
                sdram_start = dcache_start[owner];
                sdram_length = 2'd3;
                sdram_address = dcache_address[owner];
            end

            S_ICACHE: begin
                sdram_start = icache_start[owner];
                sdram_length = 2'd3;
                sdram_address = icache_address[owner];
            end

            S_WALK_DATA, S_WALK_FETCH: begin
                sdram_start = mmu_start[owner];
                sdram_address = mmu_address[owner];
            end

            S_ATOMIC_READ: begin
                sdram_start = !atomic_issued && sdram_ready;
                sdram_address = atomic_address;
            end

            default: ;
        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            owner <= '0;
            last_owner <= CORES - 1;
            flash_req <= 1'b0;
            flash_addr <= 24'b0;
            flash_read_reg <= 32'b0;
            flash_read_active <= '0;
            read_hold <= '0;
            read_held <= '0;
            fetch_hold <= '0;
            fetch_held <= '0;
            fetch_fault_hold <= '0;
            store_check <= 1'b0;
            store_owner <= '0;
            atomic_old <= '0;
            atomic_result <= '0;
            atomic_active <= '0;
            atomic_issued <= 1'b0;
            reservation_valid <= '0;
            reservation_address <= '0;
            store_address <= 21'b0;
            store_data <= 32'b0;
            store_dqm <= 4'b0000;
        end else begin
            flash_read_active <= '0;
            atomic_active <= '0;
            flash_req <= 1'b0;
            store_check <= any_push;
            store_owner <= atomic_push ? (CORES'(1) << owner) : store_accept;

            if (any_push) begin
                store_address <= push_address;
                store_data <= push_data;
                store_dqm <= push_dqm;
            end

            for (int c = 0; c < CORES; c++) begin
                if (cpu_reservation_clear[c] || (store_check && reservation_address[c] == store_address))
                    reservation_valid[c] <= 1'b0;
            end

            for (int c = 0; c < CORES; c++) begin
                if (!cpu_stall[c]) begin
                    read_held[c] <= 1'b0;
                    fetch_held[c] <= 1'b0;
                end else begin
                    if (!read_held[c]) begin
                        read_hold[c] <= read_data[c];
                        read_held[c] <= 1'b1;
                    end

                    if (!fetch_held[c]) begin
                        fetch_hold[c] <= fetch_data[c];
                        fetch_fault_hold[c] <= fetch_fault_now[c];
                        fetch_held[c] <= 1'b1;
                    end
                end

                if (dcache_word[c])
                    read_hold[c] <= sdram_read_data;

                if (icache_word[c])
                    fetch_hold[c] <= sdram_read_data;

                if (mmu_walk_failed[c])
                    fetch_fault_hold[c] <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (any_store) begin
                        state <= S_IDLE;
                    end else if (next_found) begin
                        owner <= next_owner;
                        last_owner <= next_owner;

                        if (dcache_ready[next_owner]) begin
                            state <= S_DCACHE;
                        end else if (other_ready[next_owner] && mmu_data_request[next_owner]) begin
                            state <= S_WALK_DATA;
                        end else if (other_ready[next_owner] && is_sdram_atomic[next_owner]) begin
                            atomic_issued <= 1'b0;
                            state <= state_t'(cpu_atomic_op[next_owner] == ATOMIC_STORE_CONDITIONAL ? S_ATOMIC_WRITE : S_ATOMIC_READ);
                        end else if (icache_ready[next_owner]) begin
                            state <= S_ICACHE;
                        end else if (mmu_fetch_request[next_owner]) begin
                            state <= S_WALK_FETCH;
                        end else begin
                            flash_req <= 1'b1;
                            flash_addr <= {next_owner_address[23:2], 2'b00};
                            state <= S_FLASH_WAIT;
                        end
                    end
                end

                S_DCACHE: begin
                    if (dcache_done[owner])
                        state <= S_IDLE;
                end

                S_ICACHE: begin
                    if (icache_done[owner])
                        state <= S_IDLE;
                end

                S_WALK_DATA, S_WALK_FETCH: begin
                    if (mmu_walk_done[owner])
                        state <= S_IDLE;
                end

                S_FLASH_WAIT: begin
                    if (flash_ready) begin
                        flash_read_reg <= flash_rdata;
                        state <= S_FLASH_DONE;
                    end
                end

                S_FLASH_DONE: begin
                    flash_read_active[owner] <= 1'b1;
                    state <= S_IDLE;
                end

                S_ATOMIC_READ: begin
                    if (sdram_start)
                        atomic_issued <= 1'b1;

                    if (atomic_issued && sdram_valid) begin
                        atomic_old <= sdram_read_data;
                        atomic_result <= sdram_read_data;

                        if (atomic_op == ATOMIC_LOAD_RESERVED) begin
                            reservation_valid[owner] <= 1'b1;
                            reservation_address[owner] <= atomic_address;
                            state <= S_ATOMIC_DONE;
                        end else begin
                            state <= S_ATOMIC_WRITE;
                        end
                    end
                end

                S_ATOMIC_WRITE: begin
                    if (atomic_op == ATOMIC_STORE_CONDITIONAL) begin
                        atomic_result <= atomic_success ? 32'd0 : 32'd1;
                        reservation_valid[owner] <= 1'b0;
                    end

                    state <= S_ATOMIC_DONE;
                end

                S_ATOMIC_DONE: begin
                    atomic_active[owner] <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    always_comb begin
        store_accept = '0;
        store_core = '0;
        bram_conflict = '0;
        bram_core = '0;

        for (int c = 0; c < CORES; c++) begin
            store_blocked[c] = 1'b0;

            if (is_sdram_store[c] && state != S_IDLE)
                store_blocked[c] = 1'b1;

            for (int other = 0; other < c; other++) begin
                if (is_sdram_store[c] && is_sdram_store[other])
                    store_blocked[c] = 1'b1;

                if (is_bram_data[c] && is_bram_data[other])
                    bram_conflict[c] = 1'b1;
            end
        end

        for (int c = 0; c < CORES; c++) begin
            if (icache_clearing[c] || dcache_clearing[c])
                cpu_stall[c] = 1'b1;
            else if ((state == S_FLASH_DONE || state == S_ATOMIC_DONE) && owner == c)
                cpu_stall[c] = 1'b0;
            else if (state != S_IDLE && owner == c)
                cpu_stall[c] = 1'b1;
            else
                cpu_stall[c] = icache_fill_request[c] || dcache_fill_request[c] || mmu_data_request[c] || mmu_fetch_request[c] || is_flash_data[c] ||
                    is_sdram_atomic[c] || (is_sdram_store[c] && (buffer_full || mmu_data_denied[c])) || store_conflict[c] || store_blocked[c] ||
                    bram_conflict[c] || io_conflict[c] || (cpu_fence[c] && store_check && store_owner[c]);
        end

        for (int c = CORES - 1; c >= 0; c--) begin
            if (is_sdram_store[c]) begin
                store_accept[c] = !cpu_stall[c];
                store_core = c[OWNER_BITS - 1:0];
            end

            if (is_bram_data[c] && !bram_conflict[c])
                bram_core = c[OWNER_BITS - 1:0];
        end

        bram_addr = cpu_mem_addr[bram_core];
        bram_write = cpu_mem_write[bram_core];
        bram_fetch_addr = cpu_fetch_addr[0];
        bram_we = 4'b0000;

        if (is_bram_data[bram_core] && !cpu_stall[bram_core])
            bram_we = cpu_mem_we[bram_core];

        for (int c = 0; c < CORES; c++) begin
            if (dcache_lookup[c])
                read_data[c] = dcache_read[c];
            else if (flash_read_active[c])
                read_data[c] = flash_read_reg;
            else if (atomic_active[c])
                read_data[c] = atomic_result;
            else
                read_data[c] = bram_read;

            fetch_data[c] = icache_lookup[c] ? icache_read[c] : (c == 0 ? bram_fetch_read : 32'b0);
            cpu_fetch_read[c] = fetch_held[c] ? fetch_hold[c] : fetch_data[c];

            if (!read_held[c] && !dcache_lookup[c] && !flash_read_active[c] && !atomic_active[c])
                cpu_mem_read[c] = bram_read;
            else if (read_held[c])
                cpu_mem_read[c] = read_hold[c];
            else
                cpu_mem_read[c] = read_data[c];
        end
    end
endmodule
