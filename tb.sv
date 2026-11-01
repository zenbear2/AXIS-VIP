`timescale 1ns / 1ps

import axis_vip_pkg::*;

module tb;

    // Parameters
    localparam DATA_WIDTH = 32;
    localparam DEPTH      = 4;
    localparam CLK_PERIOD = 10; // 100 MHz
    localparam NUM_TRANS  = 32;

    // Clock and Reset
    logic clk;
    logic rst_n;
    bit   test_done = 0;

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

    // Main Test Stimulus using Pure SV VIP Environment
    axis_env env;

    initial begin
        // Waveform dump
        $dumpfile("axis_fifo_tb.vcd");
        $dumpvars(0, tb);

        // Initialize signals before reset release
        rst_n         = 1'b0;
        s_axis.tvalid = 1'b0;
        s_axis.tdata  = '0;
        s_axis.tkeep  = '0;
        s_axis.tlast  = 1'b0;
        m_axis.tready = 1'b0;

        $display("==================================================");
        $display("       Starting Pure SV AXIS VIP Testbench        ");
        $display("==================================================");

        // Build VIP Environment
        env = new(s_axis, m_axis, NUM_TRANS);

        // Reset Sequence
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        $display("[%0t] Reset released.", $time);

        // Run VIP Environment & wait until all transactions are drained
        env.run();
        repeat (3) @(posedge clk);

        // Final Summary
        $display("\n==================================================");
        $display("               Simulation Summary                 ");
        $display("==================================================");
        $display("Total transactions matched : %0d / %0d", env.scb.match_count, NUM_TRANS);
        $display("Total errors detected      : %0d", env.scb.err_count);
        $display("Master Functional Coverage : %0.2f%%", env.s_agt.cov.get_cov());
        $display("Slave  Functional Coverage : %0.2f%%", env.m_agt.cov.get_cov());
        if (env.scb.err_count == 0 && env.scb.match_count == NUM_TRANS) begin
            $display(">>> TEST STATUS: PASSED! ALL CHECKS SUCCESSFUL <<<");
        end else begin
            $display(">>> TEST STATUS: FAILED! <<<");
        end
        $display("==================================================\n");

        test_done = 1;
        $finish;
    end

    // Timeout Watchdog (避免 Handshake 死鎖永久等待，對應 3.2 節)
    initial begin
        #100000; // 100 us timeout
        if (!test_done) begin
            $error("\n[TIMEOUT] Simulation timed out after 100us!");
            $finish;
        end
    end

endmodule
