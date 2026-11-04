`timescale 1ns / 1ps

interface axis_if #(
    parameter DATA_WIDTH = 32
)(
    input logic aclk,
    input logic aresetn
);

    localparam int KEEP_WIDTH = DATA_WIDTH / 8;

    logic tvalid;
    logic tready;
    logic [DATA_WIDTH-1:0] tdata;
    logic [KEEP_WIDTH-1:0] tkeep;
    logic tlast;

    modport master (
        input  aclk, aresetn,
        input  tready,
        output tvalid, tdata, tkeep, tlast
    );

    modport slave (
        input  aclk, aresetn,
        input  tvalid, tdata, tkeep, tlast,
        output tready
    );

    modport monitor (
        input aclk, aresetn,
        input tready, tvalid, tdata, tkeep, tlast
    );

    // synthesis translate_off
    clocking mst_cb @(posedge aclk);
        default input #1step output #1ns;
        output tvalid, tdata, tkeep, tlast;
        input  tready;
    endclocking

    clocking slv_cb @(posedge aclk);
        default input #1step output #1ns;
        input  tvalid, tdata, tkeep, tlast;
        output tready;
    endclocking

    clocking mon_cb @(posedge aclk);
        default input #1step;
        input tvalid, tready, tdata, tkeep, tlast;
    endclocking

    // 1. Stall Hold Assertion: When TVALID=1 and TREADY=0, TVALID must remain 1 and payload must remain stable on the next cycle
    stall_hold : assert property (
        @(posedge aclk) disable iff (!aresetn)
        (tvalid && !tready) |=> (tvalid && $stable(tdata) && $stable(tkeep) && $stable(tlast))
    ) else $fatal(1, "[SVA ERROR] Protocol violation: Signals changed or tvalid dropped during stall!");

    // 2. Reset Assertion: TVALID must be driven low (0) while reset (!aresetn) is active
    reset_tvalid_low : assert property (
        @(posedge aclk)
        (!aresetn) |-> (tvalid == 1'b0)
    ) else $fatal(1, "[SVA ERROR] Protocol violation: TVALID must be 0 during reset!");

    // =========================================================
    // Pin-level BFM Tasks
    // =========================================================

    task automatic master_reset();
        tvalid <= '0;
        tdata  <= '0;
        tkeep  <= '0;
        tlast  <= '0;
        wait (aresetn === 1'b1);
        @(mst_cb);
    endtask

    task automatic master_send(
        input logic [DATA_WIDTH-1:0] data,
        input logic [KEEP_WIDTH-1:0] keep,
        input logic                  tlast,
        input int                    idle_cycles = 0
    );
        repeat (idle_cycles) begin
            mst_cb.tvalid <= 1'b0;
            @(mst_cb);
        end

        mst_cb.tvalid <= 1'b1;
        mst_cb.tdata  <= data;
        mst_cb.tkeep  <= keep;
        mst_cb.tlast  <= tlast;

        do begin
            @(mst_cb);
        end while (!mst_cb.tready && aresetn);

        mst_cb.tvalid <= 1'b0;
    endtask

    task automatic slave_reset();
        tready <= '0;
        wait (aresetn === 1'b1);
        @(slv_cb);
    endtask

    task automatic slave_received(
        input logic ready,
        input int   stall_cycles = 0
    );
        repeat (stall_cycles) begin
            slv_cb.tready <= 1'b0;
            @(slv_cb);
        end

        slv_cb.tready <= ready;
        @(slv_cb);
    endtask

    task automatic monitor_sample(
        output logic [DATA_WIDTH-1:0] data,
        output logic [KEEP_WIDTH-1:0] keep,
        output logic                  last
    );
        do begin
            @(mon_cb);
        end while (!(aresetn && mon_cb.tvalid && mon_cb.tready));
        data = mon_cb.tdata;
        keep = mon_cb.tkeep;
        last = mon_cb.tlast;
    endtask
    // synthesis translate_on

endinterface // axis_if
