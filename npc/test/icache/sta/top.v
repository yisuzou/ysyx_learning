// Synthesis wrapper for the ICache STA experiment: exposes every icache_ref
// port at the top level so yosys keeps them (no hard macro, flop-array model).
module top (
    input        clk,
    input        rst_n,
    input        s_invalidate,

    input  [31:0] s_axi_araddr,
    input   [2:0] s_axi_arprot,
    input         s_axi_arvalid,
    output        s_axi_arready,
    output [31:0] s_axi_rdata,
    output  [1:0] s_axi_rresp,
    output        s_axi_rvalid,
    input         s_axi_rready,

    output [31:0] m_axi_araddr,
    output  [2:0] m_axi_arprot,
    output  [3:0] m_axi_arlen,
    output  [2:0] m_axi_arsize,
    output  [1:0] m_axi_arburst,
    output        m_axi_arvalid,
    input         m_axi_arready,
    input  [31:0] m_axi_rdata,
    input   [1:0] m_axi_rresp,
    input         m_axi_rlast,
    input         m_axi_rvalid,
    output        m_axi_rready
);

    icache_ref u_icache (
        .clk(clk), .rst_n(rst_n), .s_invalidate(s_invalidate),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arprot(m_axi_arprot),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

endmodule
