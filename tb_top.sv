// Module:      tb_top
// Description: Testbench pentru simularea proiectului SPI in ModelSim.
//              Instantiaza generatorul de stimuli si top_level (DUT).
//              Nu are porturi, nu are logica proprie.
//
// Cum se ruleaza in ModelSim:
//   1. Compileaza toate fisierele: stimuli.sv, top_level.sv,
//      reg_interface.sv, spi_module.sv
//   2. Simuleaza modulul tb_top
//   3. Adauga semnalele la Wave si ruleaza

module tb_top;

// Semnale generate de stimuli si conectate la DUT
wire clk;
wire rst_n;
wire enable;
wire inainte_inapoi;
wire cpol;
wire cpha;

// Semnale SPI generate de DUT
// spi_miso este conectat la 0 in simulare
// Arduino nu exista, simulam ca trimite mereu 0
wire [1:0] spi_ss_n;
wire       spi_clk;
wire       spi_mosi;
wire       spi_miso;

// spi_miso = 0 in simulare
// intr-un test mai avansat am putea pune un model de Arduino aici
assign spi_miso = 1'b0;

// Instanta generator de stimuli
// DEBOUNCE_MAX este suprascris la 10 pentru simulare rapida
stimuli #(
    .CLK_PERIOD(10)
) u_stimuli (
    .clk            (clk),
    .rst_n          (rst_n),
    .enable         (enable),
    .inainte_inapoi (inainte_inapoi),
    .cpol           (cpol),
    .cpha           (cpha)
);

// Instanta DUT (Design Under Test)
// DEBOUNCE_MAX suprascris la 10 pentru simulare
// In implementarea reala ramane 500.000
top_level #(
    .DEBOUNCE_MAX(10)
) u_dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .enable         (enable),
    .inainte_inapoi (inainte_inapoi),
    .cpol           (cpol),
    .cpha           (cpha),
    .spi_ss_n       (spi_ss_n),
    .spi_clk        (spi_clk),
    .spi_mosi       (spi_mosi),
    .spi_miso       (spi_miso)
);

// Monitorizare in consolа ModelSim
// Afiseaza mesaje cand semnalele importante se schimba
initial begin
    $monitor("t=%0t rst=%b en=%b dir=%b ss_n=%b sck=%b mosi=%b",
             $time, rst_n, enable, inainte_inapoi,
             spi_ss_n[0], spi_clk, spi_mosi);
end

endmodule