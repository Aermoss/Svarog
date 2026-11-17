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

module system #(
    parameter bit SIMULATION = 1'b0,
    parameter int CLK_FREQ = 54000000,
    parameter int CORES = 2
) (
    input logic clk,
    input logic rst,

    input logic uart_rx,
    output logic uart_tx,

    output logic sd_clk,
    output logic sd_mosi,
    input logic sd_miso,
    output logic sd_cs_n,

    input logic button,
    output logic [5:0] leds,
    output logic ws2812,

    output logic video_write,
    output logic [11:0] video_address,
    output logic [15:0] video_data,
    output logic [15:0] video_cursor,
    output logic [4:0] video_scroll,

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
    input logic [31:0] sdram_read_data
);
    logic [CORES - 1:0] core_rst;
    logic [CORES - 1:0] core_running;
    logic [31:0] core_entry;

    logic [CORES - 1:0][31:0] cpu_fetch_addr;
    logic [CORES - 1:0][31:0] cpu_fetch_next;
    logic [CORES - 1:0][31:0] cpu_fetch_current;
    logic [CORES - 1:0] cpu_fetch_repeat;
    logic [CORES - 1:0][31:0] cpu_fetch_read;
    logic [CORES - 1:0] cpu_fetch_fault;
    logic [CORES - 1:0] cpu_mem_access;
    logic [CORES - 1:0] cpu_atomic;
    logic [CORES - 1:0][3:0] cpu_atomic_op;
    logic [CORES - 1:0] cpu_write_access;
    logic [CORES - 1:0] cpu_fence;
    logic [CORES - 1:0] cpu_reservation_clear;
    logic [CORES - 1:0] cpu_icache_flush;
    logic [CORES - 1:0][3:0] cpu_mem_we;
    logic [CORES - 1:0][3:0] cpu_io_we;
    logic [CORES - 1:0][31:0] cpu_mem_addr;
    logic [CORES - 1:0][31:0] cpu_ex_addr;
    logic [CORES - 1:0][31:0] cpu_mem_write;
    logic [CORES - 1:0][31:0] cpu_mem_read;
    logic [CORES - 1:0] cpu_stall;
    logic [CORES - 1:0] cpu_data_fault;
    logic [CORES - 1:0] cpu_user_mode;
    logic [CORES - 1:0][31:0] cpu_ptbase;
    logic [CORES - 1:0][3:0] cpu_asid;
    logic [CORES - 1:0] cpu_tlb_flush;
    logic [CORES - 1:0] cpu_cache_flush;
    logic [CORES - 1:0][31:0] cpu_instret;

    logic [CORES - 1:0][31:0] io_read_word;
    logic [CORES - 1:0] io_read_hit;
    logic [CORES - 1:0] io_conflict;
    logic [CORES - 1:0][2:0] io_interrupts;
    logic [31:0] cycle_counter;
    logic [31:0] ms_counter;

    io #(
        .SIMULATION(SIMULATION),
        .CLK_FREQ(CLK_FREQ),
        .CORES(CORES)
    ) io0 (
        .clk(clk),
        .rst(rst),

        .address(cpu_mem_addr),
        .access(cpu_mem_access),
        .write_enable(cpu_io_we),
        .write_data(cpu_mem_write),
        .stall(cpu_stall),
        .instret(cpu_instret),
        .read_word(io_read_word),
        .read_hit(io_read_hit),
        .conflict(io_conflict),

        .interrupts(io_interrupts),
        .cycle_counter(cycle_counter),
        .ms_counter(ms_counter),
        .core_running(core_running),
        .core_entry(core_entry),

        .uart_rx(uart_rx),
        .uart_tx(uart_tx),

        .sd_clk(sd_clk),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n),

        .button(button),
        .leds(leds),
        .ws2812(ws2812),

        .video_write(video_write),
        .video_address(video_address),
        .video_data(video_data),
        .video_cursor(video_cursor),
        .video_scroll(video_scroll)
    );

    logic store_check;
    logic [CORES - 1:0] store_owner;
    logic [20:0] store_address;
    logic [31:0] store_data;
    logic [3:0] store_dqm;
    logic [20:0] store_push_address;

    logic [CORES - 1:0] icache_request;
    logic [CORES - 1:0][10:0] icache_tag;
    logic [CORES - 1:0] icache_lookup;
    logic [CORES - 1:0][31:0] icache_read;
    logic [CORES - 1:0] icache_fill_request;
    logic [CORES - 1:0] icache_clearing;
    logic [CORES - 1:0] icache_grant;
    logic [CORES - 1:0] icache_start;
    logic [CORES - 1:0][20:0] icache_address;
    logic [CORES - 1:0] icache_word;
    logic [CORES - 1:0] icache_done;

    logic [CORES - 1:0] dcache_request;
    logic [CORES - 1:0][10:0] dcache_tag;
    logic [CORES - 1:0] dcache_lookup;
    logic [CORES - 1:0][31:0] dcache_read;
    logic [CORES - 1:0] dcache_fill_request;
    logic [CORES - 1:0] dcache_clearing;
    logic [CORES - 1:0] dcache_grant;
    logic [CORES - 1:0] dcache_start;
    logic [CORES - 1:0][20:0] dcache_address;
    logic [CORES - 1:0] dcache_word;
    logic [CORES - 1:0] dcache_done;

    logic [CORES - 1:0][10:0] mmu_fetch_frame;
    logic [CORES - 1:0] mmu_fetch_translated;
    logic [CORES - 1:0] mmu_fetch_fault;
    logic [CORES - 1:0] mmu_fetch_request;
    logic [CORES - 1:0][10:0] mmu_data_frame;
    logic [CORES - 1:0] mmu_data_request;
    logic [CORES - 1:0] mmu_data_denied;
    logic [CORES - 1:0] mmu_grant_data;
    logic [CORES - 1:0] mmu_grant_fetch;
    logic [CORES - 1:0] mmu_start;
    logic [CORES - 1:0][20:0] mmu_address;
    logic [CORES - 1:0] mmu_walk_done;
    logic [CORES - 1:0] mmu_walk_resolved;
    logic [CORES - 1:0] mmu_walk_failed;
    logic [CORES - 1:0][10:0] mmu_walk_frame;

    genvar c;

    generate
        for (c = 0; c < CORES; c++) begin : core
            assign core_rst[c] = rst || !core_running[c];

            cpu #(
                .SIMULATION(SIMULATION),
                .CORE_ID(c)
            ) cpu0 (
                .clk(clk),
                .rst(core_rst[c]),
                .reset_vector(c == 0 ? 32'b0 : core_entry),

                .io_read_word(io_read_word[c]),
                .io_read_hit(io_read_hit[c]),
                .io_write_enable(cpu_io_we[c]),
                .instret(cpu_instret[c]),
                .interrupt_lines(io_interrupts[c]),
                .cycle_counter(cycle_counter),
                .ms_counter(ms_counter),

                .fetch_addr(cpu_fetch_addr[c]),
                .fetch_next(cpu_fetch_next[c]),
                .fetch_current(cpu_fetch_current[c]),
                .fetch_repeat(cpu_fetch_repeat[c]),
                .fetch_read(cpu_fetch_read[c]),
                .fetch_fault(cpu_fetch_fault[c]),

                .mem_access(cpu_mem_access[c]),
                .mem_atomic(cpu_atomic[c]),
                .mem_atomic_op(cpu_atomic_op[c]),
                .mem_write_access(cpu_write_access[c]),
                .mem_fence(cpu_fence[c]),
                .reservation_clear(cpu_reservation_clear[c]),
                .icache_flush(cpu_icache_flush[c]),
                .actual_mem_we(cpu_mem_we[c]),
                .mem_addr(cpu_mem_addr[c]),
                .ex_addr(cpu_ex_addr[c]),
                .mem_write(cpu_mem_write[c]),
                .mem_read(cpu_mem_read[c]),
                .data_fault(cpu_data_fault[c]),

                .user_mode(cpu_user_mode[c]),
                .csr_ptbase(cpu_ptbase[c]),
                .csr_asid(cpu_asid[c]),
                .tlb_flush(cpu_tlb_flush[c]),
                .cache_flush(cpu_cache_flush[c]),

                .fetch_wait(mmu_fetch_request[c] || icache_fill_request[c]),
                .bus_stall(cpu_stall[c])
            );

            mmu mmu0 (
                .clk(clk),
                .rst(core_rst[c]),
                .stall(cpu_stall[c]),

                .user_mode(cpu_user_mode[c]),
                .ptbase(cpu_ptbase[c]),
                .asid(cpu_asid[c]),
                .flush(cpu_tlb_flush[c]),

                .fetch_address(cpu_fetch_addr[c]),
                .fetch_next(cpu_fetch_next[c]),
                .fetch_current(cpu_fetch_current[c]),
                .fetch_repeat(cpu_fetch_repeat[c]),
                .fetch_lookup(icache_lookup[c]),
                .fetch_frame(mmu_fetch_frame[c]),
                .fetch_translated(mmu_fetch_translated[c]),
                .fetch_fault(mmu_fetch_fault[c]),
                .fetch_request(mmu_fetch_request[c]),

                .ex_address(cpu_ex_addr[c]),
                .data_address(cpu_mem_addr[c]),
                .data_access(cpu_mem_access[c]),
                .data_write(cpu_write_access[c]),
                .data_frame(mmu_data_frame[c]),
                .data_request(mmu_data_request[c]),
                .data_denied(mmu_data_denied[c]),
                .data_fault(cpu_data_fault[c]),

                .grant_data(mmu_grant_data[c]),
                .grant_fetch(mmu_grant_fetch[c]),
                .sdram_ready(sdram_ready),
                .sdram_valid(sdram_valid),
                .sdram_data(sdram_read_data),
                .sdram_start(mmu_start[c]),
                .sdram_address(mmu_address[c]),
                .walk_done(mmu_walk_done[c]),
                .walk_resolved(mmu_walk_resolved[c]),
                .walk_failed(mmu_walk_failed[c]),
                .walk_frame(mmu_walk_frame[c])
            );

            icache icache0 (
                .clk(clk),
                .rst(core_rst[c]),

                .capture(!cpu_stall[c]),
                .request(icache_request[c]),
                .address(cpu_fetch_addr[c]),
                .tag(icache_tag[c]),
                .translated(mmu_fetch_translated[c]),
                .lookup(icache_lookup[c]),
                .read_data(icache_read[c]),
                .fill_request(icache_fill_request[c]),
                .clearing(icache_clearing[c]),

                .flush((cpu_tlb_flush[c] && cpu_cache_flush[c]) || cpu_icache_flush[c]),
                .invalidate(1'b0),
                .invalidate_address(store_address),
                .retag(mmu_walk_resolved[c]),
                .new_tag(mmu_walk_frame[c]),

                .grant(icache_grant[c]),
                .sdram_ready(sdram_ready),
                .sdram_valid(sdram_valid),
                .sdram_data(sdram_read_data),
                .sdram_start(icache_start[c]),
                .sdram_address(icache_address[c]),
                .word_valid(icache_word[c]),
                .fill_done(icache_done[c])
            );

            dcache dcache0 (
                .clk(clk),
                .rst(core_rst[c]),

                .capture(!cpu_stall[c]),
                .request(dcache_request[c]),
                .address(cpu_mem_addr[c]),
                .tag(dcache_tag[c]),
                .lookup(dcache_lookup[c]),
                .read_data(dcache_read[c]),
                .fill_request(dcache_fill_request[c]),
                .clearing(dcache_clearing[c]),

                .flush(cpu_tlb_flush[c] && cpu_cache_flush[c]),
                .invalidate(store_check && !store_owner[c]),
                .snoop_address(store_push_address),
                .store(store_check && store_owner[c]),
                .store_address(store_address),
                .store_data(store_data),
                .store_dqm(store_dqm),

                .grant(dcache_grant[c]),
                .sdram_ready(sdram_ready),
                .sdram_valid(sdram_valid),
                .sdram_data(sdram_read_data),
                .sdram_start(dcache_start[c]),
                .sdram_address(dcache_address[c]),
                .word_valid(dcache_word[c]),
                .fill_done(dcache_done[c])
            );
        end
    endgenerate

    logic [3:0] bram_we;
    logic [31:0] bram_addr;
    logic [31:0] bram_write;
    logic [31:0] bram_read;
    logic [31:0] bram_fetch_addr;
    logic [31:0] bram_fetch_read;

    bram bram0 (
        .clk(clk),
        .we(bram_we),
        .addr(bram_addr),
        .write(bram_write),
        .read(bram_read),
        .fetch_addr(bram_fetch_addr),
        .fetch_read(bram_fetch_read)
    );

    bus #(
        .CORES(CORES)
    ) bus0 (
        .clk(clk),
        .rst(rst),

        .cpu_fetch_addr(cpu_fetch_addr),
        .cpu_fetch_read(cpu_fetch_read),
        .cpu_fetch_fault(cpu_fetch_fault),

        .cpu_mem_access(cpu_mem_access),
        .cpu_atomic(cpu_atomic),
        .cpu_atomic_op(cpu_atomic_op),
        .cpu_fence(cpu_fence),
        .cpu_reservation_clear(cpu_reservation_clear),
        .cpu_mem_we(cpu_mem_we),
        .cpu_mem_addr(cpu_mem_addr),
        .cpu_mem_write(cpu_mem_write),
        .cpu_mem_read(cpu_mem_read),
        .cpu_stall(cpu_stall),

        .cpu_user_mode(cpu_user_mode),
        .io_conflict(io_conflict),

        .bram_we(bram_we),
        .bram_addr(bram_addr),
        .bram_write(bram_write),
        .bram_read(bram_read),
        .bram_fetch_addr(bram_fetch_addr),
        .bram_fetch_read(bram_fetch_read),

        .flash_req(flash_req),
        .flash_addr(flash_addr),
        .flash_rdata(flash_rdata),
        .flash_ready(flash_ready),

        .sdram_start(sdram_start),
        .sdram_write(sdram_write),
        .sdram_length(sdram_length),
        .sdram_address(sdram_address),
        .sdram_data(sdram_data),
        .sdram_dqm(sdram_dqm),
        .sdram_ready(sdram_ready),
        .sdram_valid(sdram_valid),
        .sdram_read_data(sdram_read_data),

        .store_check(store_check),
        .store_owner(store_owner),
        .store_address(store_address),
        .store_data(store_data),
        .store_dqm(store_dqm),
        .store_push_address(store_push_address),

        .icache_request(icache_request),
        .icache_tag(icache_tag),
        .icache_lookup(icache_lookup),
        .icache_read(icache_read),
        .icache_fill_request(icache_fill_request),
        .icache_clearing(icache_clearing),
        .icache_grant(icache_grant),
        .icache_start(icache_start),
        .icache_address(icache_address),
        .icache_word(icache_word),
        .icache_done(icache_done),

        .dcache_request(dcache_request),
        .dcache_tag(dcache_tag),
        .dcache_lookup(dcache_lookup),
        .dcache_read(dcache_read),
        .dcache_fill_request(dcache_fill_request),
        .dcache_clearing(dcache_clearing),
        .dcache_grant(dcache_grant),
        .dcache_start(dcache_start),
        .dcache_address(dcache_address),
        .dcache_word(dcache_word),
        .dcache_done(dcache_done),

        .mmu_fetch_frame(mmu_fetch_frame),
        .mmu_fetch_fault(mmu_fetch_fault),
        .mmu_fetch_request(mmu_fetch_request),
        .mmu_data_frame(mmu_data_frame),
        .mmu_data_request(mmu_data_request),
        .mmu_data_denied(mmu_data_denied),
        .mmu_grant_data(mmu_grant_data),
        .mmu_grant_fetch(mmu_grant_fetch),
        .mmu_start(mmu_start),
        .mmu_address(mmu_address),
        .mmu_walk_done(mmu_walk_done),
        .mmu_walk_failed(mmu_walk_failed)
    );
endmodule
