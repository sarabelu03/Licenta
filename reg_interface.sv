// Module:      reg_interface
// Description: APB Master care face legatura intre comutatoarele
//              fizice de pe Nexys A7 si registrele din spi_module.
//
//              Detecteaza frontul crescator si coborator al comutatorului
//              enable si frontul crescator al comutatorului inainte_inapoi
//              prin filtre de debounce, apoi initiaza tranzactii APB
//              catre spi_module pentru a configura si declansa
//              transferuri SPI catre Arduino.
//
// Format byte trimis la Arduino:
//   bit 1 = enable          (1 = motor pornit)
//   bit 0 = inainte_inapoi  (0 = inainte, 1 = inapoi)
//   biti 7..2 = 0 (neutilizati)
//
// Secventa Control FSM la schimbarea unui comutator:
//   S_RESET_CFG: scrie SPCR o singura data la pornire
//   S_IDLE:      asteapta frontul crescator sau coborator al unui comutator
//   S_TX:        scrie SPDR cu comanda pentru motor
//   S_POLL:      citeste SPSR in bucla pana cand SPIF = 1
//   S_RX:        citeste SPDR pentru a obtine raspunsul Arduino

module reg_interface #(
    parameter REGISTER_WIDTH = 8,      // latimea in biti a registrelor APB
    parameter ADDR_WIDTH     = 2,      // latimea adresei APB
    parameter CNT_WIDTH      = 20,     // latimea contorului debounce, 2^20 > 500000
    parameter DEBOUNCE_MAX   = 500_000 // cicluri pentru filtrarea bounce-ului mecanic
)(
    input clk,   // ceasul sistemului, 100 MHz
    input rst_n, // reset activ LOW

    // comutatoare fizice de pe Nexys A7
    input inainte_inapoi, // SW0: directia motorului, 0 = inainte, 1 = inapoi
    input enable,         // SW1: pornire motor, 1 = pornit, 0 = oprit
    input cpol,           // SW2: polaritate clock SPI, intra in SPCR bit 2
    input cpha,           // SW3: faza clock SPI, intra in SPCR bit 1

    // interfata APB Master catre spi_module
    input  [REGISTER_WIDTH-1:0] prdata,  // date citite din spi_module
    input                       pready,  // confirmare de la spi_module
    output reg [ADDR_WIDTH-1:0] paddr,   // adresa registrului: 0=SPCR,1=SPSR,2=SPDR
    output reg                  psel,    // 1 = masterul initiaza tranzactie APB
    output reg                  penable, // 0 = faza SETUP, 1 = faza ACCESS
    output reg                  pwrite,  // 1 = scriere, 0 = citire
    output reg [REGISTER_WIDTH-1:0] pwdata // date scrise in spi_module
);

// Stari APB FSM
localparam APB_IDLE   = 2'd0;
localparam APB_SETUP  = 2'd1;
localparam APB_ACCESS = 2'd2;

// Stari Control FSM
localparam S_RESET_CFG = 3'd0;
localparam S_IDLE      = 3'd1;
localparam S_TX        = 3'd2;
localparam S_POLL      = 3'd3;
localparam S_RX        = 3'd4;

// Semnale debounce pentru comutatorul enable
reg [CNT_WIDTH-1:0] db_cnt_en;     // numara cicluri consecutive cat enable e ridicat
reg                 db_stable_en;  // 1 dupa ce enable a stat ridicat DEBOUNCE_MAX cicluri
reg                 db_prev_en;    // valoarea anterioara a db_stable_en pentru detectie front
reg                 pulse_enable;      // puls de 1 ciclu pe frontul crescator al db_stable_en
reg                 pulse_enable_fall; // puls de 1 ciclu pe frontul coborator al db_stable_en

// Semnale debounce pentru comutatorul inainte_inapoi
reg [CNT_WIDTH-1:0] db_cnt_ii;
reg                 db_stable_ii;
reg                 db_prev_ii;
reg                 pulse_ii; // puls de 1 ciclu pe frontul crescator al db_stable_ii

// Semnale APB FSM
reg [1:0]                apb_state; // starea curenta a APB FSM
reg                      apb_done;  // puls de 1 ciclu la terminarea tranzactiei APB
reg [REGISTER_WIDTH-1:0] apb_rdata; // data capturata din spi_module dupa o citire

// Starea Control FSM
reg [2:0]                ctrl_state; // starea curenta a Control FSM
reg [REGISTER_WIDTH-1:0] spsr_val;   // valoarea SPSR citita in timpul polling-ului

// Semnale combinationale pentru a evita intarzieri de 1 ciclu la tranzitii
reg                      do_write;      // 1 = scriere, 0 = citire
reg [ADDR_WIDTH-1:0]     apb_addr_int;  // adresa registrului de accesat
reg [REGISTER_WIDTH-1:0] apb_wdata_int; // data de scris in registru

// start_apb: semnal combinational, 1 cand Control FSM cere o tranzactie
// si APB FSM este liber
wire start_apb = (apb_state == APB_IDLE) && !apb_done &&
                 (ctrl_state == S_RESET_CFG ||
                  ctrl_state == S_TX        ||
                  ctrl_state == S_POLL      ||
                  ctrl_state == S_RX);

// DEBOUNCE enable - db_cnt_en
// Incrementat cat timp enable e ridicat, resetat cand enable coboara
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        db_cnt_en <= 0;
    else if (!enable)
        db_cnt_en <= 0;
    else if (db_cnt_en < DEBOUNCE_MAX - 1)
        db_cnt_en <= db_cnt_en + 1;

// DEBOUNCE enable - db_stable_en
// Devine 1 cand enable a stat ridicat timp de DEBOUNCE_MAX cicluri
// Devine 0 imediat cand enable coboara
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        db_stable_en <= 0;
    else if (!enable)
        db_stable_en <= 0;
    else if (db_cnt_en == DEBOUNCE_MAX - 1)
        db_stable_en <= 1;

// DEBOUNCE enable - db_prev_en
// Retine valoarea anterioara a db_stable_en pentru detectia frontului
always @(posedge clk or negedge rst_n)
    if (!rst_n) db_prev_en <= 0;
    else        db_prev_en <= db_stable_en;

// DEBOUNCE enable - pulse_enable
// Puls de 1 ciclu pe frontul crescator al db_stable_en
// Declanseaza transfer SPI cand enable trece din 0 in 1
always @(posedge clk or negedge rst_n)
    if (!rst_n) pulse_enable <= 0;
    else        pulse_enable <= db_stable_en && !db_prev_en;

// DEBOUNCE enable - pulse_enable_fall
// Puls de 1 ciclu pe frontul coborator al db_stable_en
// Declanseaza transfer SPI cand enable trece din 1 in 0
// Astfel Arduino primeste comanda de oprire imediat
always @(posedge clk or negedge rst_n)
    if (!rst_n) pulse_enable_fall <= 0;
    else        pulse_enable_fall <= !db_stable_en && db_prev_en;

// DEBOUNCE inainte_inapoi - db_cnt_ii
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        db_cnt_ii <= 0;
    else if (!inainte_inapoi)
        db_cnt_ii <= 0;
    else if (db_cnt_ii < DEBOUNCE_MAX - 1)
        db_cnt_ii <= db_cnt_ii + 1;

// DEBOUNCE inainte_inapoi - db_stable_ii
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        db_stable_ii <= 0;
    else if (!inainte_inapoi)
        db_stable_ii <= 0;
    else if (db_cnt_ii == DEBOUNCE_MAX - 1)
        db_stable_ii <= 1;

// DEBOUNCE inainte_inapoi - db_prev_ii
always @(posedge clk or negedge rst_n)
    if (!rst_n) db_prev_ii <= 0;
    else        db_prev_ii <= db_stable_ii;

// DEBOUNCE inainte_inapoi - pulse_ii
// Puls de 1 ciclu pe frontul crescator al db_stable_ii
always @(posedge clk or negedge rst_n)
    if (!rst_n) pulse_ii <= 0;
    else        pulse_ii <= db_stable_ii && !db_prev_ii;

// APB FSM - apb_state
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        apb_state <= APB_IDLE;
    else case (apb_state)
        APB_IDLE:   if (start_apb) apb_state <= APB_SETUP;
        APB_SETUP:                 apb_state <= APB_ACCESS;
        APB_ACCESS: if (pready)    apb_state <= APB_IDLE;
        default:                   apb_state <= APB_IDLE;
    endcase

// APB FSM - psel
// 1 in fazele SETUP si ACCESS, 0 in IDLE
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        psel <= 0;
    else case (apb_state)
        APB_IDLE:   psel <= 0;
        APB_SETUP:  psel <= 1;
        APB_ACCESS: if (pready) psel <= 0;
        default:    psel <= 0;
    endcase

// APB FSM - penable
// 0 in faza SETUP, 1 in faza ACCESS pana cand pready soseste
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        penable <= 0;
    else case (apb_state)
        APB_IDLE:   penable <= 0;
        APB_SETUP:  penable <= 0;
        APB_ACCESS: penable <= pready ? 0 : 1;
        default:    penable <= 0;
    endcase

// APB FSM - pwrite
// Captureaza do_write la inceputul fazei SETUP
always @(posedge clk or negedge rst_n)
    if (!rst_n)                      pwrite <= 0;
    else if (apb_state == APB_SETUP) pwrite <= do_write;
    else if (apb_state == APB_IDLE)  pwrite <= 0;

// APB FSM - paddr
// Captureaza adresa registrului la inceputul fazei SETUP
always @(posedge clk or negedge rst_n)
    if (!rst_n)                      paddr <= 0;
    else if (apb_state == APB_SETUP) paddr <= apb_addr_int;

// APB FSM - pwdata
// Captureaza data de scris la inceputul fazei SETUP
always @(posedge clk or negedge rst_n)
    if (!rst_n)                      pwdata <= 0;
    else if (apb_state == APB_SETUP) pwdata <= apb_wdata_int;

// APB FSM - apb_done
// Puls de 1 ciclu cand faza ACCESS se termina cu pready = 1
always @(posedge clk or negedge rst_n)
    if (!rst_n) apb_done <= 0;
    else        apb_done <= (apb_state == APB_ACCESS) && pready;

// APB FSM - apb_rdata
// Captureaza data citita din spi_module la terminarea tranzactiei
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        apb_rdata <= 0;
    else if (apb_state == APB_ACCESS && pready)
        apb_rdata <= prdata;

// Control FSM - ctrl_state
// pulse_enable_fall declanseaza transfer si la coborarea enable
// astfel Arduino primeste comanda de oprire imediat
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        ctrl_state <= S_RESET_CFG;
    else case (ctrl_state)
        S_RESET_CFG: if (apb_done)                                       ctrl_state <= S_IDLE;
        S_IDLE:      if (pulse_enable || pulse_enable_fall || pulse_ii)   ctrl_state <= S_TX;
        S_TX:        if (apb_done)                                        ctrl_state <= S_POLL;
        S_POLL:      if (apb_done && apb_rdata[7])                        ctrl_state <= S_RX;
        S_RX:        if (apb_done)                                        ctrl_state <= S_IDLE;
        default:     ctrl_state <= S_IDLE;
    endcase

// Control FSM - do_write
always @(*)
    case (ctrl_state)
        S_RESET_CFG: do_write = 1;
        S_TX:        do_write = 1;
        default:     do_write = 0;
    endcase

// Control FSM - apb_addr_int
always @(*)
    case (ctrl_state)
        S_RESET_CFG: apb_addr_int = 2'd0;
        S_TX:        apb_addr_int = 2'd2;
        S_POLL:      apb_addr_int = 2'd1;
        S_RX:        apb_addr_int = 2'd2;
        default:     apb_addr_int = 2'd0;
    endcase

// Control FSM - apb_wdata_int
// La enable=0 trimite {6b0, 0, inainte_inapoi} → motor oprit
// La enable=1 trimite {6b0, 1, inainte_inapoi} → motor pornit
always @(*)
    case (ctrl_state)
        S_RESET_CFG: apb_wdata_int = {1'b1, 4'b0, cpol, cpha, 1'b0};
        S_TX:        apb_wdata_int = {6'b0, enable, inainte_inapoi};
        default:     apb_wdata_int = 0;
    endcase

// Control FSM - spsr_val
// Salveaza valoarea SPSR citita in timpul polling-ului
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        spsr_val <= 0;
    else if (ctrl_state == S_POLL && apb_done)
        spsr_val <= apb_rdata;

endmodule