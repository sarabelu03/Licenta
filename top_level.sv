// Module:      top_level
// Description: Modulul de varf al proiectului. Nu contine logica proprie.
//              Instantiaza reg_interface si spi_module si le conecteaza
//              prin fire interne APB.
//              Expune in exterior doar semnalele fizice ale placii Nexys A7.
//
// Conexiuni fizice pe Nexys A7:
//   clk           - oscilator 100 MHz, pinul E3
//   rst_n         - butonul central BTNC, activ LOW
//   enable        - SW0: pornire motor
//   inainte_inapoi - SW1: directia motorului
//   cpol          - SW2: polaritate clock SPI
//   cpha          - SW3: faza clock SPI
//   spi_*         - conector PMOD JA

module top_level (
    input        clk,            // ceasul sistemului, 100 MHz
    input        rst_n,          // reset activ LOW, conectat la BTNC

    // comutatoare fizice de pe Nexys A7
    input        enable,          // SW0: motor pornit sau oprit
    input        inainte_inapoi,  // SW1: directia motorului
    input        cpol,            // SW2: polaritate clock SPI pentru SPCR
    input        cpha,            // SW3: faza clock SPI pentru SPCR

    // semnale SPI catre conectorul PMOD JA
    output [1:0] spi_ss_n, // Slave Select activ LOW, catre pinul 10 Arduino
    output       spi_clk,  // ceasul SPI, catre pinul 13 Arduino
    output       spi_mosi, // date FPGA catre Arduino, catre pinul 11 Arduino
    input        spi_miso  // date Arduino catre FPGA, de la pinul 12 Arduino
);

// Fire interne APB care conecteaza reg_interface cu spi_module
// Aceste semnale nu sunt vizibile in afara acestui modul
wire [1:0] paddr;   // adresa registrului: 0=SPCR, 1=SPSR, 2=SPDR
wire       psel;    // selectia slave-ului APB
wire       penable; // 0 = faza SETUP, 1 = faza ACCESS
wire       pwrite;  // 1 = scriere, 0 = citire
wire [7:0] pwdata;  // date scrise in spi_module
wire [7:0] prdata;  // date citite din spi_module
wire       pready;  // confirmare de la spi_module

// Instanta reg_interface
// Citeste comutatoarele si conduce bus-ul APB
reg_interface u_reg (
    .clk            (clk),
    .rst_n          (rst_n),
    .inainte_inapoi (inainte_inapoi),
    .enable         (enable),
    .cpol           (cpol),
    .cpha           (cpha),
    .prdata         (prdata),
    .pready         (pready),
    .paddr          (paddr),
    .psel           (psel),
    .penable        (penable),
    .pwrite         (pwrite),
    .pwdata         (pwdata)
);

// Instanta spi_module
// Primeste comenzi APB si genereaza semnalele SPI fizice
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