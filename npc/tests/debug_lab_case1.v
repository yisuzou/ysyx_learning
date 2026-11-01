`timescale 1ns/1ps
module debug_lab_case1;
  reg  clk;
  reg  rst_n;
  reg [1:0] req_rsize;
  reg [31:0] req_addr;
  reg  req_valid;
  wire  req_ready;
  reg  req_write;
  reg [1:0] req_wsize;
  reg [31:0] req_wdata;
  reg  req_sign;
  reg  rsp_ready;
  wire [31:0] rsp_rdata;
  wire  rsp_valid;
  wire  lsu_error;
  wire [1:0] lsu_error_resp;
  wire [31:0] lsu_error_addr;
  wire  lsu_error_write;
  wire [31:0] m_axi_araddr;
  wire [2:0] m_axi_arprot;
  wire  m_axi_arvalid;
  reg  m_axi_arready;
  reg [31:0] m_axi_rdata;
  reg [1:0] m_axi_rresp;
  reg  m_axi_rvalid;
  wire  m_axi_rready;
  wire [31:0] m_axi_awaddr;
  wire [2:0] m_axi_awprot;
  wire  m_axi_awvalid;
  reg  m_axi_awready;
  wire [31:0] m_axi_wdata;
  wire [3:0] m_axi_wstrb;
  wire  m_axi_wvalid;
  reg  m_axi_wready;
  reg [1:0] m_axi_bresp;
  reg  m_axi_bvalid;
  wire  m_axi_bready;
  LSU #(.RANDOM_DELAY(0)) dut (
    .clk(clk),
    .rst_n(rst_n),
    .req_rsize(req_rsize),
    .req_addr(req_addr),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_write(req_write),
    .req_wsize(req_wsize),
    .req_wdata(req_wdata),
    .req_sign(req_sign),
    .rsp_ready(rsp_ready),
    .rsp_rdata(rsp_rdata),
    .rsp_valid(rsp_valid),
    .lsu_error(lsu_error),
    .lsu_error_resp(lsu_error_resp),
    .lsu_error_addr(lsu_error_addr),
    .lsu_error_write(lsu_error_write),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arprot(m_axi_arprot),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awprot(m_axi_awprot),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready)
  );

  always #5 clk = ~clk;
  task check;
    input ok;
    input [8*160-1:0] message;
    begin
      if (ok !== 1'b1) begin
        $display("FAIL: %0s at %0t", message, $time);
        $finish;
      end
    end
  endtask
  initial begin
    #20000;
    $display("FAIL: timeout; a transaction did not complete");
    $finish;
  end

  task read_value;
    input [31:0] word_data;
    input [1:0] size;
    input signed_load;
    input [31:0] expected;
    begin
      @(negedge clk);
      req_addr = 32'h80000100;
      req_rsize = size;
      req_sign = signed_load;
      req_write = 0;
      req_valid = 1;
      @(posedge clk);
      while (!req_ready) @(posedge clk);
      @(negedge clk);
      req_valid = 0;
      @(posedge clk);
      while (!m_axi_arvalid) @(posedge clk);
      check(m_axi_araddr == 32'h80000100, "unexpected read address");
      repeat (2) @(negedge clk);
      m_axi_rdata = word_data;
      m_axi_rvalid = 1;
      @(posedge clk);
      while (!m_axi_rready) @(posedge clk);
      @(negedge clk);
      m_axi_rvalid = 0;
      m_axi_rdata = 32'hdeadbeef;
      while (!rsp_valid) @(negedge clk);
      check(!lsu_error, "legal load must not fault");
      $display("READ word=%08h size=%0d signed=%0d got=%08h expected=%08h",
               word_data, size, signed_load, rsp_rdata, expected);
      check(rsp_rdata === expected, "load value differs from expected result");
      repeat (3) begin
        @(negedge clk);
        check(rsp_valid && rsp_rdata === expected, "response changed while blocked");
      end
      rsp_ready = 1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 0;
    end
  endtask

  initial begin
    clk = 0;
    rst_n = 0;
    req_rsize = 0;
    req_addr = 0;
    req_valid = 0;
    req_write = 0;
    req_wsize = 0;
    req_wdata = 0;
    req_sign = 0;
    rsp_ready = 0;
    m_axi_arready = 0;
    m_axi_rdata = 0;
    m_axi_rresp = 0;
    m_axi_rvalid = 0;
    m_axi_awready = 0;
    m_axi_wready = 0;
    m_axi_bresp = 0;
    m_axi_bvalid = 0;
    $dumpfile("case1.vcd");
    $dumpvars(0, debug_lab_case1);
    repeat (2) @(negedge clk);
    rst_n = 1;
    m_axi_arready = 1;
    read_value(32'h12345678, 2'd3, 0, 32'h12345678);
    read_value(32'h00008001, 2'd2, 0, 32'h00008001);
    read_value(32'h00000080, 2'd1, 1, 32'hffffff80);
    read_value(32'h0000007f, 2'd2, 1, 32'h0000007f);
    read_value(32'h00008001, 2'd2, 1, 32'hffff8001);
    read_value(32'h00000080, 2'd2, 1, 32'h00000080);

    $display("PASS: case1");
    $finish;
  end
endmodule
