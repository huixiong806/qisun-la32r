module mycpu_top(
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [7:0]  ext_int,
    output wire [3:0]  arid,
    output wire [31:0] araddr,
    output wire [7:0]  arlen,
    output wire [2:0]  arsize,
    output wire [1:0]  arburst,
    output wire [1:0]  arlock,
    output wire [3:0]  arcache,
    output wire [2:0]  arprot,
    output wire        arvalid,
    input  wire        arready,
    input  wire [3:0]  rid,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,
    output wire [3:0]  awid,
    output wire [31:0] awaddr,
    output wire [7:0]  awlen,
    output wire [2:0]  awsize,
    output wire [1:0]  awburst,
    output wire [1:0]  awlock,
    output wire [3:0]  awcache,
    output wire [2:0]  awprot,
    output wire        awvalid,
    input  wire        awready,
    output wire [3:0]  wid,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,
    input  wire [3:0]  bid,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready,
    output wire        debug_valid,
    output wire [31:0] debug_wb_pc,
    output wire [3:0]  debug_wb_rf_we,
    output wire [4:0]  debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata,
    output wire        debug1_valid,
    output wire [31:0] debug1_wb_pc,
    output wire [3:0]  debug1_wb_rf_we,
    output wire [4:0]  debug1_wb_rf_wnum,
    output wire [31:0] debug1_wb_rf_wdata,
    output wire        debug_exception
);
    assign arburst = 2'b01;
    assign arlock = 0;
    assign arcache = 0;
    assign arprot = 0;
    assign awid = 4'd1;
    assign awburst = 2'b01;
    assign awlock = 0;
    assign awcache = 0;
    assign awprot = 0;
    assign wid = awid;

    ooo_core core (
        .clk(aclk), .resetn(aresetn), .ext_int(ext_int),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid && bid == awid), .bready(bready),
        .debug_valid(debug_valid), .debug_wb_pc(debug_wb_pc),
        .debug_wb_rf_we(debug_wb_rf_we), .debug_wb_rf_wnum(debug_wb_rf_wnum),
        .debug_wb_rf_wdata(debug_wb_rf_wdata), .debug1_valid(debug1_valid),
        .debug1_wb_pc(debug1_wb_pc), .debug1_wb_rf_we(debug1_wb_rf_we),
        .debug1_wb_rf_wnum(debug1_wb_rf_wnum), .debug1_wb_rf_wdata(debug1_wb_rf_wdata),
        .debug_exception(debug_exception)
    );
endmodule
