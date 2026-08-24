// Module:      stimuli
// Description: Generator de stimuli pentru simularea top_level in ModelSim.
//              Emuleaza comutatoarele fizice de pe Nexys A7.
//
// Scenarii simulate:
//   1. Reset initial
//   2. enable 0->1: motor pornit, directie inainte
//              FPGA trimite 0x02 la Arduino
//   3. inainte_inapoi 0->1: motor pornit, directie inapoi
//              FPGA trimite 0x03 la Arduino
//   4. enable 1->0: motor oprit
//              FPGA trimite 0x01 la Arduino
//
// Nota: DEBOUNCE_MAX=10 in testbench, deci debounce dureaza 10 cicluri.
//       Un transfer SPI complet dureaza ~900 cicluri la CLK_DIV=50.
//       Fiecare scenariu are 3000 cicluri de asteptare pentru siguranta.

module stimuli #(
    parameter CLK_PERIOD = 10 // perioada ceasului in ns, 10ns = 100MHz
)(
    output reg clk,
    output reg rst_n,
    output reg enable,
    output reg inainte_inapoi,
    output reg cpol,
    output reg cpha
);

// Generare ceas
// Se inverseaza la fiecare CLK_PERIOD/2 nanosecunde
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// Scenariile de test
initial begin

    // Valori initiale - toate semnalele la 0
    rst_n          = 0;
    enable         = 0;
    inainte_inapoi = 0;
    cpol           = 0;
    cpha           = 0;

    $display("[%0t ns] Reset activ", $time);

    // Reset activ 10 cicluri de ceas
    #(CLK_PERIOD * 10);
    rst_n = 1;
    $display("[%0t ns] Reset eliberat, sistem pornit", $time);

    // Asteptam stabilizarea dupa reset
    #(CLK_PERIOD * 50);

    // Scenariu 1: enable 0->1
    // Debounce detecteaza frontul crescator dupa 10 cicluri
    // reg_interface trimite SPCR apoi SPDR = 0x02
    $display("[%0t ns] Scenariu 1: enable 0->1, motor pornit directie inainte", $time);
    enable = 1;

    // Asteptam: debounce(10) + RESET_CFG APB(3) + TX APB(3) +
    //           SPI transfer(800) + POLL APB(3) + RX APB(3) = ~900 cicluri
    // Folosim 3000 pentru siguranta
    #(CLK_PERIOD * 3000);

    // Scenariu 2: inainte_inapoi 0->1
    // reg_interface trimite SPDR = 0x03
    $display("[%0t ns] Scenariu 2: inainte_inapoi 0->1, directie inapoi", $time);
    inainte_inapoi = 1;

    #(CLK_PERIOD * 3000);

    // Scenariu 3: enable 1->0
    // reg_interface trimite SPDR = 0x01
    $display("[%0t ns] Scenariu 3: enable 1->0, motor oprit", $time);
    enable = 0;

    #(CLK_PERIOD * 3000);

    $display("[%0t ns] Simulare terminata", $time);
    $stop;
end

endmodule