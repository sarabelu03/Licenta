module spi_module #(
    parameter NO_OF_SLAVES   = 2,
    parameter REGISTER_WIDTH = 8,
    parameter ADDR_WIDTH     = 2
)(
    input clk,
    input rst_n,
    // interfata APB
    input  [ADDR_WIDTH-1:0]         paddr,
    input                           psel,
    input                           penable,
    input                           pwrite,
    input  [REGISTER_WIDTH-1:0]     pwdata,
    output reg [REGISTER_WIDTH-1:0] prdata,
    output reg                      pready,
    // interfata SPI
    output reg [NO_OF_SLAVES-1:0]   spi_ss_n,
    output reg                      spi_clk,
    output reg                      spi_mosi,
    input                           spi_miso
);

reg [REGISTER_WIDTH-1:0] spcr;     // registru de control  adresa 0
reg [REGISTER_WIDTH-1:0] spsr;     // registru de stare    adresa 1
reg [REGISTER_WIDTH-1:0] spdr_tx;  // date de trimis la Arduino adresa 2
reg [REGISTER_WIDTH-1:0] spdr_rx;  // date primite de la Arduino adresa 2
reg                      transfer_req; // 1 ciclu → porneste transferul SPI

// scriere APB → registre interne
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        spcr         <= 0;
        spsr         <= 0;
        spdr_tx      <= 0;
        transfer_req <= 0;
    end else begin
        transfer_req <= 0; // implicit 0
        if (psel && penable && pready && pwrite) // faza ACCESS, scriere
            case (paddr)
                2'd0: spcr        <= pwdata;      // scriem in registrul de control
                2'd1: spsr[0]     <= pwdata[0];   // scriem in registrul de stare
                2'd2: begin
                    spdr_tx      <= pwdata;        // scriem data de trimis
                    transfer_req <= 1;             // declanseaza transferul SPI
                end
            endcase
    end

// citire registre interne → APB
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        prdata <= {REGISTER_WIDTH{1'b0}};
    else if (psel && !penable && !pwrite) // faza SETUP, citire
        case (paddr)
            2'd0: prdata <= spcr;    // citim registrul de control
            2'd1: prdata <= spsr;    // citim registrul de stare
            2'd2: prdata <= spdr_rx; // citim datele primite de la Arduino
        endcase

// pready
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        pready <= 1'b0;
    else if (psel && !penable) // faza SETUP => pregatim raspunsul
        pready <= 1'b1;
    else
        pready <= 1'b0;

// Impartitor de frecventa
// 100MHz / (2 x CLK_DIV) = 1MHz SCK
localparam CLK_DIV = 50;

reg [5:0] clk_cnt; // numarator pana la 50
reg       tick;    // puls de 1 ciclu la fiecare jumatate de perioada SCK

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_cnt <= 0;
        tick    <= 0;
    end else begin
        tick <= 0;
        if (clk_cnt == CLK_DIV - 1) begin
            clk_cnt <= 0;
            tick    <= 1; // puls la fiecare 50 cicluri
        end else
            clk_cnt <= clk_cnt + 1;
    end
end

// SPI State Machine 
localparam S_IDLE     = 3'd0;
localparam S_CS_LOW   = 3'd1;
localparam S_SHIFT    = 3'd2;
localparam S_CS_HIGH  = 3'd3;
localparam S_DONE     = 3'd4;

reg [2:0] state;

reg [3:0] tick_cnt;  // numara tick-urile in SHIFT (0-15, 2 tick-uri per bit)
reg [7:0] shift_tx;  // copia lui spdr_tx, shiftata pe masura transferului
reg [7:0] shift_rx;  // acumuleaza bitii primiti pe MISO

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state    <= S_IDLE;
        spi_ss_n <= {NO_OF_SLAVES{1'b1}}; // SS_N = 1 (dezactivat)
        spi_clk  <= 1'b0;
        spi_mosi <= 1'b0;
        tick_cnt <= 0;
        shift_tx <= 0;
        shift_rx <= 0;
        spsr[7]  <= 0; // SPIF = 0
        spdr_rx  <= 0;
    end else begin
        case (state)

            S_IDLE: begin
                spi_ss_n <= {NO_OF_SLAVES{1'b1}};
                spi_clk  <= 1'b0;
                if (spcr[7] && transfer_req) begin
                    shift_tx <= spdr_tx;
                    shift_rx <= 0;
                    tick_cnt <= 0;
                    state    <= S_CS_LOW;
                 end
            end

            S_CS_LOW: begin
                spi_ss_n <= {NO_OF_SLAVES{1'b0}}; // selectam Arduino
                if (tick) begin
                    spi_mosi <= shift_tx[7]; // punem primul bit pe MOSI
                    state    <= S_SHIFT;
                end
            end

            S_SHIFT: begin
                if (tick) begin
                    if (!tick_cnt[0]) begin
                        // tick par => SCK = 0, punem urmatorul bit
                        spi_clk  <= 1'b0;
                        spi_mosi <= shift_tx[6];
                        shift_tx <= {shift_tx[6:0], 1'b0}; // shiftam stanga
                    end else begin
                        // tick impar => SCK = 1, citim MISO
                        spi_clk  <= 1'b1;
                        shift_rx <= {shift_rx[6:0], spi_miso}; // shiftam MISO in RX
                    end
                    tick_cnt <= tick_cnt + 1;
                    if (tick_cnt == 4'd15)
                        state <= S_CS_HIGH;
                end
            end

            S_CS_HIGH: begin
                spi_clk  <= 1'b0;
                spi_ss_n <= {NO_OF_SLAVES{1'b1}}; // eliberam Arduino
                if (tick)
                    state <= S_DONE;
            end

            S_DONE: begin
                spdr_rx <= shift_rx; // salvam datele primite
                spsr[7] <= 1'b1;     // SPIF = 1 => transfer complet
                state   <= S_IDLE;
            end

        endcase
    end
end

endmodule