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

`timescale 1ns / 1ps

module SDCard (
    input logic sck,
    input logic cs_n,
    input logic mosi,
    output wire miso
);
    localparam int QUEUE = 2048;
    localparam int OVERLAY = 4096;
    localparam int STATE_COMMAND = 0;
    localparam int STATE_READING = 1;
    localparam int STATE_WAITING = 2;
    localparam int STATE_RECEIVING = 3;

    real output_valid = 10.0;

    int file = 0;
    int sectors = 0;
    logic idle = 1'b1;
    logic application = 1'b0;
    int polls = 0;
    int state = STATE_COMMAND;
    logic multiple = 1'b0;
    int address = 0;

    logic [7:0] command [0:5];
    int command_length = 0;
    logic [7:0] queue [0:QUEUE - 1];
    int head = 0;
    int tail = 0;
    logic [7:0] block [0:513];
    int block_length = 0;
    logic [7:0] sector [0:511];

    logic [7:0] overlay [0:OVERLAY * 512 - 1];
    int overlay_tag [0:OVERLAY - 1];
    int overlay_used = 0;

    logic [7:0] incoming = 8'd0;
    logic [7:0] outgoing = 8'hFF;
    int bit_count = 0;
    int out_bits = 8;
    logic send_bit = 1'b1;
    logic miso_value = 1'b1;
    logic miso_enable = 1'b0;
    int blocks_read = 0;
    int blocks_written = 0;
    logic log_commands = 1'b0;

    initial begin
        string path;
        log_commands = $test$plusargs("sd_log");

        if ($value$plusargs("sd=%s", path)) begin
            file = $fopen(path, "rb");

            if (file == 0) begin
                $display("SD: cannot open %s, no card inserted", path);
            end else begin
                void'($fseek(file, 0, 2));
                sectors = $ftell(file) / 512;
                $display("SD: %s, %0d sectors (%0d MB); writes stay in memory", path, sectors, sectors / 2048);
            end
        end
    end

    task automatic Report();
        $display("SD: %0d blocks read, %0d blocks written", blocks_read, blocks_written);
    endtask

    function automatic logic Present();
        return file != 0 && sectors > 0;
    endfunction

    task automatic Push(input logic [7:0] value);
        if ((tail + 1) % QUEUE == head) begin
            $display("SD: response queue overflow");
        end else begin
            queue[tail] = value;
            tail = (tail + 1) % QUEUE;
        end
    endtask

    task automatic PushWord(input logic [31:0] value);
        Push(value[31:24]);
        Push(value[23:16]);
        Push(value[15:8]);
        Push(value[7:0]);
    endtask

    function automatic logic Empty();
        return head == tail;
    endfunction

    task automatic Clear();
        head = 0;
        tail = 0;
    endtask

    function automatic logic [7:0] Status();
        return idle ? 8'h01 : 8'h00;
    endfunction

    function automatic int Find(input int number);
        for (int i = 0; i < overlay_used; i++) if (overlay_tag[i] == number) return i;
        return -1;
    endfunction

    task automatic ReadSector(input int number, output logic ok);
        int slot;
        int count;
        slot = Find(number);

        if (slot >= 0) begin
            for (int i = 0; i < 512; i++) sector[i] = overlay[slot * 512 + i];
            ok = 1'b1;
        end else begin
            void'($fseek(file, number * 512, 0));
            count = $fread(sector, file, 0, 512);
            ok = count == 512;
        end
    endtask

    task automatic WriteSector(input int number, output logic ok);
        int slot;
        slot = Find(number);

        if (slot < 0 && overlay_used < OVERLAY) begin
            slot = overlay_used;
            overlay_tag[slot] = number;
            overlay_used++;
        end

        ok = slot >= 0;
        if (!ok) $display("SD: write overlay is full");
        if (ok) for (int i = 0; i < 512; i++) overlay[slot * 512 + i] = block[i];
    endtask

    task automatic QueueBlock();
        logic ok;

        if (address >= sectors) begin
            Push(8'h08);
            state = STATE_COMMAND;
            return;
        end

        ReadSector(address, ok);

        if (!ok) begin
            Push(8'h08);
            state = STATE_COMMAND;
            return;
        end

        Push(8'hFF);
        Push(8'hFE);
        for (int i = 0; i < 512; i++) Push(sector[i]);
        Push(8'hFF);
        Push(8'hFF);
        address++;
        blocks_read++;
    endtask

    task automatic QueueRegister();
        logic [31:0] size;
        size = sectors / 1024 - 1;
        Push(8'h00);
        Push(8'hFF);
        Push(8'hFE);
        PushWord(32'h400E0032);
        PushWord(32'h5B590000 | ((size >> 16) & 32'h3F));
        PushWord(((size & 32'hFFFF) << 16) | 32'h7F80);
        PushWord(32'h0A400001);
        Push(8'hFF);
        Push(8'hFF);
    endtask

    task automatic Execute();
        logic [5:0] index;
        logic [31:0] argument;
        logic was_application;

        index = command[0][5:0];
        argument = {command[1], command[2], command[3], command[4]};
        was_application = application;
        application = 1'b0;
        command_length = 0;
        Push(8'hFF);
        if (log_commands) $display("SD: %0.1f us %sCMD%0d %08h", $realtime / 1000.0, was_application ? "A" : "", index, argument);

        if (was_application && index == 6'd41) begin
            polls++;
            if (polls >= 3) idle = 1'b0;
            Push(Status());
            return;
        end

        case (index)
            6'd0: begin
                idle = 1'b1;
                polls = 0;
                Push(8'h01);
            end
            6'd8: begin
                Push(Status());
                PushWord(argument & 32'hFFF);
            end
            6'd55: begin
                application = 1'b1;
                Push(Status());
            end
            6'd58: begin
                Push(Status());
                PushWord(idle ? 32'h00FF8000 : 32'hC0FF8000);
            end
            6'd9: QueueRegister();
            6'd12: begin
                state = STATE_COMMAND;
                Clear();
                Push(8'hFF);
                Push(8'h00);
                Push(8'h00);
            end
            6'd13: begin
                Push(Status());
                Push(8'h00);
            end
            6'd16: Push(Status());
            6'd17, 6'd18: begin
                if (idle) begin
                    Push(8'h05);
                end else if (argument >= sectors) begin
                    Push(8'h20);
                end else begin
                    Push(8'h00);
                    address = argument;
                    multiple = index == 6'd18;
                    QueueBlock();
                    state = multiple ? STATE_READING : STATE_COMMAND;
                end
            end
            6'd24, 6'd25: begin
                if (idle) begin
                    Push(8'h05);
                end else if (argument >= sectors) begin
                    Push(8'h20);
                end else begin
                    Push(8'h00);
                    address = argument;
                    multiple = index == 6'd25;
                    state = STATE_WAITING;
                end
            end
            default: Push(Status() | 8'h04);
        endcase
    endtask

    task automatic ReceiveBlockByte(input logic [7:0] value);
        logic written;
        block[block_length] = value;
        block_length++;
        if (block_length < 514) return;
        block_length = 0;
        written = 1'b0;
        if (address < sectors) WriteSector(address, written);
        if (written) blocks_written++;
        address++;
        Push(written ? 8'hE5 : 8'hED);
        Push(8'h00);
        Push(8'h00);
        state = multiple && written ? STATE_WAITING : STATE_COMMAND;
    endtask

    task automatic Receive(input logic [7:0] value);
        if (state == STATE_WAITING) begin
            if (value == 8'hFE || (value == 8'hFC && multiple)) begin
                state = STATE_RECEIVING;
                block_length = 0;
            end else if (value == 8'hFD && multiple) begin
                state = STATE_COMMAND;
                Push(8'hFF);
                Push(8'h00);
                Push(8'h00);
            end

            return;
        end

        if (state == STATE_RECEIVING) begin
            ReceiveBlockByte(value);
            return;
        end

        if (state == STATE_READING && Empty()) QueueBlock();
        if (command_length == 0 && value[7:6] != 2'b01) return;
        command[command_length] = value;
        command_length++;
        if (command_length == 6) Execute();
    endtask

    function automatic logic [7:0] Next();
        logic [7:0] value;
        value = 8'hFF;

        if (!Empty()) begin
            value = queue[head];
            head = (head + 1) % QUEUE;
        end

        return value;
    endfunction

    assign miso = miso_enable ? miso_value : 1'bz;

    always @(negedge cs_n) begin
        bit_count = 0;

        if (Present()) begin
            outgoing = Next();
            out_bits = 1;
            send_bit = outgoing[7];
            miso_value <= #(output_valid) send_bit;
            miso_enable <= #(output_valid) 1'b1;
        end
    end

    always @(posedge cs_n) begin
        if (state != STATE_READING) command_length = 0;
        miso_enable <= #(output_valid) 1'b0;
    end

    always @(posedge sck) begin
        if (!cs_n && Present()) begin
            incoming = {incoming[6:0], mosi};
            bit_count++;

            if (bit_count == 8) begin
                bit_count = 0;
                Receive(incoming);
            end
        end
    end

    always @(negedge sck) begin
        if (!cs_n && Present()) begin
            if (out_bits == 8) begin
                if (bit_count == 0) begin
                    outgoing = Next();
                    out_bits = 1;
                    send_bit = outgoing[7];
                    miso_value <= #(output_valid) send_bit;
                end
            end else begin
                send_bit = outgoing[7 - out_bits];
                miso_value <= #(output_valid) send_bit;
                out_bits++;
            end
        end
    end
endmodule
