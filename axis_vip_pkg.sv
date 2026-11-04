`timescale 1ns / 1ps

package axis_vip_pkg;

    // =========================================================================
    // 1. Transaction: Packet payload fields, random constraints, and deep copy
    // =========================================================================
    class axis_transaction;
        rand logic [31:0] data;
        rand logic [3:0]  keep;
        rand logic        last;
        rand int          idle_cycles; // Sender idle cycles before driving transfer

        // Default protocol validity constraints
        constraint c_default {
            idle_cycles inside {[0:3]};
            keep inside {4'b1111, 4'b0111, 4'b0011, 4'b0001};
        }

        // Deep copy: Prevents object handle reuse corruption in Generator
        function axis_transaction copy();
            copy = new();
            copy.data        = this.data;
            copy.keep        = this.keep;
            copy.last        = this.last;
            copy.idle_cycles = this.idle_cycles;
        endfunction

        // Compare two transactions for equality
        function bit compare(axis_transaction rhs);
            return (this.data === rhs.data) &&
                   (this.keep === rhs.keep) &&
                   (this.last === rhs.last);
        endfunction

        function void print(string tag = "");
            $display("[%0t] [%s] data=0x%08h keep=0x%x last=%b (idle=%0d)",
                     $time, tag, data, keep, last, idle_cycles);
        endfunction
    endclass

    // =========================================================================
    // 2. Generator: Generates randomized transactions and puts copies into mailbox
    // =========================================================================
    class axis_generator;
        mailbox #(axis_transaction) gen2drv;
        int num_trans;

        function new(mailbox #(axis_transaction) gen2drv, int num_trans = 16);
            this.gen2drv   = gen2drv;
            this.num_trans = num_trans;
        endfunction

        task run();
            axis_transaction tr_template = new();
            for (int i = 0; i < num_trans; i++) begin
                // Inline constraint to assert TLAST every 4 beats and on the final beat
                if (!tr_template.randomize() with {
                    last == (i % 4 == 3 || i == num_trans - 1);
                }) begin
                    $fatal(1, "[GEN] Randomize failed!");
                end

                // Put a deep copy into the mailbox to avoid overwriting the same handle
                gen2drv.put(tr_template.copy());
            end
        endtask
    endclass

    // =========================================================================
    // 3. Master Driver: Retrieves transactions and drives bus via Master BFM
    // =========================================================================
    class axis_master_driver;
        virtual axis_if vif;
        mailbox #(axis_transaction) gen2drv;

        function new(virtual axis_if vif, mailbox #(axis_transaction) gen2drv);
            this.vif     = vif;
            this.gen2drv = gen2drv;
        endfunction

        task run();
            axis_transaction tr;
            vif.master_reset();
            forever begin
                gen2drv.get(tr);
                vif.master_send(tr.data, tr.keep, tr.last, tr.idle_cycles);
            end
        endtask
    endclass

    // =========================================================================
    // 4. Slave Driver: Generates random backpressure on TREADY via Slave BFM
    // =========================================================================
    class axis_slave_driver;
        virtual axis_if vif;

        function new(virtual axis_if vif);
            this.vif = vif;
        endfunction

        task run();
            vif.slave_reset();
            forever begin
                vif.slave_received(1'b1, $urandom_range(0, 2));
            end
        endtask
    endclass

    // =========================================================================
    // 5. Functional Coverage: Collects packet field and cross coverage
    // =========================================================================
    class axis_coverage;
        axis_transaction tr;
        int              beat_cnt = 0; // Tracks number of beats per packet
        int              pkt_len  = 0;

        // Covergroup checking TKEEP patterns, TLAST position, and their cross product
        covergroup cg_axis_pkt;
            option.per_instance = 1;

            // 1. Valid byte-enable (TKEEP) patterns
            cp_keep : coverpoint tr.keep {
                bins keep_1byte = {4'b0001};
                bins keep_2byte = {4'b0011};
                bins keep_3byte = {4'b0111};
                bins keep_4byte = {4'b1111};
                illegal_bins bad_keep = default;
            }

            // 2. Packet boundary indicator (TLAST)
            cp_last : coverpoint tr.last {
                bins mid_beat  = {1'b0};
                bins last_beat = {1'b1};
            }

            // 3. Cross coverage: Verify all TKEEP patterns occur on both mid and last beats
            cx_keep_last : cross cp_keep, cp_last;
        endgroup

        function new();
            cg_axis_pkt = new();
        endfunction

        // Sample method invoked by Monitor when a valid handshake occurs
        function void sample(axis_transaction t);
            this.tr = t;
            beat_cnt++;
            if (t.last) begin
                pkt_len  = beat_cnt;
                beat_cnt = 0;
            end
            cg_axis_pkt.sample();
        endfunction

        function real get_cov();
            return cg_axis_pkt.get_inst_coverage();
        endfunction
    endclass

    // =========================================================================
    // 6. Monitor: Samples completed handshakes via BFM, forwards to SCB & Coverage
    // =========================================================================
    class axis_monitor;
        string name;
        virtual axis_if vif;
        mailbox #(axis_transaction) mon2scb;
        axis_coverage cov; // Optional coverage collector (Observer pattern)

        function new(
            string                      name,
            virtual axis_if             vif,
            mailbox #(axis_transaction) mon2scb,
            axis_coverage               cov = null
        );
            this.name    = name;
            this.vif     = vif;
            this.mon2scb = mon2scb;
            this.cov     = cov;
        endfunction

        task run();
            forever begin
                axis_transaction tr = new();
                vif.monitor_sample(tr.data, tr.keep, tr.last);
                mon2scb.put(tr);
                // Trigger functional coverage sampling if attached
                if (cov != null) begin
                    cov.sample(tr);
                end
            end
        endtask
    endclass

    // =========================================================================
    // 7A. Scoreboard (Base Class - Mailbox Version): Uses non-blocking try_get()
    // =========================================================================
    class axis_scoreboard;
        mailbox #(axis_transaction) exp_mbx;
        mailbox #(axis_transaction) act_mbx;
        int match_count = 0;
        int err_count   = 0;

        function new(mailbox #(axis_transaction) exp_mbx, mailbox #(axis_transaction) act_mbx);
            this.exp_mbx = exp_mbx;
            this.act_mbx = act_mbx;
        endfunction

        // Virtual method supporting polymorphic override on mid-stream reset
        virtual function void reset_flush();
            axis_transaction tmp;
            while (exp_mbx.try_get(tmp));
        endfunction

        virtual task run();
            axis_transaction exp_tr, act_tr;
            forever begin
                act_mbx.get(act_tr);
                if (!exp_mbx.try_get(exp_tr)) begin
                    err_count++;
                    $error("[%0t] [SCB-MBX FAIL] Unexpected output! exp_mbx is empty, got data=0x%08h",
                           $time, act_tr.data);
                end else if (act_tr.compare(exp_tr)) begin
                    match_count++;
                    $display("[%0t] [SCB-MBX PASS #%0d] data=0x%08h keep=0x%x last=%b",
                             $time, match_count, act_tr.data, act_tr.keep, act_tr.last);
                end else begin
                    err_count++;
                    $error("[%0t] [SCB-MBX FAIL] Exp: data=0x%08h keep=0x%x last=%b | Act: data=0x%08h keep=0x%x last=%b",
                           $time, exp_tr.data, exp_tr.keep, exp_tr.last,
                           act_tr.data, act_tr.keep, act_tr.last);
                end
            end
        endtask
    endclass

    // =========================================================================
    // 7B. Scoreboard (Derived Queue Version): Uses SystemVerilog queue exp_q[$]
    // =========================================================================
    class axis_scoreboard_queue extends axis_scoreboard;
        axis_transaction exp_q[$];

        function new(mailbox #(axis_transaction) exp_mbx, mailbox #(axis_transaction) act_mbx);
            super.new(exp_mbx, act_mbx);
        endfunction

        // Override reset flush: Clear all pending expected items in a single call
        virtual function void reset_flush();
            exp_q.delete();
        endfunction

        // Override run(): Use push_back() and pop_front() on exp_q[$]
        virtual task run();
            fork
                // Thread 1: Collect expected transactions from input monitor into exp_q
                forever begin
                    axis_transaction exp_tr;
                    exp_mbx.get(exp_tr);
                    exp_q.push_back(exp_tr);
                end

                // Thread 2: Compare actual output transactions against front of exp_q
                forever begin
                    axis_transaction exp_tr, act_tr;
                    act_mbx.get(act_tr);

                    if (exp_q.size() == 0) begin
                        err_count++;
                        $error("[%0t] [SCB-QUEUE FAIL] Unexpected output! exp_q is empty, got data=0x%08h",
                               $time, act_tr.data);
                    end else begin
                        exp_tr = exp_q.pop_front();
                        if (act_tr.compare(exp_tr)) begin
                            match_count++;
                            $display("[%0t] [SCB-QUEUE PASS #%0d] data=0x%08h keep=0x%x last=%b (in_fifo_q=%0d)",
                                     $time, match_count, act_tr.data, act_tr.keep, act_tr.last, exp_q.size());
                        end else begin
                            err_count++;
                            $error("[%0t] [SCB-QUEUE FAIL] Exp: data=0x%08h keep=0x%x last=%b | Act: data=0x%08h keep=0x%x last=%b",
                                   $time, exp_tr.data, exp_tr.keep, exp_tr.last,
                                   act_tr.data, act_tr.keep, act_tr.last);
                        end
                    end
                end
            join
        endtask
    endclass

    // =========================================================================
    // 8. Agent: Encapsulates Gen / Driver / Monitor / Coverage with Active/Passive mode
    // =========================================================================
    class axis_agent;
        string name;
        bit    is_active; // 1: Active (Drives + Monitors), 0: Passive (Monitors only)
        bit    is_master; // 1: Master role, 0: Slave role
        int    num_trans;

        axis_generator     gen;
        axis_master_driver mst_drv;
        axis_slave_driver  slv_drv;
        axis_monitor       mon;     // Shared across both Active/Passive and Master/Slave modes
        axis_coverage      cov;     // Functional coverage collector

        mailbox #(axis_transaction) gen2drv;

        function new(
            string                      name,
            virtual axis_if             vif,
            mailbox #(axis_transaction) mon2scb,
            bit                         is_active = 1'b1,
            bit                         is_master = 1'b1,
            int                         num_trans = 16
        );
            this.name      = name;
            this.is_active = is_active;
            this.is_master = is_master;
            this.num_trans = num_trans;

            // Monitor and Coverage are always instantiated in both Active and Passive modes
            cov = new();
            mon = new({name, "_MON"}, vif, mon2scb, cov);

            // Driver and Generator are only instantiated in Active mode (is_active == 1)
            if (is_active) begin
                if (is_master) begin
                    gen2drv = new();
                    gen     = new(gen2drv, num_trans);
                    mst_drv = new(vif, gen2drv);
                end else begin
                    slv_drv = new(vif);
                end
            end
        endfunction

        task run();
            fork
                mon.run();
                if (is_active) begin
                    if (is_master) begin
                        fork
                            gen.run();
                            mst_drv.run();
                        join
                    end else begin
                        slv_drv.run();
                    end
                end
            join
        endtask
    endclass

    // =========================================================================
    // 9. Environment: Instantiates Agents and Scoreboard, manages execution & drain
    // =========================================================================
    class axis_env;
        axis_agent      s_agt; // Master Agent (connected to s_axis)
        axis_agent      m_agt; // Slave Agent  (connected to m_axis)
        axis_scoreboard scb;   // Base class handle (supports polymorphic assignment)

        mailbox #(axis_transaction) in_mon2scb;
        mailbox #(axis_transaction) out_mon2scb;

        function new(
            virtual axis_if s_vif,
            virtual axis_if m_vif,
            int             num_trans     = 16,
            bit             use_queue_scb = 1'b1
        );
            in_mon2scb  = new();
            out_mon2scb = new();

            // Instantiate Master Active Agent (is_active = 1, is_master = 1)
            s_agt = new("S_AGT", s_vif, in_mon2scb,  1'b1, 1'b1, num_trans);
            // Instantiate Slave Active Agent  (is_active = 1, is_master = 0)
            m_agt = new("M_AGT", m_vif, out_mon2scb, 1'b1, 1'b0);

            // Polymorphism: Base handle scb can point to either Queue or Mailbox Scoreboard
            if (use_queue_scb) begin
                axis_scoreboard_queue q_scb = new(in_mon2scb, out_mon2scb);
                scb = q_scb;
            end else begin
                scb = new(in_mon2scb, out_mon2scb);
            end
        endfunction

        task run();
            // Spawn all VIP component threads in the background
            fork
                s_agt.run();
                m_agt.run();
                scb.run();
            join_none

            // Wait until all expected transactions have been drained and verified
            wait ((scb.match_count + scb.err_count) == s_agt.num_trans);
        endtask
    endclass

endpackage
