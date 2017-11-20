////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2017, Matt Dew
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
/*! \class axi_seq
 *  \brief Writes to memory over AXI, backdoor readback, then AXI readback
 *
 *  miscompares are flagged.
 */
class axi_seq extends uvm_sequence #(axi_seq_item);

  `uvm_object_utils(axi_seq)

  const int axi_readback  = 1;
  const int clearmemory   = 1;
  const int postcheck     = 1;
  const int precheck      = 1;
  const int window_size   = 'h1000;
  int xfers_to_send = 1;

  bit valid [];

  const int pipelined_bursts_enabled=0;

  bit [2:0] max_burst_size;


  int xfers_done=0;

  memory m_memory;

  axi_seq_item write_item [];
  axi_seq_item read_item  [];

  // all write responses have been received
  // Reads can go ahead
  event writes_done;


  extern function   new (string name="axi_seq");
  extern task       body;
  extern function void response_handler(uvm_sequence_item response);

  extern function void set_transaction_count(int count);
  extern function void set_valid(ref bit valid []);


  extern function bit compare_items (ref axi_seq_item write_item, ref axi_seq_item read_item);
  extern function bit check_memory(ref axi_seq_item item,
                                   input bit [ADDR_WIDTH-1:0] lower_addr,
                                   input bit [ADDR_WIDTH-1:0] upper_addr);

endclass : axi_seq


// This response_handler function is enabled to keep the sequence response FIFO empty
function void axi_seq::response_handler(uvm_sequence_item response);

axi_seq_item item;
int xfer_cnt;

$cast(item,response);

$cast(read_item[item.id], item.clone);
xfer_cnt=item.id;
 if (item.cmd== e_WRITE_RESPONSE) begin
   xfers_done++;

  if (xfers_done >= xfers_to_send) begin
     `uvm_info("axi_seq::response_handler::sending event ",
               $sformatf("xfers_done:%0d  xfers_to_send: %0d  sending event",
                         xfers_done, xfers_to_send),
               UVM_INFO)
    ->writes_done;
  end

end
  `uvm_info(this.get_type_name(), $sformatf("SEQ_response_handler xfers_done=%0d.   Item: %s",xfers_done, item.convert2string()), UVM_INFO)


 if (item.cmd== e_READ_DATA) begin

    `uvm_info("axi_seq::response_handler::READBACK COMPARE",
              $sformatf("Now comparing axi write transfer %0d with axi read transfer %0d", xfer_cnt, xfer_cnt),
              UVM_INFO)
    assert (compare_items (.write_item (write_item[xfer_cnt]),
                           .read_item  (item)));
   end


endfunction: response_handler

/*! \brief Constructor
 *
 * Doesn't actually do anything except call parent constructor
 */
function axi_seq::new (string name="axi_seq");
  super.new(name);
endfunction : new


/*! \brief How many transactions?
 *
 * This method sets how many transactions to send
 * (Write Address, Write Data, Write Response) is one traction
 * (Read Address, Read Data) is one transaction
 */
function void axi_seq::set_transaction_count(int count);
  xfers_to_send = count;
endfunction : set_transaction_count



function void axi_seq::set_valid(ref bit valid []);
  this.valid=new[valid.size()](valid);

endfunction : set_valid

/*! \brief Does all the work.
 *
 * -# Creates constrained random AXI write packet
 * -# Sends it
 * -# Backdoor read of memory to verify correctly written
 * -# Creates constrained random AXI read packet with same len and address as write packet
 * -# Sends it
 * -# Verifies read back data with written data.
 *
 *  two modes:
 *     Serial, Write_addr,  then write, then resp.  Repeat
 *     Parallel - Multiple write_adr, then multiple write_data, then multiple  resp, repeat
 */
task axi_seq::body;

  string s;
  bit [7:0] read_data;
  bit [7:0] expected_data;



  bit [ADDR_WIDTH-1:0] Lower_Wrap_Boundary;
  bit [ADDR_WIDTH-1:0] Upper_Wrap_Boundary;
  bit [ADDR_WIDTH-1:0] iaddr;
  bit [ADDR_WIDTH-1:0] addr_lo;
  bit [ADDR_WIDTH-1:0] addr_hi;

  int idatacntr;
  int miscompare_cntr;
  string write_item_s;
  string read_item_s;
  string expected_data_s;
  string msg_s;
  string localbuffer_s;
  int rollover_cnt;
  bit [ID_WIDTH-1:0] xid;

  bit [7:0] expected_data_array [];

  bit [2:0] max_burst_size;
  int yy;
  bit [7:0] localbuffer [];

  xfers_done=0;

  write_item = new [xfers_to_send];
  read_item  = new [xfers_to_send];


  use_response_handler(pipelined_bursts_enabled); // Enable Response Handler

  if (!uvm_config_db #(memory)::get(null, "", "m_memory", m_memory)) begin
    `uvm_fatal(this.get_type_name(),
               "Unable to fetch m_memory from config db. Using defaults")
    end

  // Clear memory
  // AXI write
  // direct readback of memory
  //  check that addresses before Axi start address are still 0
  //  chck expected data
  //  check that addresses after axi start_addres+length are still 0


  //if (valid.size() == 0) begin
 //   valid = new[1];
 //   valid[0] = 1'b1;
 // end

  for (int xfer_cnt=0;xfer_cnt<xfers_to_send;xfer_cnt++) begin

    // clear memory
    if (clearmemory==1) begin
       for (int i=0;i<window_size;i++) begin
          m_memory.write(i, 'h0);
       end
    end

    write_item[xfer_cnt] = axi_seq_item::type_id::create("write_item");
    read_item[xfer_cnt]  = axi_seq_item::type_id::create("read_item");


    // Not sure why I have to define and set these and
    // then use them in the randomize with {} but
    // Riviera Pro works better like this.
    addr_lo=xfer_cnt*window_size;
    addr_hi=addr_lo+'h100;
    xid =xfer_cnt[ID_WIDTH-1:0];
    start_item(write_item[xfer_cnt]);

    `uvm_info(this.get_type_name(),
              $sformatf("item %0d id:0x%0x addr_lo: 0x%0x  addr_hi: 0x%0x",
                        xfer_cnt, xid, addr_lo,addr_hi),
              UVM_INFO)


    assert( write_item[xfer_cnt].randomize() with {
                                         cmd        == e_WRITE;
                                         burst_size <= local::max_burst_size;
                                         id         == local::xid;
                                         addr       >= local::addr_lo;
                                         addr       <  local::addr_hi;
    })

    `uvm_info("DATA", $sformatf("\n\n\nItem %0d:  %s", xfer_cnt, write_item[xfer_cnt].convert2string()), UVM_INFO)
    finish_item(write_item[xfer_cnt]);

    if (!pipelined_bursts_enabled) begin
       get_response(write_item[xfer_cnt]);

      if (!check_memory(.item       (write_item[xfer_cnt]),
                        .lower_addr (xfer_cnt*window_size),
                        .upper_addr ((xfer_cnt+1)*window_size))) begin
        `uvm_info("MISCOMPARE","Miscompare error", UVM_INFO)
      end

    end
  end  //for

  //#2us
  // wait for all
    if (pipelined_bursts_enabled) begin
       `uvm_info("READBACK", "writes done. waiting for event trigger", UVM_INFO)
       wait (writes_done.triggered);
       `uvm_info("READBACK", "event trigger detected1111", UVM_INFO)

    end
  // \todo: setup so read memm and axireadback don't commense until write
  // response is received.
  //

  //use_response_handler(0); // Enable Response Handler
if (axi_readback==1) begin

    // Now AXI readback
    `uvm_info("READBACK", "Now READING BACK via AXI", UVM_INFO)

  for (int xfer_cnt=0;xfer_cnt<xfers_to_send;xfer_cnt++) begin

    `uvm_info("...", "Now reading back from memory to verify - DONE", UVM_LOW)

    start_item(read_item[xfer_cnt]);
    assert( read_item[xfer_cnt].randomize() with {protocol   == write_item[xfer_cnt].protocol;
                                                  cmd        == e_READ;
                                                  burst_size == write_item[xfer_cnt].burst_size;
                                                  id         == write_item[xfer_cnt].id;
                                                  burst_type == write_item[xfer_cnt].burst_type;
                                                  addr       == write_item[xfer_cnt].addr;
                                                  len        == write_item[xfer_cnt].len;}
                                                                          ) else begin
         `uvm_error(this.get_type_name(),
                    $sformatf("Unable to randomize %s",  read_item[xfer_cnt].get_full_name()));
         end  //assert


    finish_item(read_item[xfer_cnt]);

    if (pipelined_bursts_enabled != 1) begin
       get_response(read_item[xfer_cnt]);   //response_handler above deals with this
    end

    `uvm_info(this.get_type_name(),
              $sformatf("GOT RESPONSE. item=%s", read_item[xfer_cnt].convert2string()),
              UVM_INFO)
  end

 //   `uvm_info("...", "Now comparing AXI readback to AXI write data", UVM_INFO)
  //for (int xfer_cnt=0;xfer_cnt<xfers_to_send;xfer_cnt++) begin
    //`uvm_info("READBACK COMPARE", $sformatf("Now comparing axi write  transfer %0d with axi read transfer %0d", xfer_cnt, xfer_cnt), UVM_INFO)
     //compare_items (.xfer_cnt(xfer_cnt));
  //end  //for

end // if axi_readback=1

    `uvm_info("..", "...", UVM_HIGH)


  #10us

  `uvm_info(this.get_type_name(), "SEQ ALL DONE", UVM_INFO)

endtask : body


function automatic bit axi_seq::check_memory(
                ref axi_seq_item item,
                input bit [ADDR_WIDTH-1:0] lower_addr,
                input bit [ADDR_WIDTH-1:0] upper_addr);


  int max_beat_cnt;
  int dtsize;

  bit [ADDR_WIDTH-1:0] Lower_Wrap_Boundary;
  bit [ADDR_WIDTH-1:0] Upper_Wrap_Boundary;
  bit [ADDR_WIDTH-1:0] iaddr;

  bit [ADDR_WIDTH-1:0]  pre_check_start_addr;
  bit [ADDR_WIDTH-1:0]  pre_check_stop_addr;

  bit [ADDR_WIDTH-1:0]  check_start_addr;
  bit [ADDR_WIDTH-1:0]  check_stop_addr;

  bit [ADDR_WIDTH-1:0]  post_check_start_addr;
  bit [ADDR_WIDTH-1:0]  post_check_stop_addr;


 //  string write_item_s;
  int idatacntr;
  int miscompare_cntr;
  string write_item_s;
  string read_item_s;
  string expected_data_s;
  string actual_data_s;
  string msg_s;
  string localbuffer_s;
  int rollover_cnt;

  bit [7:0] expected_data_array [];
  bit [7:0] actual_data_array [];

  bit [2:0] max_burst_size;
  int yy;
  bit [7:0] localbuffer [];
  bit [7:0] read_data;
  bit [7:0] expected_data;


  assert (item != null);

  if (item == null) begin
    `uvm_fatal(this.get_type_name(), "Item is null")
  end




    //***** Readback
    `uvm_info("...", "Now reading back from memory to verify", UVM_LOW)


    if (item.burst_type == e_WRAP) begin


      max_beat_cnt = axi_pkg::calculate_axlen(.addr(item.addr),
                                              .burst_size(item.burst_size),
                                              .burst_length(item.len)) + 1;

      dtsize = (2**item.burst_size) * max_beat_cnt;

      Lower_Wrap_Boundary = (int'(item.addr/dtsize) * dtsize);
      Upper_Wrap_Boundary = Lower_Wrap_Boundary + dtsize;

      pre_check_start_addr  = lower_addr;
      pre_check_stop_addr   = Lower_Wrap_Boundary;

      check_start_addr      = Lower_Wrap_Boundary;
      check_stop_addr       = Upper_Wrap_Boundary;

      post_check_start_addr = Upper_Wrap_Boundary;
      post_check_stop_addr  = upper_addr;

    end else begin
       pre_check_start_addr=lower_addr;
       pre_check_stop_addr= item.addr; // only different if burst_type=e_WRAP;

       check_start_addr=item.addr;
       check_stop_addr=item.addr+item.len;

       post_check_start_addr=item.addr+item.len;
       post_check_stop_addr=upper_addr;
    end

    msg_s="";
  $sformat(msg_s, "%s Item: %s",                     msg_s, item.convert2string());
  $sformat(msg_s, "%s pre_check_start_addr: 0x%0x",  msg_s, pre_check_start_addr);
  $sformat(msg_s, "%s pre_check_stop_addr: 0x%0x",   msg_s, pre_check_stop_addr);
  $sformat(msg_s, "%s check_start_addr: 0x%0x",      msg_s, check_start_addr);
  $sformat(msg_s, "%s check_stop_addr: 0x%0x",       msg_s, check_stop_addr);
  $sformat(msg_s, "%s post_check_start_addr: 0x%0x", msg_s, post_check_start_addr);
  $sformat(msg_s, "%s post_check_stop_addr: 0x%0x",  msg_s, post_check_stop_addr);
  $sformat(msg_s, "%s Lower_Wrap_Boundary: 0x%0x",   msg_s, Lower_Wrap_Boundary);
  $sformat(msg_s, "%s Upper_Wrap_Boundary: 0x%0x",   msg_s, Upper_Wrap_Boundary);


    `uvm_info("CHECK MEMORY",
            msg_s,
            UVM_INFO)



     miscompare_cntr=0;

    // compare pre-data
    if (precheck==1) begin
        expected_data='h0;
        for (int i=pre_check_start_addr;i<pre_check_stop_addr;i++) begin
             read_data=m_memory.read(i);
             assert(expected_data==read_data) else begin
                miscompare_cntr++;
                `uvm_error("e_FIXED miscompare",
                           $sformatf("expected: 0x%0x   actual:0x%0x",
                                     expected_data,
                                     read_data))
             end
          end
     end // if precheck

     // compare data
     if (item.burst_type == e_FIXED) begin

       expected_data_array = new[2**item.burst_size];
       actual_data_array   = new[2**item.burst_size];
       localbuffer         = new[2**item.burst_size];
      // brute force, not elegant at all.
      // write to local buffer, then compare that buffer (repeated) with the axi readback


      yy=0;

      for (int y=0;y<localbuffer.size();y++) begin
         localbuffer[y]='h0;
      end
      for (int y=0;y<item.len;y++) begin
        localbuffer[yy++]=item.data[y];
        if (yy >= 2**item.burst_size) begin
          yy=0;
        end
      end

      yy=0;
      for (int y=0; y<expected_data_array.size(); y++) begin
        expected_data_array[y]=localbuffer[yy++];
        if (yy >= localbuffer.size()) begin
          yy=0;
        end
      end
/*
      for (int y=0;y<item.data.size();y++) begin
         expected_data = expected_data_array[y];
         read_data     = m_memory.read(item.addr+y);
        actual_data_array[y] = read_data;
         if (expected_data!=read_data) begin
            miscompare_cntr++;
         end
      end
*/

       // on a fixed burst, we only need to compare last beat of data
       for (int y=0;y<localbuffer.size();y++) begin
          expected_data = expected_data_array[y];
          read_data     = m_memory.read(item.addr+y);
          actual_data_array[y] = read_data;
          if (expected_data!=read_data) begin
             miscompare_cntr++;
          end
       end

     assert (miscompare_cntr==0) else begin
         write_item_s="";
//        read_item_s="";
         expected_data_s="";
         actual_data_s="";
         localbuffer_s="";

         for (int z=0;z<item.data.size();z++) begin
            $sformat(write_item_s, "%s 0x%2x", write_item_s, item.data[z]);
         end


        for (int z=0;z<expected_data_array.size();z++) begin
          $sformat(expected_data_s, "%s 0x%2x", expected_data_s, expected_data_array[z]);
        end

       for (int z=0;z<actual_data_array.size();z++) begin
         $sformat(actual_data_s, "%s 0x%2x", actual_data_s, actual_data_array[z]);
        end

        for (int z=0;z<localbuffer.size();z++) begin
          $sformat(localbuffer_s, "%s 0x%2x", localbuffer_s, localbuffer[z]);
        end

        msg_s="";
       $sformat(msg_s, "%s %0d miscompares between expected and actual data items.", msg_s, miscompare_cntr );
       $sformat(msg_s, "%s \nExpected:    %s", msg_s, expected_data_s);
       $sformat(msg_s, "%s \nActual:      %s", msg_s, actual_data_s);
       $sformat(msg_s, "%s \nWritten:     %s", msg_s, write_item_s);
       $sformat(msg_s, "%s \nLocalbuffer: %s", msg_s, localbuffer_s);

        `uvm_error("READBACK e_FIXED miscompare", msg_s);
      end




     end else if (item.burst_type == e_INCR) begin
       for (int z=0;z<item.len;z++) begin
          expected_data=item.data[z];
         read_data=m_memory.read(item.addr+z);
          //s=$sformatf("%s 0x%0x", s, read_data);
          assert(expected_data==read_data) else begin
                miscompare_cntr++;
            `uvm_error("e_INCR miscompare",
                       $sformatf("addr:0x%0x expected: 0x%0x   actual:0x%0x",
                                  item.addr+z,
                                  expected_data,
                                  read_data))
          end
       end
     end else if (item.burst_type == e_WRAP) begin

       if (item.addr + item.len < Upper_Wrap_Boundary) begin
         expected_data='h0;
         for (int z=Lower_Wrap_Boundary;z<item.addr;z++) begin
           read_data=m_memory.read(z);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
              `uvm_fatal("e_WRAP miscompare",
                       $sformatf("expected: 0x%0x   actual:0x%0x",
                                 expected_data,
                                 read_data))
            end
         end

         for (int z=0;z<item.len;z++) begin
            expected_data=item.data[z];
           read_data=m_memory.read(item.addr+z);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
               `uvm_fatal("e_WRAP miscompare",
                          $sformatf("expected: 0x%0x   actual:0x%0x",
                                    expected_data,
                                    read_data))
            end
         end

         expected_data='h0;
         for (int z=item.addr+item.len;z<Upper_Wrap_Boundary;z++) begin
           read_data=m_memory.read(z);
           assert(expected_data==read_data) else begin
                miscompare_cntr++;
              `uvm_fatal("e_WRAP miscompare",
                       $sformatf("expected: 0x%0x   actual:0x%0x",
                                 expected_data,
                                 read_data))
            end
         end


       end else begin // data actually wraps.

         // compare beginning of data, which is towards the end of the boundary window
         for (int i=item.addr; i<Upper_Wrap_Boundary; i++) begin
            expected_data=item.data[i-item.addr];
            read_data=m_memory.read(i);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
               `uvm_error("e_WRAP miscompare",
                          $sformatf("expected: 0x%0x   actual:0x%0x",
                                    expected_data,
                                    read_data))
            end
         end

         // at which offset did the wrap occur?  compar that starting at lower_wrap_boundary

         rollover_cnt=item.len-((item.addr+item.len)-Upper_Wrap_Boundary);
         for (int i=rollover_cnt;i<item.len;i++) begin
           expected_data=item.data[i];
           read_data=m_memory.read(Lower_Wrap_Boundary+(i-rollover_cnt));
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
              msg_s="";
              for (int j=Lower_Wrap_Boundary;j<Upper_Wrap_Boundary;j++) begin
                $sformat(msg_s, "%s 0x%2x", msg_s, m_memory.read(j));
              end
               `uvm_fatal("e_WRAP miscompare",
                          $sformatf("Wrap Window contents: [0x%0x - 0x%0x]: %s   expected: 0x%0x   actual:[0x%0x]=0x%0x (rollover_cnt: 0x%0x)",
                                    Lower_Wrap_Boundary,
                                    Upper_Wrap_Boundary-1,
                                    msg_s,
                                    expected_data,
                                    Lower_Wrap_Boundary+(i-rollover_cnt),
                                    read_data,
                                    rollover_cnt))
            end
         end

         // `uvm_warning(this.get_type_name(),
         //              "Not currently verifying eWRAP AXi readback data if data actually wraps.")
       end




     end else begin
                miscompare_cntr++;
        `uvm_fatal(this.get_type_name(), $sformatf("Invalid burst_type: %0d", item.burst_type))
     end


      // compare post-data
      if (postcheck==1) begin
         expected_data='h0;
        for (int i=post_check_start_addr;i<post_check_stop_addr;i++) begin
            read_data=m_memory.read(i);
            assert(expected_data==read_data) else begin
                miscompare_cntr++;
               `uvm_error("e_FIXED miscompare",
                          $sformatf("expected: 0x%0x   actual:0x%0x",
                                    expected_data,
                                    read_data))
            end
         end
      end // if postcheck


return (miscompare_cntr == 0);

endfunction : check_memory


// This functionompares thewrite-item withthe correspondingread_item
function bit axi_seq::compare_items (ref axi_seq_item write_item, ref axi_seq_item read_item);

  bit [2:0] max_burst_size;
  int yy;
  bit [7:0] localbuffer [];
  bit [7:0] read_data;
  bit [7:0] expected_data;
  int idatacntr;
  int miscompare_cntr;
  string write_item_s;
  string read_item_s;
  string expected_data_s;
  string msg_s;
  string localbuffer_s;
  int rollover_cnt;

  bit [7:0] expected_data_array [];


    if (write_item.burst_type==e_FIXED) begin

      idatacntr=2**write_item.burst_size;

      // compare every nth byte with the same offset byte in last beat.
      // should look like only the last beat got sent repeatedly
      // construct the expected array,, then compare against actual.
      // if miscompare, print original, readback and (calculated) expected.

      miscompare_cntr=0;
      expected_data_array=new[read_item.data.size()];

      // brute force, not elegant at all.
      // write to local buffer, then compare that buffer (repeated) with the axi readback


      yy=0;
      localbuffer=new[2**write_item.burst_size];
      for (int y=0;y<localbuffer.size();y++) begin
         localbuffer[y]='h0;
      end
      for (int y=0;y<write_item.len;y++) begin
        localbuffer[yy++]=write_item.data[y];
        if (yy >= 2**write_item.burst_size) begin
          yy=0;
        end
      end

      yy=0;
      for (int y=0; y<expected_data_array.size(); y++) begin
        expected_data_array[y]=localbuffer[yy++];
        if (yy >= localbuffer.size()) begin
          yy=0;
        end
      end

      for (int y=0;y<read_item.data.size();y++) begin
         expected_data = expected_data_array[y];
         read_data     = read_item.data[y];
         if (expected_data!=read_data) begin
            miscompare_cntr++;
         end
      end

      assert (miscompare_cntr==0) else begin
        write_item_s="";
        read_item_s="";
        expected_data_s="";
        localbuffer_s="";

       for (int z=0;z<write_item.data.size();z++) begin
          $sformat(write_item_s, "%s 0x%2x", write_item_s, write_item.data[z]);
        end

        for (int z=0;z<read_item.data.size();z++) begin
          $sformat(read_item_s, "%s 0x%2x", read_item_s, read_item.data[z]);
        end

        for (int z=0;z<expected_data_array.size();z++) begin
          $sformat(expected_data_s, "%s 0x%2x", expected_data_s, expected_data_array[z]);
        end

        for (int z=0;z<localbuffer.size();z++) begin
          $sformat(localbuffer_s, "%s 0x%2x", localbuffer_s, localbuffer[z]);
        end


        `uvm_error("AXI READBACK e_FIXED miscompare",
                   $sformatf("%0d miscompares between expected and actual data items.  \nExpected: %s \n  Actual: %s;  \nWritten: %s  \nLocalbuffer: %s", miscompare_cntr, expected_data_s, read_item_s, write_item_s, localbuffer_s ));
      end

      ///   ........................

    end else if (write_item.burst_type==e_INCR || write_item.burst_type==e_WRAP) begin
      for (int z=0;z<write_item.len;z++) begin
         read_data=read_item.data[z];
         expected_data=write_item.data[z];
         assert(expected_data==read_data) else begin
           miscompare_cntr++;
           `uvm_error("AXI READBACK e_INCR miscompare",
                       $sformatf("expected: 0x%0x   actual:0x%0x",
                                 expected_data,
                                 read_data))
         end
      end
    end else begin
           miscompare_cntr++;
      `uvm_error(this.get_type_name(),
                 $sformatf("Unsupported burst type %0d", write_item.burst_type))

    end

return (miscompare_cntr == 0);
endfunction : compare_items