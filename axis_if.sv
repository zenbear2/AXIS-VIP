`timescale 1ns / 1ps

interface axis_if #(
    parameter DATA_WIDTH = 32
)(
    input logic aclk,
    input logic aresetn
);

localparam int KEEP_WIDTH = DATA_WIDTH / 8 ;

logic tvalid;
logic tready;
logic [DATA_WIDTH-1:0] tdata;
logic [KEEP_WIDTH-1:0] tkeep;
logic tlast;

modport master (
    input aclk, aresetn,
    input tready,
    output tvalid, tdata, tkeep, tlast
);

modport slave (
    input aclk, aresetn,
    input tvalid, tdata, tkeep, tlast,
    output tready
);
    
modport moniter (
    input aclk, aresetn,
    input tready, tvalid, tdata, tkeep, tlast
);
    
endinterface //axis_if
    