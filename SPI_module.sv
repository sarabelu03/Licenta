// Module:      spi_module
// Description: Controller SPI Master cu interfata APB Slave.
//              Primeste comenzi de la reg_interface prin APB,
//              stocheaza datele in registre interne si genereaza
//              semnalele SPI fizice catre Arduino Uno.
//
// Registre interne accesibile prin APB:
//   Adresa 0: SPCR - registru de control
//   Adresa 1: SPSR - registru de stare
//   Adresa 2: SPDR - registru de date (TX la scriere, RX la citire)
//
// Protocol SPI Mode 0: CPOL=0, CPHA=0
//   SCK sta la 0 in repaus, datele sunt citite pe frontul crescator

module spi_module #(
    parameter NO_OF_SLAVES   = 2, // numarul de fire SS_N generate
    parameter REGISTER_WIDTH = 8, // latimea in biti a registrelor
    parameter ADDR_WIDTH     = 2  // latimea adresei APB, 3 registre = 2 biti
)(
    input clk,   // ceasul sistemului, 100 MHz pe Nexys A7
    input rst_n, // reset activ LOW, 0 = reset, 1 = functionare normala

    // interfata APB Slave
    input  [ADDR_WIDTH-1:0]         paddr,   // adresa registrului: 0=SPCR, 1=SPSR, 2=SPDR
    input                           psel,    // 1 = masterul adreseaza acest modul
    input                           penable, // 0 = faza SETUP, 1 = faza ACCESS
    input                           pwrite,  // 1 = scriere, 0 = citire
    input  [REGISTER_WIDTH-1:0]     pwdata,  // data scrisa de master in registru
    output reg [REGISTER_WIDTH-1:0] prdata,  // data citita de master din registru
    output reg                      pready,  // confirmare slave, tranzactia poate continua

    // interfata SPI Master catre Arduino
    output reg [NO_OF_SLAVES-1:0]   spi_ss_n, // Slave Select activ LOW, 0 = Arduino asculta
    output reg                      spi_clk,  // ceasul SPI generat de FPGA
    output reg                      spi_mosi, // date de la FPGA catre Arduino
    input                           spi_miso  // date de la Arduino catre FPGA
);

// Registrul de control SPCR
// bit 7: SPE  = SPI Enable, trebuie 1 pentru a porni SPI
// bit 2: CPOL = Clock Polarity
// bit 1: CPHA = Clock Phase
reg [REGISTER_WIDTH-1:0] spcr;

// Registrul de stare SPSR stocat ca biti separati
// pentru a permite blocuri always separate per bit
// bit 7: SPIF = transfer complet
// bit 0: WCOL = write collision
reg spsr_spif;
reg spsr_wcol;

// Combinarea bitilor de stare intr-un registru de 8 biti pentru citire APB
wire [REGISTER_WIDTH-1:0] spsr = {spsr_spif, 6'b0, spsr_wcol};

// Registrul de date TX, incarcat de APB, trimis pe MOSI
reg [REGISTER_WIDTH-1:0] spdr_tx;

// Registrul de date RX, incarcat din MISO, citit de APB
reg [REGISTER_WIDTH-1:0] spdr_rx;

// Puls de 1 ciclu generat la scrierea APB in SPDR
// Detectat de SPI FSM pentru a porni un nou transfer
reg transfer_req;

// Impartitor de frecventa: 100 MHz / (2 x 50) = 1 MHz SCK
localparam CLK_DIV = 50;
reg [5:0] clk_cnt; // contor pentru impartitorul de frecventa, 0 la CLK_DIV-1
reg       tick;    // puls de 1 ciclu la fiecare jumatate de perioada SCK

// Stari ale SPI State Machine
localparam S_IDLE    = 3'd0; // asteptare cerere transfer
localparam S_CS_LOW  = 3'd1; // activare SS_N, un tick de setup
localparam S_SHIFT   = 3'd2; // transfer 8 biti, 2 tickuri per bit = 16 total
localparam S_CS_HIGH = 3'd3; // dezactivare SS_N dupa transfer
localparam S_DONE    = 3'd4; // salvare date primite si semnalizare terminare

reg [2:0] state;    // starea curenta a SPI FSM
reg [3:0] tick_cnt; // contorizeaza tickurile in SHIFT, 0 la 15

// Registru de shiftare TX: incarcat la inceput, shiftat stanga la fiecare
// front descrescator al SCK
reg [7:0] shift_tx;

// Registru de shiftare RX: acumuleaza bitii de pe MISO la fiecare
// front crescator al SCK
reg [7:0] shift_rx;

// APB WRITE - spcr
// Scrie in registrul de control cand APB adreseaza SPCR
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spcr <= 0;
    else if (psel && penable && pready && pwrite && paddr == 2'd0)
        spcr <= pwdata;

// APB WRITE - spsr_wcol
// Bitul WCOL din SPSR poate fi scris de APB la adresa 1
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spsr_wcol <= 0;
    else if (psel && penable && pready && pwrite && paddr == 2'd1)
        spsr_wcol <= pwdata[0];

// APB WRITE - spdr_tx
// Incarca data de trimis cand APB scrie la adresa SPDR
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spdr_tx <= 0;
    else if (psel && penable && pready && pwrite && paddr == 2'd2)
        spdr_tx <= pwdata;

// APB WRITE - transfer_req
// Genereaza un puls de 1 ciclu la scrierea in SPDR
// SPI FSM detecteaza acest puls pentru a porni transferul
always @(posedge clk or negedge rst_n)
    if (!rst_n) transfer_req <= 0;
    else        transfer_req <= (psel && penable && pready && pwrite && paddr == 2'd2);

// APB READ - prdata
// Pregateste datele pentru master in faza SETUP
// Datele trebuie sa fie stabile cand vine faza ACCESS
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        prdata <= 0;
    else if (psel && !penable && !pwrite)
        case (paddr)
            2'd0:    prdata <= spcr;
            2'd1:    prdata <= spsr;
            2'd2:    prdata <= spdr_rx;
            default: prdata <= 0;
        endcase

// PREADY
// Ridicat la 1 in faza SETUP astfel incat in ACCESS
// slave-ul este deja confirmat, rezultand 0 wait states
always @(posedge clk or negedge rst_n)
    if (!rst_n)                pready <= 0;
    else if (psel && !penable) pready <= 1;
    else                       pready <= 0;

// IMPARTITOR DE FRECVENTA - clk_cnt
// Numara de la 0 la CLK_DIV-1 si se reseteaza
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        clk_cnt <= 0;
    else if (clk_cnt == CLK_DIV - 1)
        clk_cnt <= 0;
    else
        clk_cnt <= clk_cnt + 1;

// IMPARTITOR DE FRECVENTA - tick
// Puls de 1 ciclu la fiecare CLK_DIV cicluri de sistem
// Fiecare tick reprezinta o jumatate de perioada SCK
always @(posedge clk or negedge rst_n)
    if (!rst_n) tick <= 0;
    else        tick <= (clk_cnt == CLK_DIV - 1);

// SPI FSM - state
// Gestioneaza tranzitiile intre starile transferului SPI
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        state <= S_IDLE;
    else case (state)
        S_IDLE:    if (spcr[7] && transfer_req)   state <= S_CS_LOW;
        S_CS_LOW:  if (tick)                      state <= S_SHIFT;
        S_SHIFT:   if (tick && tick_cnt == 4'd15) state <= S_CS_HIGH;
        S_CS_HIGH: if (tick)                      state <= S_DONE;
        S_DONE:                                   state <= S_IDLE;
        default:                                  state <= S_IDLE;
    endcase

// SPI FSM - spi_ss_n
// 0 in timpul intregului transfer, 1 in toate celelalte stari
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spi_ss_n <= {NO_OF_SLAVES{1'b1}};
    else case (state)
        S_CS_LOW: spi_ss_n <= {NO_OF_SLAVES{1'b0}};
        S_SHIFT:  spi_ss_n <= {NO_OF_SLAVES{1'b0}};
        default:  spi_ss_n <= {NO_OF_SLAVES{1'b1}};
    endcase

// SPI FSM - spi_clk
// Oscileaza in starea SHIFT sincron cu tick
// tick_cnt par = front crescator SCK = 1
// tick_cnt impar = front descrescator SCK = 0
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spi_clk <= 0;
    else if (state == S_SHIFT && tick)
        spi_clk <= !tick_cnt[0];

// SPI FSM - spi_mosi
// Primul bit plasat in CS_LOW, urmatorii biti pe frontul descrescator al SCK
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spi_mosi <= 0;
    else if (state == S_CS_LOW && tick)
        spi_mosi <= shift_tx[7]; // MSB plasat inainte de primul front SCK
    else if (state == S_SHIFT && tick && tick_cnt[0])
        spi_mosi <= shift_tx[6]; // urmatorul bit pe frontul descrescator

// SPI FSM - shift_tx
// Incarcat cu datele de trimis la inceputul transferului
// Shiftat stanga pe fiecare front descrescator al SCK
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        shift_tx <= 0;
    else if (state == S_IDLE && spcr[7] && transfer_req)
        shift_tx <= spdr_tx;
    else if (state == S_SHIFT && tick && tick_cnt[0])
        shift_tx <= {shift_tx[6:0], 1'b0};

// SPI FSM - shift_rx
// Resetat la inceputul transferului
// Acumuleaza biti de pe MISO pe fiecare front crescator al SCK
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        shift_rx <= 0;
    else if (state == S_IDLE && spcr[7] && transfer_req)
        shift_rx <= 0;
    else if (state == S_SHIFT && tick && !tick_cnt[0])
        shift_rx <= {shift_rx[6:0], spi_miso};

// SPI FSM - tick_cnt
// Numara tickurile in starea SHIFT
// 16 tickuri totale: 8 biti x 2 tickuri per bit
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        tick_cnt <= 0;
    else if (state == S_IDLE)
        tick_cnt <= 0;
    else if (state == S_SHIFT && tick)
        tick_cnt <= tick_cnt + 1;

// SPI FSM - spdr_rx
// Salveaza byte-ul primit din shift_rx la terminarea transferului
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spdr_rx <= 0;
    else if (state == S_DONE)
        spdr_rx <= shift_rx;

// SPI FSM - spsr_spif
// Setat la 1 cand transferul se termina
// Sters cand un nou transfer incepe
// reg_interface face polling pe acest bit pentru a sti cand poate citi SPDR
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spsr_spif <= 0;
    else if (state == S_DONE)
        spsr_spif <= 1;
    else if (state == S_CS_LOW)
        spsr_spif <= 0;

endmodule