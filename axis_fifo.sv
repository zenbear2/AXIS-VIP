`timescale 1ns / 1ps

module axis_fifo #(
    parameter DEPTH = 4
)(    
    axis_if.slave s_axis,
    axis_if.master m_axis
);

localparam DATA_WIDTH = $bits(s_axis.tdata);
localparam KEEP_WIDTH = $bits(s_axis.tkeep);
localparam PTR_WIDTH = $clog2(DEPTH);
localparam COUNTER_WIDTH = $clog2(DEPTH+1);

logic [DATA_WIDTH-1:0] data_mem [0:DEPTH-1];
logic [KEEP_WIDTH-1:0] keep_mem [0:DEPTH-1];
logic last_mem [0:DEPTH-1];
logic [COUNTER_WIDTH-1:0] counter;
logic [PTR_WIDTH-1:0] r_ptr,w_ptr;
logic push, pop;


  initial begin
    if (DEPTH <= 1)
      $fatal(1, "AXIS FIFO DEPTH must be bigger than one");
  end

assign m_axis.tvalid = s_axis.aresetn && (counter != 0);
assign s_axis.tready = s_axis.aresetn &&
                         ((counter < COUNTER_WIDTH'(DEPTH)) || m_axis.tready);
assign m_axis.tdata = data_mem[r_ptr];
assign m_axis.tkeep = keep_mem[r_ptr];
assign m_axis.tlast = last_mem[r_ptr];
assign push = s_axis.tvalid && s_axis.tready;
assign pop = m_axis.tvalid && m_axis.tready;


always_ff @(posedge s_axis.aclk or negedge s_axis.aresetn) begin : FIFO_WRITE
    
    if(!s_axis.aresetn)begin
        r_ptr <= '0;
        w_ptr <= '0;
        counter <= '0;
    end else begin

        if(push)begin
            data_mem[w_ptr] <= s_axis.tdata;
            keep_mem[w_ptr] <= s_axis.tkeep;
            last_mem[w_ptr] <= s_axis.tlast;
            w_ptr <= (w_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : w_ptr + 1'b1;            
        end

        if(pop)begin
            r_ptr <= (r_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : r_ptr + 1'b1;
        end
        
        case ({push, pop})
            2'b10: counter <= counter + 1'b1;
            2'b01: counter <= counter - 1'b1;
            default: ;
        endcase
    end
end


counter_in_range :assert property (
    @(posedge s_axis.aclk) disable iff (!s_axis.aresetn)
    counter <= COUNTER_WIDTH'(DEPTH)
) else $fatal(1, "AXIS FIFO count out of range");


endmodule