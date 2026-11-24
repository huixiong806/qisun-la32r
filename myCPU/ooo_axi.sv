module ooo_axi (
    input logic clk, resetn,
    input logic i_valid, d_valid,
    input ooo_pkg::read_req_t i_request, d_request,
    output logic i_accept, d_accept,
    output logic i_beat_valid, d_beat_valid,
    output ooo_pkg::read_beat_t read_beat,
    input logic write_valid,
    input ooo_pkg::write_req_t write_request,
    output logic write_accept, write_done, write_error,

    output logic [3:0] arid,
    output logic [31:0] araddr,
    output logic [7:0] arlen,
    output logic [2:0] arsize,
    output logic arvalid,
    input logic arready,
    input logic [3:0] rid,
    input logic [31:0] rdata,
    input logic [1:0] rresp,
    input logic rlast, rvalid,
    output logic rready,

    output logic [31:0] awaddr,
    output logic [7:0] awlen,
    output logic [2:0] awsize,
    output logic awvalid,
    input logic awready,
    output logic [31:0] wdata,
    output logic [3:0] wstrb,
    output logic wlast, wvalid,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready
);
    import ooo_pkg::*;
    read_req_t ar;
    logic read_data_selected, ar_occupied, prefer_data;
    logic i_outstanding, d_outstanding;

    wire i_eligible = i_valid && !i_outstanding;
    wire d_eligible = d_valid && !d_outstanding;
    assign d_accept = !ar_occupied && d_eligible && (prefer_data || !i_eligible);
    assign i_accept = !ar_occupied && i_eligible && !d_accept;
    assign arvalid = ar_occupied;
    assign arid = {3'b0, read_data_selected};
    assign araddr = ar.addr;
    assign arlen = {4'b0, ar.len};
    assign arsize = {1'b0, ar.size};

    assign rready = resetn;
    assign read_beat = {rdata, rlast, |rresp};
    assign i_beat_valid = rvalid && rready && rid == 0;
    assign d_beat_valid = rvalid && rready && rid == 1;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            ar_occupied <= 0;
            read_data_selected <= 0;
            prefer_data <= 0;
            i_outstanding <= 0;
            d_outstanding <= 0;
            ar <= '0;
        end else begin
            if (arvalid && arready) ar_occupied <= 0;
            if (i_beat_valid && rlast) i_outstanding <= 0;
            if (d_beat_valid && rlast) d_outstanding <= 0;
            if (i_accept || d_accept) begin
                ar_occupied <= 1;
                read_data_selected <= d_accept;
                prefer_data <= i_accept;
                ar <= d_accept ? d_request : i_request;
                if (i_accept) i_outstanding <= 1;
                if (d_accept) d_outstanding <= 1;
            end
        end
    end

    read_req_t aw;
    logic [511:0] write_data;
    logic [3:0] write_mask, beat_index;
    logic writing, aw_pending, w_pending;

    assign write_accept = write_valid && !writing;
    assign awvalid = aw_pending;
    assign awaddr = aw.addr;
    assign awlen = {4'b0, aw.len};
    assign awsize = {1'b0, aw.size};
    assign wvalid = w_pending;
    assign wdata = write_data[beat_index * 32 +: 32];
    assign wstrb = aw.len == 0 ? write_mask : 4'b1111;
    assign wlast = beat_index == aw.len;
    assign bready = writing && !aw_pending && !w_pending;
    assign write_done = bvalid && bready;
    assign write_error = |bresp;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            writing <= 0;
            aw_pending <= 0;
            w_pending <= 0;
            beat_index <= 0;
            aw <= '0;
            write_mask <= 0;
        end else if (write_accept) begin
            writing <= 1;
            aw_pending <= 1;
            w_pending <= 1;
            aw <= write_request.address;
            write_data <= write_request.data;
            write_mask <= write_request.single_mask;
            beat_index <= 0;
        end else begin
            if (awvalid && awready) aw_pending <= 0;
            if (wvalid && wready) begin
                if (wlast) w_pending <= 0;
                else beat_index <= beat_index + 1'b1;
            end
            if (write_done) writing <= 0;
        end
    end
endmodule
