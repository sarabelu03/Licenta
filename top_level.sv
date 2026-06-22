module top_level (
    input        clk,
    input        rst_n,
    // intrari fizice
    input        cpol,
    input        cpha,
    input  [7:0] data,
    input        inainte,
    input        inapoi,
    input        valid,
    // interfata SPI (merg la pini PMOD JA)
    output [1:0] spi_ss_n,
    output       spi_clk,
    output       spi_mosi,
    input        spi_miso
);

    // fire interne APB (conecteaza reg_interface cu spi_module)
    wire [1:0] paddr;
    wire       psel;
    wire       penable;
    wire       pwrite;
    wire [7:0] pwdata;
    wire [7:0] prdata;
    wire       pready;

    reg_interface u_reg (
        .clk     (clk),
        .rst_n   (rst_n),
        .cpol    (cpol),
        .cpha    (cpha),
        .data    (data),
        .inainte (inainte),
        .inapoi  (inapoi),
        .valid   (valid),
        .prdata  (prdata),
        .pready  (pready),
        .paddr   (paddr),
        .psel    (psel),
        .penable (penable),
        .pwrite  (pwrite),
        .pwdata  (pwdata)
    );

    spi_module u_spi (
        .clk      (clk),
        .rst_n    (rst_n),
        .paddr    (paddr),
        .psel     (psel),
        .penable  (penable),
        .pwrite   (pwrite),
        .pwdata   (pwdata),
        .prdata   (prdata),
        .pready   (pready),
        .spi_ss_n (spi_ss_n),
        .spi_clk  (spi_clk),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso)
    );

endmodule