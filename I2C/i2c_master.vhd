
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


    type I2C_MASTER_IN is record
        start      : std_logic;
        rw         : std_logic;
        slv_addr   : std_logic_vector(6 downto 0);
        ptr        : std_logic_vector(7 downto 0);
        data_len   : std_logic_vector(C_LOG2_MAX_DATA_BYTES downto 0);
        data_in    : std_logic_vector(C_MAX_DATA_BYTES*8-1 downto 0);
    end record;
    type I2C_MASTER_OUT is record
        done        : std_logic;
        data_err    : std_logic;
        data_out    : std_logic_vector(C_MAX_DATA_BYTES*8-1 downto 0);
    end record;
    


use work.pivt_pkg.all;

entity i2c_master is
generic (
    G_INST_IOBUF         : boolean := false;
    G_RTL_CLK_FREQ        : integer := 50_000_000;  -- Default value
    G_MAX_DATA_BYTES      : integer := 3;  -- Default value
    G_LOG2_MAX_DATA_BYTES : integer := 2  -- Default value
);
    Port (
        clk_i                : in  std_logic;     -- system clock (e.g. 50MHz)
        arstn_i              : in  std_logic;     -- reset signal
        
        i2c_master_i         : in  I2C_MASTER_IN;
        i2c_master_o         : out I2C_MASTER_OUT;
        
        
        --state_debug          : out std_logic_vector(7 downto 0);
        --state2_debug         : out std_logic_vector(15 downto 0);
        -- i2c ports
        SDA_IO               : inout std_logic;
        SCL_O                : out   std_logic
        
    );
end i2c_master;

architecture Behavioral of i2c_master is

		type data_byte_array is array (0 to G_MAX_DATA_BYTES-1) of std_logic_vector(7 downto 0);
		
    
     -- config
     signal   start_i              : std_logic := '0';     -- start transmission
     signal   rw_i                 : std_logic := '0';     -- 0: write, 1: read
     signal   slv_addr_i           : std_logic_vector(6 downto 0) := (others => '0'); -- 7-bit slave address
     signal   ptr_i                : std_logic_vector(7 downto 0) := (others => '0'); -- 8-bit register address
     signal   data_len_i           : std_logic_vector(G_LOG2_MAX_DATA_BYTES downto 0) := (others => '0'); -- total bytes to send or receive
        -- data
    signal data_in_bytes           : data_byte_array; -- data to be written
        
    signal data_out_bytes         : data_byte_array; -- data read
    signal   done_o               : std_logic;
    signal   data_err_o           : std_logic;
        
        
    
    

    constant  C_I2C_CLK_FREQ        : integer := 400_000;  -- Default value
    constant  C_CLK_TLOW_PC         : integer := 60;  -- Default value
    constant  C_CLK_THIGH_PC        : integer := 40;  -- Default value
      
      
    signal    start_i2cm      : std_logic := '0';     -- start transmission
    signal    ptr_only_i2cm   : std_logic := '0';
    signal    data_err_i2cm   : std_logic := '0';
    signal    done_i2cm       : std_logic := '0';
        
        
    signal trx_restart_net : std_logic := '0';
    
    
    
    signal neg_clk_edge     : std_logic := '0';
    signal pos_clk_edge     : std_logic := '0';
    signal data_clk_edge    : std_logic := '0';

    signal SDA_I		:  std_logic := '0';
    signal SDA_O		:  std_logic := '0';
    signal SDA_T		:  std_logic := '1';   -- 0: output, 1: input
		

    -- Declare the IOBUF instance
    component IOBUF
        Port (
            I  : in    std_logic;     -- Data input to the buffer
            O  : out   std_logic;     -- Data output from the buffer
            T  : in    std_logic;     -- Tri-state control (Active high to enable output)
            IO : inout std_logic      -- Bidirectional I/O
        );
    end component;
    
    
    ---------------------------------------------------------------
    ------------- Start of Signals for I2C Master -----------------
    ---------------------------------------------------------------
    
        signal bit_cnt  : integer range 0 to 7 := 0;
        signal byte_cnt : integer range 0 to G_MAX_DATA_BYTES := 0;
        signal last_byte : std_logic := '0';
        
        type state_type is (S_IDLE, S_START, S_START_HOLD, S_SETUP_CLK, S_ADDR_RW, S_RW_BIT, S_SLV_ADDR_ACK, S_PTR_WRITE, S_WAIT_ACK_PTR_WR, S_DATA_WRITE, S_WAIT_ACK_DATA_WR, S_DATA_READ, S_SEND_ACK_DATA_RD, S_STOP, S_STOP_HOLD, S_IDLE_HOLD); --, S_DONE);
        signal state : state_type := S_IDLE;

        signal data_out_reg    : std_logic_vector(G_MAX_DATA_BYTES*8-1 downto 0); -- data to be written
    
    signal curr_data_byte_reg  : std_logic_vector(7 downto 0);  -- to store currently being processed byte
    
	   signal SDA_IN     : std_logic     := '0';
	   signal SDA_OUT    : std_logic     := '1';
	   signal SDA_DIR    : std_logic     := '1';     -- 0: output, 1: input
	   
       --signal state_debug_reg     : std_logic_vector(7 downto 0);
       --signal substate_debug_reg  : std_logic_vector(7 downto 0);
    ---------------------------------------------------------------
    ------------- End of Signals for I2C Master -------------------
    ---------------------------------------------------------------
     
    
    ---------------------------------------------------------------
    ------------- Start of Signals for Iterator -------------------
    ---------------------------------------------------------------
    type state_iter_type is (S_IDLE, S_WAIT_PTR_WR, S_WAIT_DONE, S_ADDR);--,  S_DONE);
    signal state_iter : state_iter_type := S_IDLE;
    signal start_p1               : std_logic := '0';
    signal rw_i2cm                : std_logic := '0';     -- 0: write, 1: read   
    --signal state_debug_iter_reg   : std_logic_vector(7 downto 0) := (others => '0');
    ---------------------------------------------------------------
    ------------- End of Signals for Iterator ---------------------
    ---------------------------------------------------------------

begin
    start_i       <= i2c_master_i.start     ;
    rw_i          <= i2c_master_i.rw        ;
    slv_addr_i    <= i2c_master_i.slv_addr  ;
    ptr_i         <= i2c_master_i.ptr       ;
    data_len_i    <= i2c_master_i.data_len  ;
		gen_data_in_bytes : for i in 0 to G_MAX_DATA_BYTES-1 generate
		begin
			data_in_bytes(i) <= i2c_master_i.data_in(8*i+7 downto 8*i);
		end generate;


		gen_data_out_bytes : for i in 0 to G_MAX_DATA_BYTES-1 generate
		begin
			i2c_master_o.data_out(8*i+7 downto 8*i) <= data_out_bytes(i);
		end generate;
    i2c_master_o.done      <= done_o    ;
    i2c_master_o.data_err  <= data_err_o;

    
		
		
    
    
    
    
    feature_unselect : if G_INST_IOBUF generate
    begin
    -- Instantiate IOT_to_IO
    IOBUF_inst_sda : IOBUF
        Port map (
            I   => SDA_I,         -- Input signal to IOBUF
            O   => SDA_O,         -- Output signal from IOBUF
            T   => SDA_T,         -- Control the buffer direction (0 means output enabled)
            IO  => SDA_IO         -- I/O pin connection
        );
		end generate;
		
    feature_select2 : if not G_INST_IOBUF generate
    begin
		SDA_IO <= SDA_I when SDA_T='0' else 'Z';
		SDA_O <= SDA_IO;
		end generate;
    
    PROC_I2C_CLK_GEN : process(clk_i, arstn_i)
        constant C_CLK_PERIOD  : integer := G_RTL_CLK_FREQ/C_I2C_CLK_FREQ;
        constant C_CLK_TLOW    : integer := (C_CLK_PERIOD * C_CLK_TLOW_PC)/100;    --  60% of C_CLK_PERIOD
        constant C_CLK_THIGH   : integer := (C_CLK_PERIOD * C_CLK_THIGH_PC)/100;   --  40% of C_CLK_PERIOD
        constant C_CLK_SETDATA : integer := C_CLK_TLOW/2;            --  % of C_CLK_PERIOD
        variable clk_cnt     : integer range 0 to C_CLK_PERIOD - 1 := 0;
    begin
        if arstn_i = '0' then
            clk_cnt := 0;
            neg_clk_edge    <= '0';
            pos_clk_edge    <= '0';
            data_clk_edge   <= '0';
        elsif rising_edge(clk_i) then
            neg_clk_edge  <= '0';
            pos_clk_edge  <= '0';
            data_clk_edge <= '0';
            if clk_cnt = C_CLK_PERIOD - 1 then
                clk_cnt := 0;
                neg_clk_edge  <= '1';
            elsif clk_cnt = C_CLK_SETDATA - 1 then
                data_clk_edge  <= '1';
                clk_cnt := clk_cnt + 1;
            elsif clk_cnt = C_CLK_TLOW - 1 then
                pos_clk_edge  <= '1';
                clk_cnt := clk_cnt + 1;
            else
                clk_cnt := clk_cnt + 1;
            end if;
        end if;
       
    end process PROC_I2C_CLK_GEN;
    

    PROS_I2C_MASTER_ITER: process(clk_i, arstn_i)
    begin
      if arstn_i = '0' then
        state_iter   <= S_IDLE;
        --state_debug_iter_reg  <= x"00";
        start_i2cm <= '0';
        start_p1 <= '0';
        done_o <= '0';
        ptr_only_i2cm <= '0';
      elsif rising_edge(clk_i) then
        start_p1 <= start_i;
        done_o <= '0';
        start_i2cm <= '0';
        case state_iter is
          when S_IDLE =>
            --state_debug_iter_reg  <= x"01";
            if start_i = '1' and start_p1 = '0' then  -- positive edge detection
              start_i2cm <= '1';
              data_err_o <= '0';
              if rw_i = '1' then
                trx_restart_net <= '1';
                rw_i2cm        <= '0';  -- 0: write, 1: read
                ptr_only_i2cm <= '1';    -- 0 data registers to be written, only ptr reg will be written
                state_iter <= S_WAIT_PTR_WR;
              else
                trx_restart_net <= '0';
                rw_i2cm          <= rw_i;  -- 0: write, 1: read
                state_iter <= S_WAIT_DONE;
              end if;
            end if;
              
          when S_WAIT_PTR_WR =>
            --state_debug_iter_reg  <= x"02";
            if done_i2cm = '1' then
              if data_err_i2cm = '1' then
                data_err_o <= '1';
                done_o <= '1';
                state_iter <= S_IDLE;
              else
                rw_i2cm          <= '1';  -- 0: write, 1: read
                start_i2cm <= '1';
                trx_restart_net <= '0';
                state_iter <= S_WAIT_DONE;
              end if;
            end if;
               
          when S_WAIT_DONE =>
            --state_debug_iter_reg  <= x"ad";
            if done_i2cm = '1' then
              if data_err_i2cm = '1' then
                data_err_o <= '1';
              end if;
              done_o <= '1';
              state_iter <= S_IDLE;
            end if;
            
          when others =>
            state_iter <= S_IDLE; -- go to reset and then to IDLE
        end case;
      end if;
              
      
      --state_debug <= state_debug_iter_reg;
        
    end process PROS_I2C_MASTER_ITER;



    PROC_I2C_MASTER_FSM: process(clk_i, arstn_i)
    
    begin
        if arstn_i = '0' then
            state   <= S_IDLE;
            SCL_O        <= '1';
            SDA_DIR      <= '1';
            SDA_OUT      <= '1';
            done_i2cm    <= '0';
            last_byte    <= '0';
            data_err_i2cm <= '0';
            byte_cnt     <= 0;
            bit_cnt      <= 0;
            --state_debug_reg <= x"00";
            --substate_debug_reg <= x"00";
            SDA_IN <= '0';
        elsif rising_edge(clk_i) then
          SDA_IN <= SDA_O;
          done_i2cm <= '0';
          case state is
            when S_IDLE =>
              --state_debug_reg <= x"01";
              if start_i2cm = '1' then  -- detect positive edge
                  state <= S_START;
                  data_err_i2cm <= '0';
                  byte_cnt <= to_integer(unsigned(data_len_i))-1;
                  --substate_debug_reg <= x"01";
              end if;
              --substate_debug_reg <= x"00";

            when S_START =>     -- transmit start condition
              --state_debug_reg <= x"02";
              --substate_debug_reg <= x"00";
              if data_clk_edge = '1' then
                if SDA_IN = '0' then		-- error if SDA is already low
                  state <= S_STOP;
                  data_err_i2cm <= '1';
                  --substate_debug_reg <= x"01";
                else
                  --substate_debug_reg <= x"02";
                  SDA_DIR   <= '0';       -- start condition
                  SDA_OUT   <= '0';
                end if;
              elsif pos_clk_edge = '1' and SDA_OUT = '0' then 
                state <= S_ADDR_RW;
                
                curr_data_byte_reg <= slv_addr_i & rw_i2cm;
                --substate_debug_reg <= x"03";
              end if;
              
            when S_ADDR_RW =>      -- transmit address (7bits)
                --state_debug_reg <= x"04";
                --substate_debug_reg <= x"00";
                if data_clk_edge = '1' then
                  SDA_DIR <= '0';
                  SDA_OUT   <= curr_data_byte_reg(7);
                  curr_data_byte_reg <= curr_data_byte_reg(6 downto 0) & '0';
                  --substate_debug_reg <= x"02";
                elsif pos_clk_edge = '1' then   -- assert clock to feed data to slave, and change state
                  --SCL_O   <= '1';
                  if bit_cnt = 7 then
                      bit_cnt <= 0;
                      state <= S_SLV_ADDR_ACK;
                      --substate_debug_reg <= x"04";
                  else
                      bit_cnt <= bit_cnt + 1;
                      --substate_debug_reg <= x"03";
                  end if;
                end if;
                
            when S_SLV_ADDR_ACK =>      --  ack of address transmission
              --state_debug_reg <= x"06";
              --substate_debug_reg <= x"00";
              if neg_clk_edge = '1' then  -- setup data
                --SCL_O   <= '0';
                SDA_DIR   <= '1';
                SDA_OUT   <= '1';
                --substate_debug_reg <= x"01";
              elsif pos_clk_edge = '1' then   -- assert clock to read ack from slave, and change state
                if SDA_IN = '1' then
                  state <= S_STOP;
                  data_err_i2cm <= '1';
                  --substate_debug_reg <= x"02";
                else
                  if rw_i2cm = '0' then
                    state <= S_PTR_WRITE;   -- first set pointer then go for writing the data (if data_len != 0)
                    curr_data_byte_reg <= ptr_i;
                    --substate_debug_reg <= x"03";
                  elsif rw_i2cm = '1' then
                    state <= S_DATA_READ;   -- dont go for setting the pointer directly go for reading the data (if data_len != 0) from the reg addr previously set
                    --substate_debug_reg <= x"04";
                  end if;
                end if;
              end if;
              
            when S_PTR_WRITE =>
              --state_debug_reg <= x"07";
              --substate_debug_reg <= x"00";
              if data_clk_edge = '1' then
                SDA_DIR <= '0';
                SDA_OUT   <= curr_data_byte_reg(7);
                curr_data_byte_reg <= curr_data_byte_reg(6 downto 0) & '0';
                --substate_debug_reg <= x"02";
              elsif pos_clk_edge = '1' then   -- assert clock to feed data to slave, and change state
                if bit_cnt = 7 then
                    bit_cnt <= 0;
                    state <= S_WAIT_ACK_PTR_WR;
                    --substate_debug_reg <= x"04";
                else
                    bit_cnt <= bit_cnt + 1;
                    --substate_debug_reg <= x"03";
                end if;
              end if;
                
            when S_WAIT_ACK_PTR_WR =>      --  ack of data byte transmission 
              --state_debug_reg <= x"08";
              --substate_debug_reg <= x"00";
              if neg_clk_edge = '1' then  -- setup data
                SDA_DIR   <= '1';
                SDA_OUT   <= '1';
                --substate_debug_reg <= x"01";
              elsif pos_clk_edge = '1' then   -- assert clock to read ack from slave, and change state
                if SDA_IN = '1' then
                  state <= S_STOP;
                  data_err_i2cm <= '1';
                  --substate_debug_reg <= x"04";
                else
                  if rw_i2cm = '1' then
                    state <= S_DATA_READ;
                    --substate_debug_reg <= x"03";
                  else
                    state <= S_DATA_WRITE;
                    curr_data_byte_reg <= data_in_bytes(byte_cnt);
                    --substate_debug_reg <= x"02";
                  end if;
                end if;
              end if;
                                    
            when S_DATA_WRITE =>
              --state_debug_reg <= x"09";
              --substate_debug_reg <= x"00";
              if ptr_only_i2cm = '1' then
                state <= S_STOP;
                --substate_debug_reg <= x"06";
              else
                if data_clk_edge = '1' then
                  SDA_DIR <= '0';
                  SDA_OUT   <= curr_data_byte_reg(7);
                  curr_data_byte_reg <= curr_data_byte_reg(6 downto 0) & '0';
                  --substate_debug_reg <= x"02";
                elsif pos_clk_edge = '1' then
                  if bit_cnt = 7 then
                    bit_cnt <= 0;
                    state <= S_WAIT_ACK_DATA_WR;
                    --if byte_cnt = data_len_i2cm-1 then
                    if byte_cnt = 0 then
                      last_byte <= '1';
                      --substate_debug_reg <= x"05";
                    else
                      byte_cnt <= byte_cnt - 1;
                      --substate_debug_reg <= x"04";
                    end if;
                  else
                    bit_cnt <= bit_cnt + 1;
                    --substate_debug_reg <= x"03";
                  end if;
                end if;
              end if;
                    
            when S_WAIT_ACK_DATA_WR =>      --  ack of data byte transmission
              --state_debug_reg <= x"0a";
              --substate_debug_reg <= x"00";
              if neg_clk_edge = '1' then  -- setup data
                SDA_DIR   <= '1';
                SDA_OUT   <= '1';
                --substate_debug_reg <= x"01";
              elsif pos_clk_edge = '1' then   -- assert clock to read ack from slave, and change state
                if SDA_IN = '1' then
                  state <= S_STOP;
                  data_err_i2cm <= '1';
                  --substate_debug_reg <= x"04";
                else
                  if last_byte = '1' then
                    state <= S_STOP;
                    --substate_debug_reg <= x"03";
                  else
                    state <= S_DATA_WRITE;
                    curr_data_byte_reg <= data_in_bytes(byte_cnt);
                    --substate_debug_reg <= x"02";
                  end if;
                end if;
              end if;
                
            when S_DATA_READ =>
              --state_debug_reg <= x"0b";
              --substate_debug_reg <= x"00";
              if to_integer(unsigned(data_len_i)) = 0 then
                state <= S_STOP;
                --substate_debug_reg <= x"00";
              else
                if neg_clk_edge = '1' then  -- setup data pin direction to read
                  SDA_DIR   <= '1';
                  SDA_OUT   <= '1';
                  --substate_debug_reg <= x"01";
                elsif pos_clk_edge = '1' then   -- assert clock to read data from slave, and change state
                  --SCL_O   <= '1';
                  curr_data_byte_reg <= curr_data_byte_reg(6 downto 0) & SDA_IN;
                  if bit_cnt = 7 then
                    bit_cnt <= 0;
                    state <= S_SEND_ACK_DATA_RD;
                  else
                    bit_cnt <= bit_cnt + 1;
                    --substate_debug_reg <= x"02";
                  end if;
                end if;
              end if;
                 
              when S_SEND_ACK_DATA_RD =>
                --state_debug_reg <= x"0d";
                --substate_debug_reg <= x"00";
                if (neg_clk_edge = '1') then
                  data_out_bytes(byte_cnt) <= curr_data_byte_reg;
                  if byte_cnt = 0 then
                      last_byte <= '1';
                      --substate_debug_reg <= x"04";
                  else
                      byte_cnt <= byte_cnt - 1;
                      --substate_debug_reg <= x"03";
                  end if;
                  --substate_debug_reg <= x"01";
                elsif data_clk_edge = '1' then
                  if last_byte = '1' then
                    SDA_OUT <= '1';
                    SDA_DIR <= '1';     -- 0: output, 1: input
                    --substate_debug_reg <= x"03";
                  else
                    SDA_OUT <= '0';
                    SDA_DIR <= '0';     -- 0: output, 1: input
                    --substate_debug_reg <= x"02";
                  end if;
                elsif pos_clk_edge = '1' then
                  if SDA_IN = '1' then
                      state <= S_STOP;
                      --substate_debug_reg <= x"05";
                  else
                      state <= S_DATA_READ;
                      --substate_debug_reg <= x"04";
                  end if;
                end if;
                
            when S_STOP =>  -- wr good
              --state_debug_reg <= x"0e";
              --substate_debug_reg <= x"00";
              if data_clk_edge = '1' then
                if trx_restart_net = '1' then
                  SDA_DIR <= '1';
                  SDA_OUT <= '1';
                else
                  SDA_DIR <= '0';
                  SDA_OUT <= '0';
                end if;
              elsif pos_clk_edge = '1'then  -- 0: write, 1: read
                  state <= S_STOP_HOLD;
              end if;
                
            when S_STOP_HOLD =>
              --state_debug_reg <= x"0f";
              --substate_debug_reg <= x"00";
              if data_clk_edge = '1' then
                SDA_DIR <= '1';     -- stop condition if trx_restart_net = '0'
                SDA_OUT <= '1';
              elsif pos_clk_edge = '1'then  -- 0: write, 1: read
                --SCL_O <= '1';
                state <= S_IDLE_HOLD;
              end if;
                
            when S_IDLE_HOLD =>
              --state_debug_reg <= x"10";
              --substate_debug_reg <= x"00";
              if neg_clk_edge = '1' then
                done_i2cm <= '1';
                last_byte <= '0';
                state <= S_IDLE;
              end if;

            when others =>
                state <= S_IDLE; -- go to reset and then to IDLE

          end case;
          
          if neg_clk_edge = '1' then
            if (trx_restart_net = '0' and state = S_STOP_HOLD) or (state = S_IDLE_HOLD) then
              SCL_O <= '1';
            else
              SCL_O <= '0';
            end if;
          elsif pos_clk_edge = '1'then
            SCL_O <= '1';
          end if;
        end if;  -- end of rising edge  clk
        
        SDA_T <= SDA_OUT;   -- 0: output, 1: input
        SDA_I <= '0';
        
        --state2_debug <= state_debug_reg & substate_debug_reg;
    
    end process PROC_I2C_MASTER_FSM;




end Behavioral;


































