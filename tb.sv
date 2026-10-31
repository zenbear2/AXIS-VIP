`timescale 1ns / 1ps

module tb;

    // Parameters
    localparam DATA_WIDTH = 32;
    localparam KEEP_WIDTH = DATA_WIDTH / 8;
    localparam DEPTH      = 4;
    localparam CLK_PERIOD = 10; // 100 MHz

    // Clock and Reset
    logic clk;
    logic rst_n;

    // Interface instances
    axis_if #(.DATA_WIDTH(DATA_WIDTH)) s_axis (.aclk(clk), .aresetn(rst_n));
    axis_if #(.DATA_WIDTH(DATA_WIDTH)) m_axis (.aclk(clk), .aresetn(rst_n));

    // Device Under Test (DUT)
    axis_fifo #(
        .DEPTH(DEPTH)
    ) dut (
        .s_axis(s_axis),
        .m_axis(m_axis)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Test Variables & Queues for Scoreboarding
    typedef struct {
        logic [DATA_WIDTH-1:0] data;
        logic [KEEP_WIDTH-1:0] keep;
        logic                  last;
    } axis_packet_t;

    axis_packet_t exp_queue[$];
    int err_count = 0;
    int received_count = 0;
    bit test_done = 0;

    // Monitor & Checker Process (runs concurrently)
    initial begin
        forever begin
            @(posedge clk);
            if (rst_n && m_axis.tvalid && m_axis.tready) begin
                axis_packet_t exp;
                if (exp_queue.size() == 0) begin
                    $error("[TIME %0t] ERROR: Unexpected data received on m_axis: data=0x%08x, last=%b",
                           $time, m_axis.tdata, m_axis.tlast);
                    err_count++;
                end else begin
                    exp = exp_queue.pop_front();
                    received_count++;
                    if (m_axis.tdata !== exp.data || m_axis.tkeep !== exp.keep || m_axis.tlast !== exp.last) begin
                        $error("[TIME %0t] MISMATCH at item %0d! Exp: data=0x%08x keep=0x%x last=%b | Got: data=0x%08x keep=0x%x last=%b",
                               $time, received_count, exp.data, exp.keep, exp.last, m_axis.tdata, m_axis.tkeep, m_axis.tlast);
                        err_count++;
                    end else begin
                        $display("[TIME %0t] [MATCH #%0d] data=0x%08h keep=0x%x last=%b",
                                 $time, received_count, m_axis.tdata, m_axis.tkeep, m_axis.tlast);
                    end
                end
            end
        end
    end

    // Master (s_axis) Driver Task: send one transaction
    task automatic send_word(
        input logic [DATA_WIDTH-1:0] data,
        input logic [KEEP_WIDTH-1:0] keep = '1,
        input logic                  last = 1'b0
    );
        axis_packet_t pkt;
        pkt.data = data;
        pkt.keep = keep;
        pkt.last = last;
        exp_queue.push_back(pkt);

        @(posedge clk);
        s_axis.tdata  <= data;
        s_axis.tkeep  <= keep;
        s_axis.tlast  <= last;
        s_axis.tvalid <= 1'b1;

        // Wait until slave accepts (tready == 1)
        do begin
            @(posedge clk);
        end while (!s_axis.tready);

        s_axis.tvalid <= 1'b0;
        s_axis.tdata  <= 'x;
        s_axis.tkeep  <= 'x;
        s_axis.tlast  <= 'x;
    endtask

    // Main Test Stimulus
    initial begin
        // Waveform dump
        $dumpfile("axis_fifo_tb.vcd");
        $dumpvars(0, tb);

        // Initialize signals
        rst_n         = 1'b0;
        s_axis.tvalid = 1'b0;
        s_axis.tdata  = '0;
        s_axis.tkeep  = '0;
        s_axis.tlast  = 1'b0;
        m_axis.tready = 1'b0;

        $display("==================================================");
        $display("          Starting AXIS FIFO Testbench            ");
        $display("==================================================");

        // Reset Sequence
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        $display("[TIME %0t] Reset released.", $time);

        //-------------------------------------------------------------
        // Test 1: Single write and read
        //-------------------------------------------------------------
        $display("\n--- Test 1: Single Word Transfer ---");
        m_axis.tready = 1'b1;
        send_word(32'hA001_0001, 4'hF, 1'b1);
        repeat (3) @(posedge clk);

        //-------------------------------------------------------------
        // Test 2: Fill FIFO up to DEPTH (4 entries) without read, then drain
        //-------------------------------------------------------------
        $display("\n--- Test 2: Fill to Full, then Drain ---");
        m_axis.tready = 1'b0; // Stop reading to allow FIFO to fill
        for (int i = 0; i < DEPTH; i++) begin
            send_word(32'hB000_0000 + i, 4'hF, (i == DEPTH-1));
        end

        // Wait a cycle, verify FIFO is full (s_axis.tready should be 0)
        @(posedge clk);
        if (s_axis.tready !== 1'b0) begin
            $error("[TIME %0t] FIFO should be FULL but s_axis.tready is %b!", $time, s_axis.tready);
            err_count++;
        end else begin
            $display("[TIME %0t] FIFO is correctly FULL (s_axis.tready = 0)", $time);
        end

        // Now drain the FIFO
        $display("[TIME %0t] Asserting m_axis.tready to drain FIFO...", $time);
        m_axis.tready = 1'b1;
        repeat (DEPTH + 2) @(posedge clk);

        //-------------------------------------------------------------
        // Test 3: Continuous back-to-back streaming (push & pop together)
        //-------------------------------------------------------------
        $display("\n--- Test 3: Continuous Back-to-Back Streaming ---");
        m_axis.tready = 1'b1;
        fork
            begin
                // Producer: send 8 words back-to-back
                for (int i = 0; i < 8; i++) begin
                    send_word(32'hC000_0000 + i, 4'hF, (i == 7));
                end
            end
        join

        repeat (5) @(posedge clk);

        //-------------------------------------------------------------
        // Test 4: Random backpressure on m_axis.tready
        //-------------------------------------------------------------
        $display("\n--- Test 4: Random Backpressure Test ---");
        fork
            // Producer
            begin
                for (int i = 0; i < 12; i++) begin
                    send_word(32'hD000_0000 + i, 4'hF, (i == 11));
                    if ($urandom_range(0, 1)) repeat ($urandom_range(1, 2)) @(posedge clk);
                end
            end
            // Consumer with intermittent ready
            begin
                for (int k = 0; k < 25; k++) begin
                    m_axis.tready <= $urandom_range(0, 1);
                    @(posedge clk);
                end
                m_axis.tready <= 1'b1;
            end
        join

        // Drain remaining
        m_axis.tready <= 1'b1;
        repeat (10) @(posedge clk);

        // Wait until expected queue is empty
        wait (exp_queue.size() == 0);
        repeat (5) @(posedge clk);

        //-------------------------------------------------------------
        // Final Results Summary
        //-------------------------------------------------------------
        $display("\n==================================================");
        $display("               Simulation Summary                 ");
        $display("==================================================");
        $display("Total packets received : %0d", received_count);
        $display("Total errors detected  : %0d", err_count);
        if (err_count == 0 && received_count > 0) begin
            $display(">>> TEST STATUS: PASSED! ALL CHECKS SUCCESSFUL <<<");
        end else begin
            $display(">>> TEST STATUS: FAILED! <<<");
        end
        $display("==================================================\n");

        test_done = 1;
        $finish;
    end

    // Timeout watchdog (prevents infinite loop if deadlocked)
    initial begin
        #100000; // 100 us timeout
        if (!test_done) begin
            $error("\n[TIMEOUT] Simulation timed out after 100us!");
            $finish;
        end
    end

endmodule

