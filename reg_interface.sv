module reg_interface #(
    parameter DATA_WIDTH     = 8,
    parameter REGISTER_WIDTH = 8,
    parameter ADDR_WIDTH     = 2,
    parameter CNT_WIDTH      = 20  // numarul de biti ai contorului de debounce
)(
    input clk,
    input rst_n,
    //interfata intrare
    input cpol,
    input cpha,
    input [DATA_WIDTH-1:0] data,
    input inainte,
    input inapoi,
    input valid,
    //interfata APB
    input  [REGISTER_WIDTH-1:0] prdata,
    input  pready,
    output reg [ADDR_WIDTH-1:0] paddr,
    output reg psel,
    output reg penable,
    output reg pwrite,
    output reg [REGISTER_WIDTH-1:0] pwdata
);

//Debounce inainte
localparam DEBOUNCE_MAX = 500_000; // 500.000 cicuri x 10ns = 5ms

reg [CNT_WIDTH-1:0] db_cnt;
reg                 db_stable;
reg                 db_prev;
reg                 pulse_inainte; // puls de 1 ciclu la apasare reala

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        db_cnt        <= 0;
        db_stable     <= 0;
        db_prev       <= 0;
        pulse_inainte <= 0;
    end else begin
        pulse_inainte <= 0;
        if (inainte)
            if (db_cnt == DEBOUNCE_MAX - 1)
                db_stable <= 1;
            else
                db_cnt <= db_cnt + 1;
        else begin
            db_cnt    <= 0;
            db_stable <= 0;
        end
        db_prev <= db_stable;
        if (db_stable && !db_prev)
            pulse_inainte <= 1; // front crescator al db_stable 
    end
end


//Debounce inapoi
reg [CNT_WIDTH-1:0] db_cnt_back;
reg                 db_stable_back;
reg                 db_prev_back;
reg                 pulse_inapoi; // puls de 1 ciclu la apasare reala

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        db_cnt_back    <= 0;
        db_stable_back <= 0;
        db_prev_back   <= 0;
        pulse_inapoi   <= 0;
    end else begin
        pulse_inapoi <= 0; 
        if (inapoi)
            if (db_cnt_back == DEBOUNCE_MAX - 1)
                db_stable_back <= 1;
            else
                db_cnt_back <= db_cnt_back + 1;
        else begin
            db_cnt_back    <= 0;
            db_stable_back <= 0;
        end
        db_prev_back <= db_stable_back;
        if (db_stable_back && !db_prev_back)
            pulse_inapoi <= 1; // front crescator al db_stable_back 
    end
end

//APB Master FSM 
// IDLE asteapta start_apb = 1 de la Control FSM
// SETUP pune adresa, data, directia pe bus (penable=0)
// ACCESS ridica penable, asteapta pready de la spi_module
localparam APB_IDLE   = 2'd0;
localparam APB_SETUP  = 2'd1;
localparam APB_ACCESS = 2'd2;

reg [1:0]                apb_state;
reg                      start_apb;  // Control FSM pune 1 si porneste tranzactia
reg                      do_write;   // 1=scriere, 0=citire
reg [1:0]                apb_addr;   // adresa registrului
reg [REGISTER_WIDTH-1:0] apb_wdata;  // data de scris
reg                      apb_done;   // 1 = tranzactia s-a terminat
reg [REGISTER_WIDTH-1:0] apb_rdata;  // data citita din registru

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        apb_state <= APB_IDLE;
        psel      <= 0;
        penable   <= 0;
        pwrite    <= 0;
        paddr     <= 0;
        pwdata    <= 0;
        apb_done  <= 0;
        apb_rdata <= 0;
    end else begin
        apb_done <= 0; 
        case (apb_state)
            APB_IDLE: begin
                psel    <= 0;
                penable <= 0;
                if (start_apb)
                    apb_state <= APB_SETUP;
            end
            APB_SETUP: begin
                psel      <= 1;
                penable   <= 0;        // in SETUP penable e mereu 0
                pwrite    <= do_write;
                paddr     <= apb_addr;
                pwdata    <= apb_wdata;
                apb_state <= APB_ACCESS;
            end
            APB_ACCESS: begin
                penable <= 1;          // in ACCESS penable devine 1
                if (pready) begin      // spi_module a confirmat
                    apb_rdata <= prdata;
                    psel      <= 0;
                    penable   <= 0;
                    apb_done  <= 1;    // semnalam Control FSM ca am terminat
                    apb_state <= APB_IDLE;
                end
            end
        endcase
    end
end

//Control FSM 
// RESET_CFG la pornire: scrie SPCR (SPE=1, cpol, cpha)
// IDLE asteapta apasarea unui buton
// TX scrie SPDR cu data de pe switch-uri → declanseaza transfer SPI
// POLL citeste SPSR in bucla pana cand SPIF=1 (transferul s-a terminat)
// RX citeste SPDR (raspunsul Arduino)
localparam S_RESET_CFG = 3'd0;
localparam S_IDLE      = 3'd1;
localparam S_TX        = 3'd2;
localparam S_POLL      = 3'd3;
localparam S_RX        = 3'd4;

reg [2:0]                ctrl_state;
reg [REGISTER_WIDTH-1:0] spsr_val; // valoarea citita din SPSR

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ctrl_state <= S_RESET_CFG;
        start_apb  <= 0;
        do_write   <= 0;
        apb_addr   <= 0;
        apb_wdata  <= 0;
        spsr_val   <= 0;
    end else begin
        start_apb <= 0;
        case (ctrl_state)
            // SPCR = { SPE=1, 4'b0, cpol, cpha, 1'b0 }
            S_RESET_CFG: begin
                do_write  <= 1;
                apb_addr  <= 2'd0;  // adresa SPCR
                apb_wdata <= {1'b1, 4'b0, cpol, cpha, 1'b0};
                start_apb <= 1;
                if (apb_done)
                    ctrl_state <= S_IDLE;
            end
            S_IDLE:
                if (pulse_inainte && valid)
                    ctrl_state <= S_TX;
            S_TX: begin
                do_write  <= 1;
                apb_addr  <= 2'd2;  // adresa SPDR
                apb_wdata <= data;
                start_apb <= 1;
                if (apb_done)
                    ctrl_state <= S_POLL;
            end
            S_POLL: begin
                do_write  <= 0;
                apb_addr  <= 2'd1;  // adresa SPSR
                if (!apb_done)
                    start_apb <= 1;
                if (apb_done) begin
                    spsr_val <= apb_rdata;
                    if (apb_rdata[7]) // SPIF = bitul 7
                        ctrl_state <= S_RX;
                end
            end
            S_RX: begin
                do_write  <= 0;
                apb_addr  <= 2'd2;  // adresa SPDR
                start_apb <= 1;
                if (apb_done)
                    ctrl_state <= S_IDLE;
            end
        endcase
    end
end

endmodule