`timescale 1ns / 1ps

package axis_vip_pkg;

    // =========================================================================
    // 1. Transaction: 封包資料結構、Random Constraint 與 Deep Copy
    // =========================================================================
    class axis_transaction;
        rand logic [31:0] data;
        rand logic [3:0]  keep;
        rand logic        last;
        rand int          idle_cycles; // 兩筆傳輸之間的發送端閒置拍數

        // 基本合法性約束
        constraint c_default {
            idle_cycles inside {[0:3]};
            keep inside {4'b1111, 4'b0111, 4'b0011, 4'b0001};
        }

        // Deep Copy：避免 Generator 重用同一個 Object Handle 造成覆寫 (必考第 7 題)
        function axis_transaction copy();
            copy = new();
            copy.data        = this.data;
            copy.keep        = this.keep;
            copy.last        = this.last;
            copy.idle_cycles = this.idle_cycles;
        endfunction

        // 比對兩筆 Transaction 是否相同
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
    // 2. Generator: 產生 Random / Directed Transactions 並放入 Mailbox
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
                // 使用 inline constraint 控制最後一筆拉高 last
                if (!tr_template.randomize() with {
                    last == (i % 4 == 3 || i == num_trans - 1);
                }) begin
                    $fatal(1, "[GEN] Randomize failed!");
                end

                // 【重要考點】必須放入 copy() 出來的新物件，不能直接 put(tr_template)
                gen2drv.put(tr_template.copy());
            end
        endtask
    endclass
    
    // =========================================================================
    // 3. Master Driver: 取出 Transaction，呼叫 Interface 的 Master BFM 驅動
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
    // 4. Slave Driver: 呼叫 Interface 的 Slave BFM 產生隨機 Backpressure
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
    // 5. Functional Coverage: 收集封包欄位與交握狀態覆蓋率 (對應第 5 節)
    // =========================================================================
    class axis_coverage;
        axis_transaction tr;
        int              beat_cnt = 0; // 計算每個 Packet 包含幾個 beat (單 beat vs 多 beat)
        int              pkt_len  = 0;

        // 定義 Covergroup：檢查 keep、last、封包長度與 Cross Coverage
        covergroup cg_axis_pkt;
            option.per_instance = 1;

            // 1. 檢查有效的 Byte Enable 組合 (部分有效 byte vs 全部有效)
            cp_keep : coverpoint tr.keep {
                bins keep_1byte = {4'b0001};
                bins keep_2byte = {4'b0011};
                bins keep_3byte = {4'b0111};
                bins keep_4byte = {4'b1111};
                illegal_bins bad_keep = default;
            }

            // 2. 檢查 TLAST (0: 封包中間 beat, 1: 封包結尾 beat)
            cp_last : coverpoint tr.last {
                bins mid_beat  = {1'b0};
                bins last_beat = {1'b1};
            }

            // 3. 交叉覆蓋率 (Cross)：確認各種 keep 在封包中間與結尾都有測到
            cx_keep_last : cross cp_keep, cp_last;
        endgroup

        function new();
            cg_axis_pkt = new();
        endfunction

        // 提供 sample 函式，由 Monitor 或 Scoreboard 在收到交易時呼叫
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
    // 6. Monitor: 呼叫 Interface 的 Monitor BFM 取樣，送往 SCB 並觸發 Coverage
    // =========================================================================
    class axis_monitor;
        string name;
        virtual axis_if vif;
        mailbox #(axis_transaction) mon2scb;
        axis_coverage cov; // 掛載 Coverage 收集器 (Observer pattern 一對多通知)

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
                // 若有掛載 Coverage 物件，同步取樣功能覆蓋率
                if (cov != null) begin
                    cov.sample(tr);
                end
            end
        endtask
    endclass

    // =========================================================================
    // 7A. Scoreboard (基底類別 - 純 Mailbox 版): 搭配 try_get() 非阻塞取樣比對
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

        // 使用 virtual method 支援多型覆寫 (對應 3.2 節繼承與多型)
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
    // 7B. Scoreboard (獨立單一 Queue 版): 繼承自 axis_scoreboard，改用 exp_q[$]
    // =========================================================================
    class axis_scoreboard_queue extends axis_scoreboard;
        axis_transaction exp_q[$];

        function new(mailbox #(axis_transaction) exp_mbx, mailbox #(axis_transaction) act_mbx);
            super.new(exp_mbx, act_mbx);
        endfunction

        // 覆寫 (Override) Reset 清空方法：Queue 只需一行 delete() (必考第 5 題)
        virtual function void reset_flush();
            exp_q.delete();
        endfunction

        // 覆寫 (Override) run()：使用 Queue push_back / pop_front 比對
        virtual task run();
            fork
                // 執行緒 1：從 IN_MON 收期望封包，推入 exp_q 尾端
                forever begin
                    axis_transaction exp_tr;
                    exp_mbx.get(exp_tr);
                    exp_q.push_back(exp_tr);
                end

                // 執行緒 2：每當 OUT_MON 收到實際輸出，從 exp_q 前端取出比對
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
    // 8. Agent: 封裝 Generator / Driver / Monitor / Coverage，支援 Active / Passive (必考第 10 題)
    // =========================================================================
    class axis_agent;
        string name;
        bit    is_active; // 1: Active (產生激勵 + 監聽), 0: Passive (僅被動監聽)
        bit    is_master; // 1: Master 端角色, 0: Slave 端角色
        int    num_trans;

        axis_generator     gen;
        axis_master_driver mst_drv;
        axis_slave_driver  slv_drv;
        axis_monitor       mon;     // 無論 Active/Passive 或 Master/Slave 皆共用同一個 Monitor！
        axis_coverage      cov;     // 功能覆蓋率收集器

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

            // Monitor 與 Coverage 在 Active 與 Passive 模式下皆會建立 (共用元件)
            cov = new();
            mon = new({name, "_MON"}, vif, mon2scb, cov);

            // 只有 Active 模式 (is_active == 1) 才會建立 Driver 與 Generator
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
    // 9. Environment: 建立 Master/Slave Agent 與 Scoreboard，管理啟動與排空結束
    // =========================================================================
    class axis_env;
        axis_agent      s_agt; // Master Agent (接 s_axis)
        axis_agent      m_agt; // Slave Agent  (接 m_axis)
        axis_scoreboard scb;   // 父類別 Handle (可指向 axis_scoreboard 或子類別 axis_scoreboard_queue！)

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

            // 建立 Master Active Agent (is_active = 1, is_master = 1)
            s_agt = new("S_AGT", s_vif, in_mon2scb,  1'b1, 1'b1, num_trans);
            // 建立 Slave Active Agent  (is_active = 1, is_master = 0)
            m_agt = new("M_AGT", m_vif, out_mon2scb, 1'b1, 1'b0);

            // 展示 OOP 多型 (Polymorphism)：父類別 handle scb 可動態決定實例化哪一種 Scoreboard
            if (use_queue_scb) begin
                axis_scoreboard_queue q_scb = new(in_mon2scb, out_mon2scb);
                scb = q_scb;
            end else begin
                scb = new(in_mon2scb, out_mon2scb);
            end
        endfunction

        task run();
            // 啟動兩個 Agent 與 Scoreboard 背景程序 (fork...join_none)
            fork
                s_agt.run();
                m_agt.run();
                scb.run(); // 多型呼叫：若 scb 指向 axis_scoreboard_queue，就會執行 Queue 版的 run()！
            join_none

            // 等待所有交易皆從 DUT 流出並比對完畢 (Drain condition，必考第 8 題)
            wait ((scb.match_count + scb.err_count) == s_agt.num_trans);
        endtask
    endclass

endpackage
