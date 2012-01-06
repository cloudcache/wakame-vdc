# -*- coding: utf-8 -*-
$LOAD_PATH.unshift File.expand_path('../../../../../../trema/ruby', __FILE__)

require 'net/dhcp'
require 'eventmachine'
require 'trema'
require 'racket'

class IPAddr
  def to_short
    [(@addr >> 24) & 0xff, (@addr >> 16) & 0xff, (@addr >> 8) & 0xff, @addr & 0xff]
  end
end

module Dcmgr
  module VNet
    module OpenFlow
#
# Refactored code;
#
    
      module OpenFlowConstants
        # Default table used by all incoming packets.
        TABLE_CLASSIFIER = 0

        # Straight-forward routing of packets to the port tied to the
        # destination mac address, which includes all non-virtual
        # networks.
        TABLE_ROUTE_DIRECTLY = 3

        # Routing to non-virtual networks with filtering applied.
        #
        # Due to limitations in the rules we can use the filter rules
        # for the destination must be applied first, and its port number
        # loaded into a registry.
        #
        # The source will then apply filtering rules and output to the
        # port number found in registry 1.
        TABLE_LOAD_DST = 4
        TABLE_LOAD_SRC = 5

        # Routing to virtual networks.
        #
        # Each port participating in a virtual network will load the
        # virtual network id to registry 2 in the classifier table for
        # all types of packets.
        #
        # The current filtering rules are bare-boned and provide just
        # routing.
        TABLE_VIRTUAL_SRC = 6
        TABLE_VIRTUAL_DST = 7

        # The ARP antispoof table ensures no ARP packet SHA or SPA field
        # matches the mac address owned by another port.
        #
        # If valid, the next table routes the packet to the right port.
        TABLE_ARP_ANTISPOOF = 10
        TABLE_ARP_ROUTE = 11

        # Routing to the metadata server.
        #
        # Currently using the OpenFlowController, rather than learning
        # flows.
        TABLE_METADATA_OUTGOING = 12
        TABLE_METADATA_INCOMING = 13

        TABLE_MAC_ROUTE = 14
      end

      # OpenFlow datapath allows us to send OF messages and ovs-ofctl
      # commands to a specific bridge/switch.
      class OpenFlowDatapath
        attr_reader :controller
        attr_reader :datapath_id
        attr_reader :ovs_ofctl

        def initialize ofc, dp_id, ofctl
          @controller = ofc
          @datapath_id = dp_id
          @ovs_ofctl = ofctl
        end

        def switch
          controller.switches[datapath_id]
        end

        def send_message message
          controller.send_message datapath_id, message
        end

        def send_packet_out params
          controller.send_packet_out datapath_id, params
        end

        def send_arp out_port, op_code, src_hw, src_ip, dst_hw, dst_ip
          controller.send_arp datapath_id, out_port, op_code, src_hw, src_ip, dst_hw, dst_ip
        end

        def send_udp out_port, src_hw, src_ip, src_port, dst_hw, dst_ip, dst_port, payload
          controller.send_udp datapath_id, out_port, src_hw, src_ip, src_port, dst_hw, dst_ip, dst_port, payload
        end
      end

      class OpenFlowSwitch
        include Dcmgr::Logger
        include OpenFlowConstants
        
        attr_reader :datapath
        attr_reader :ports
        attr_reader :networks
        attr_reader :switch_name
        attr_reader :local_hw
        
        def initialize dp, name
          @datapath = dp
          @ports = {}
          @networks = {}
          @switch_name = name
        end
        
        def switch_ready
          logger.info "switch_ready: name:#{switch_name} datapath_id:%#x." % datapath.datapath_id

          # There's a short period of time between the switch being
          # activated and features_reply installing flow.
          datapath.send_message Trema::FeaturesRequest.new
        end

        def features_reply message
          logger.info  "features_reply from %#x." % message.datapath_id
          logger.debug "datapath_id: %#x" % message.datapath_id
          logger.debug "transaction_id: %#x" % message.transaction_id
          logger.debug "n_buffers: %u" % message.n_buffers
          logger.debug "n_tables: %u" % message.n_tables
          logger.debug "capabilities: %u" % message.capabilities
          logger.debug "actions: %u" % message.actions
          logger.info  "ports: %s" % message.ports.collect { | each | each.number }.sort.join( ", " )

          message.ports.each do | each |
            if each.number == OpenFlowController::OFPP_LOCAL
              @local_hw = each.hw_addr
              logger.debug "OFPP_LOCAL: hw_addr:#{local_hw.to_s}"
            end
          end

          message.ports.each do | each |
            port = OpenFlowPort.new(datapath, each)
            port.is_active = true
            ports[each.number] = port

            datapath.controller.insert_port self, port
          end

          # Build the routing flow table and some other flows using
          # ovs-ofctl due to the lack of multiple tables support, which
          # was introduced in of-spec 1.1.

          #
          # Classification
          #
          flows = []

          # DHCP queries from instances and network should always go to
          # local host, while queries from local host should go to the
          # network.
          flows << ["priority=#{5},udp,dl_dst=ff:ff:ff:ff:ff:ff,nw_src=0.0.0.0,nw_dst=255.255.255.255,tp_src=68,tp_dst=67", "local"]

          flows << ["priority=#{3},arp", "resubmit(,#{TABLE_ARP_ANTISPOOF})"]
          flows << ["priority=#{3},icmp", "resubmit(,#{TABLE_LOAD_DST})"]
          flows << ["priority=#{3},tcp", "resubmit(,#{TABLE_LOAD_DST})"]
          flows << ["priority=#{3},udp", "resubmit(,#{TABLE_LOAD_DST})"]

          flows << ["priority=#{2},in_port=local", "resubmit(,#{TABLE_ROUTE_DIRECTLY})"]

          #
          # MAC address routing
          #

          flows << ["priority=#{1},table=#{TABLE_MAC_ROUTE},dl_dst=#{local_hw.to_s}", "local"]
          flows << ["priority=#{1},table=#{TABLE_ROUTE_DIRECTLY},dl_dst=#{local_hw.to_s}", "local"]
          flows << ["priority=#{1},table=#{TABLE_LOAD_DST},dl_dst=#{local_hw.to_s}", "load:#{OpenFlowController::OFPP_LOCAL}->NXM_NX_REG0[],resubmit(,#{TABLE_LOAD_SRC})"]

          # Some flows depend on only local being able to send packets
          # with the local mac and ip address, so drop those.
          flows << ["priority=#{6},table=#{TABLE_LOAD_SRC},in_port=local", "output:NXM_NX_REG0[]"]
          flows << ["priority=#{5},table=#{TABLE_LOAD_SRC},dl_src=#{local_hw.to_s}", "drop"]
          flows << ["priority=#{5},table=#{TABLE_LOAD_SRC},ip,nw_src=#{Isono::Util.default_gw_ipaddr}", "drop"]

          #
          # ARP routing table
          #

          # ARP anti-spoofing flows.
          flows << ["priority=#{1},table=#{TABLE_ARP_ANTISPOOF},arp,in_port=local", "resubmit(,#{TABLE_ARP_ROUTE})"]

          # Replace drop actions with table default action.
          flows << ["priority=#{0},table=#{TABLE_ARP_ANTISPOOF},arp", "drop"]

          # TODO: How will this handle packets from host or eth0 that
          # spoof the mac of an instance?
          flows << ["priority=#{1},table=#{TABLE_ARP_ROUTE},arp,dl_dst=#{local_hw.to_s}", "local"]

          #
          # Meta-data connections
          #
          flows << ["priority=#{5},tcp,nw_dst=169.254.169.254,tp_dst=80", "resubmit(,#{TABLE_METADATA_OUTGOING})"]
          flows << ["priority=#{5},tcp,nw_src=#{Isono::Util.default_gw_ipaddr},tp_src=#{9002}", "resubmit(,#{TABLE_METADATA_INCOMING})"]

          flows << ["priority=#{4},table=#{TABLE_METADATA_OUTGOING},in_port=local", "drop"]
          flows << ["priority=#{0},table=#{TABLE_METADATA_OUTGOING}", "controller"]

          datapath.ovs_ofctl.add_flows_from_list flows        
        end

        def port_status message
          logger.info "port_status from %#x." % message.datapath_id
          logger.debug "datapath_id: %#x" % message.datapath_id
          logger.debug "reason: #{message.reason}"
          logger.debug "in_port: #{message.phy_port.number}"
          logger.debug "hw_addr: #{message.phy_port.hw_addr}"
          logger.debug "state: %#x" % message.phy_port.state

          case message.reason
          when OpenFlowController::OFPPR_ADD
            logger.info "Adding port: port:#{message.phy_port.number} name:#{message.phy_port.name}."
            raise "OpenFlowPort" if ports.has_key? message.phy_port.number

            datapath.controller.delete_port ports[message.phy_port.number] if ports.has_key? message.phy_port.number

            port = OpenFlowPort.new(datapath, message.phy_port)
            port.is_active = true
            ports[message.phy_port.number] = port

            datapath.controller.insert_port self, port

          when OpenFlowController::OFPPR_DELETE
            logger.info "Deleting instance port: port:#{message.phy_port.number}."
            raise "UnknownOpenflowPort" if not ports.has_key? message.phy_port.number

            datapath.controller.delete_port ports[message.phy_port.number] if ports.has_key? message.phy_port.number

          when OpenFlowController::OFPPR_MODIFY
            logger.info "Ignoring port modify..."
          end
        end

        def packet_in message
          port = ports[message.in_port]

          if port.nil?
            logger.debug "Dropping processing of packet, unknown port."
            return
          end

          if message.arp?
            logger.debug "Got ARP packet; port:#{message.in_port} source:#{message.arp_sha.to_s}:#{message.arp_spa.to_s} dest:#{message.arp_tha.to_s}:#{message.arp_tpa.to_s}."
            return if port.network.nil?

            if message.arp_oper == Racket::L3::ARP::ARPOP_REQUEST and message.arp_tpa.to_i == port.network.dhcp_ip.to_i
              datapath.send_arp(message.in_port, Racket::L3::ARP::ARPOP_REPLY,
                                port.network.dhcp_hw.to_s, port.network.dhcp_ip.to_s,
                                message.macsa.to_s, message.arp_spa.to_s)
            end

            return
          end

          if message.ipv4? and message.tcp?
            logger.debug "Got IPv4/TCP packet; port:#{message.in_port} source:#{message.ipv4_saddr.to_s}:#{message.tcp_src_port} dest:#{message.ipv4_daddr.to_s}:#{message.tcp_dst_port}."

            # Add dynamic NAT flows for meta-data connections.
            if message.ipv4_daddr.to_s == "169.254.169.254" and message.tcp_dst_port == 80
              install_dnat_entry(message, TABLE_METADATA_OUTGOING, TABLE_METADATA_INCOMING, OpenFlowController::OFPP_LOCAL, local_hw, Isono::Util.default_gw_ipaddr, 9002)
              datapath.send_packet_out(:packet_in => message, :actions => Trema::ActionOutput.new( :port => OpenFlowController::OFPP_TABLE ))
              return
            end

          end

          if message.ipv4? and message.udp?
            logger.debug "Got IPv4/UDP packet; port:#{message.in_port} source:#{message.ipv4_saddr.to_s}:#{message.udp_src_port} dest:#{message.ipv4_daddr.to_s}:#{message.udp_dst_port}."

            return if port.network.nil?

            if message.udp_src_port == 68 and message.udp_dst_port == 67
              dhcp_in = DHCP::Message.from_udp_payload(message.udp_payload)

              logger.debug "DHCP: message:#{dhcp_in.to_s}."

              if port.network.dhcp_ip.nil?
                logger.debug "DHCP: Port has no dhcp_ip: port:#{port.inspect}"
                return
              end

              # Check incoming type...
              message_type = dhcp_in.options.select { |each| each.type == $DHCP_MESSAGETYPE }
              return if message_type.empty? or message_type[0].payload.empty?

              # Verify dhcp_in values...

              if message_type[0].payload[0] == $DHCP_MSG_DISCOVER
                logger.debug "DHCP send: DHCP_MSG_OFFER."
                dhcp_out = DHCP::Offer.new(:options => [DHCP::MessageTypeOption.new(:payload => [$DHCP_MSG_OFFER])])
              elsif message_type[0].payload[0] == $DHCP_MSG_REQUEST
                logger.debug "DHCP send: DHCP_MSG_ACK."
                dhcp_out = DHCP::ACK.new(:options => [DHCP::MessageTypeOption.new(:payload => [$DHCP_MSG_ACK])])
              else
                logger.debug "DHCP send: no handler."
                return
              end

              dhcp_out.xid = dhcp_in.xid
              dhcp_out.yiaddr = Trema::IP.new(port.ip).to_i
              # Verify instead that discover has the right mac address.
              dhcp_out.chaddr = Trema::Mac.new(port.mac).to_short
              dhcp_out.siaddr = port.network.dhcp_ip.to_i

              subnet_mask = IPAddr.new(IPAddr::IN4MASK, Socket::AF_INET).mask(port.network.prefix)

              dhcp_out.options << DHCP::ServerIdentifierOption.new(:payload => port.network.dhcp_ip.to_short)
              dhcp_out.options << DHCP::IPAddressLeaseTimeOption.new(:payload => [ 0xff, 0xff, 0xff, 0xff ])
              dhcp_out.options << DHCP::BroadcastAddressOption.new(:payload => (port.network.ipv4_network | ~subnet_mask).to_short)
              # Host name 'abcdefgh'.
              # Domain name 'foo.local'
              # Domain name server
              dhcp_out.options << DHCP::SubnetMaskOption.new(:payload => subnet_mask.to_short)

              logger.debug "DHCP send: output:#{dhcp_out.to_s}."
              datapath.send_udp(message.in_port, port.network.dhcp_hw.to_s, port.network.dhcp_ip.to_s, 67, port.mac.to_s, port.ip, 68, dhcp_out.pack)
            end
          end
        end

        def install_dnat_entry message, outgoing_table, incoming_table, dest_port, dest_hw, dest_ip, dest_tp
          logger.info "Installing DNAT entry: #{dest_port} #{dest_hw} #{dest_ip}:#{dest_tp}"

          msg_nw_src = message.ipv4_saddr.to_s
          msg_nw_dst = message.ipv4_daddr.to_s

          # We don't need to match against the IP or port used by the
          # classifier to pass the flow to these tables.

          prefix = "priority=3,idle_timeout=#{300},tcp"

          prefix_outgoing = "#{prefix},table=#{outgoing_table},#{datapath.ovs_ofctl.arg_in_port message.in_port}"
          # classifier_outgoing = "nw_dst=#{msg_nw_dst},tp_dst=#{message.tcp_dst_port}"
          match_outgoing = "dl_src=#{message.macsa.to_s},dl_dst=#{message.macda.to_s},nw_src=#{msg_nw_src},tp_src=#{message.tcp_src_port}"
          action_outgoing = "mod_dl_dst:#{dest_hw},mod_nw_dst:#{dest_ip},mod_tp_dst:#{dest_tp},#{datapath.ovs_ofctl.arg_output dest_port}"

          prefix_incoming = "#{prefix},table=#{incoming_table},#{datapath.ovs_ofctl.arg_in_port dest_port}"
          # classifier_incoming = "nw_src=#{dest_ip},tp_src=#{dest_tp}"
          match_incoming = "dl_src=#{dest_hw.to_s},dl_dst=#{message.macsa.to_s},nw_dst=#{msg_nw_src},tp_dst=#{message.tcp_src_port}"
          action_incoming = "mod_dl_src:#{message.macda.to_s},mod_nw_src:#{msg_nw_dst},mod_tp_src:#{message.tcp_dst_port},#{datapath.ovs_ofctl.arg_output message.in_port}"

          datapath.ovs_ofctl.add_flow "#{prefix_outgoing},#{match_outgoing}", action_outgoing
          datapath.ovs_ofctl.add_flow "#{prefix_incoming},#{match_incoming}", action_incoming
        end

      end

      class OpenFlowNetwork
        include OpenFlowConstants

        attr_reader :id
        attr_reader :datapath

        # Add _numbers postfix.
        attr_reader :ports
        attr_reader :local_ports

        attr_accessor :virtual
        attr_accessor :dhcp_hw
        attr_accessor :dhcp_ip
        attr_accessor :ipv4_network
        attr_accessor :prefix

        def initialize dp, id
          @id = id
          @datapath = dp
          @ports = []
          @local_ports = []

          @virtual = false
          @prefix = 0
        end

        def add_port port, is_local
          ports << port
          local_ports << port if is_local
        end

        def remove_port port
          ports.delete port
          local_ports.delete port
        end

        def generate_flood_flows
          flows = []
          flood_flows.each { |flow|
            flows << [flow[0], "#{flow[1]}#{generate_flood_actions(flow[2], ports)}#{flow[3]}"]
          }
          flood_local_flows.each { |flow|
            flows << [flow[0], "#{flow[1]}#{generate_flood_actions(flow[2], local_ports)}#{flow[3]}"]
          }
          flows
        end

        def generate_flood_actions template, use_ports
          actions = ""
          use_ports.each { |port|
            actions << ",#{template.gsub('<>', port.to_s)}"
          }
          actions
        end

        def flood_flows
          @flood_flows ||= Array.new
        end

        def flood_local_flows
          @flood_local_flows ||= Array.new
        end

        def install_virtual_network
          flood_flows       << ["priority=#{1},table=#{TABLE_VIRTUAL_DST},reg1=#{id},reg2=#{0},dl_dst=ff:ff:ff:ff:ff:ff", "", "output:<>", ""]
          flood_local_flows << ["priority=#{0},table=#{TABLE_VIRTUAL_DST},reg1=#{id},dl_dst=ff:ff:ff:ff:ff:ff", "", "output:<>", ""]

          learn_arp_match = "priority=#{1},idle_timeout=#{3600*10},table=#{TABLE_VIRTUAL_DST},reg1=#{id},reg2=#{0},NXM_OF_ETH_DST[]=NXM_OF_ETH_SRC[]"
          learn_arp_actions = "output:NXM_NX_REG2[]"

          datapath.ovs_ofctl.add_flow "priority=#{2},table=#{TABLE_VIRTUAL_SRC},reg1=#{id},reg2=#{0}", "resubmit\\(,#{TABLE_VIRTUAL_DST}\\)"
          datapath.ovs_ofctl.add_flow "priority=#{1},table=#{TABLE_VIRTUAL_SRC},reg1=#{id},arp", "learn\\(#{learn_arp_match},#{learn_arp_actions}\\),resubmit\\(,#{TABLE_VIRTUAL_DST}\\)"
          datapath.ovs_ofctl.add_flow "priority=#{0},table=#{TABLE_VIRTUAL_SRC},reg1=#{id}", "resubmit\\(,#{TABLE_VIRTUAL_DST}\\)"

          # Catch ARP for the DHCP server.
          datapath.ovs_ofctl.add_flow "priority=#{3},table=#{TABLE_VIRTUAL_DST},reg1=#{id},arp,nw_dst=#{dhcp_ip.to_s}", "controller"

          # Catch DHCP requests.
          datapath.ovs_ofctl.add_flow "priority=#{3},table=#{TABLE_VIRTUAL_DST},reg1=#{id},udp,dl_dst=#{dhcp_hw},nw_dst=#{dhcp_ip.to_s},tp_src=68,tp_dst=67", "controller"
          datapath.ovs_ofctl.add_flow "priority=#{3},table=#{TABLE_VIRTUAL_DST},reg1=#{id},udp,dl_dst=ff:ff:ff:ff:ff:ff,nw_dst=255.255.255.255,tp_src=68,tp_dst=67", "controller"

          # logger.info "installed virtual network: id:#{id} dhcp_hw:#{dhcp_hw} dhcp_ip:#{dhcp_ip.to_s}."
        end

        def install_physical_network
          flood_flows << ["priority=#{1},table=#{TABLE_MAC_ROUTE},dl_dst=FF:FF:FF:FF:FF:FF", "", "output:<>", ""]
          flood_flows << ["priority=#{1},table=#{TABLE_ROUTE_DIRECTLY},dl_dst=FF:FF:FF:FF:FF:FF", "", "output:<>", ""]
          flood_flows << ["priority=#{1},table=#{TABLE_LOAD_DST},dl_dst=FF:FF:FF:FF:FF:FF", "", "load:<>->NXM_NX_REG0[],resubmit(,#{TABLE_LOAD_SRC})", ""]
          flood_flows << ["priority=#{1},table=#{TABLE_ARP_ROUTE},arp,dl_dst=FF:FF:FF:FF:FF:FF,arp_tha=00:00:00:00:00:00", "", "output:<>", ""]
        end

      end

      class OpenFlowPort
        include OpenFlowConstants

        attr_reader :datapath
        attr_reader :port_info
        attr_reader :lock
        attr_reader :port_type

        attr_accessor :has_instance
        attr_accessor :is_active
        attr_accessor :ip
        attr_accessor :mac
        attr_accessor :network

        PORT_TYPE_NONE = 0
        PORT_TYPE_ETH = 1
        PORT_TYPE_TUNNEL = 2
        PORT_TYPE_INSTANCE_NET = 3
        PORT_TYPE_INSTANCE_VNET = 4

        def initialize dp, port_info
          @datapath = dp
          @port_info = port_info
          @lock = Mutex.new
          @port_type = PORT_TYPE_NONE

          @has_instance = false
          @is_active = false
        end

        def init_eth
          @port_type = PORT_TYPE_ETH
          queue_flow "priority=#{6}", "udp,in_port=local,dl_dst=ff:ff:ff:ff:ff:ff,nw_src=0.0.0.0,nw_dst=255.255.255.255,tp_src=68,tp_dst=67", "output:#{port_info.number}"
          queue_flow "priority=#{2}", "in_port=#{port_info.number}",  "resubmit(,#{TABLE_ROUTE_DIRECTLY})"
          queue_flow "priority=#{0}", "table=#{TABLE_MAC_ROUTE}", "output:#{port_info.number}"
          queue_flow "priority=#{0}", "table=#{TABLE_ROUTE_DIRECTLY}", "output:#{port_info.number}"
          queue_flow "priority=#{0}", "table=#{TABLE_LOAD_DST}", "load:#{port_info.number}->NXM_NX_REG0[],resubmit(,#{TABLE_LOAD_SRC})"
          queue_flow "priority=#{4}", "table=#{TABLE_LOAD_SRC},in_port=#{port_info.number}", "output:NXM_NX_REG0[]"
          queue_flow "priority=#{1}", "table=#{TABLE_ARP_ANTISPOOF},arp,in_port=#{port_info.number}", "resubmit(,#{TABLE_ARP_ROUTE})"
          queue_flow "priority=#{0}", "table=#{TABLE_ARP_ROUTE},arp", "output:#{port_info.number}"
          queue_flow "priority=#{4}", "table=#{TABLE_METADATA_OUTGOING},in_port=#{port_info.number}", "drop"
        end

        def init_gre_tunnel
          @port_type = PORT_TYPE_TUNNEL
          queue_flow "priority=#{7}", "table=#{0},in_port=#{port_info.number}", "load:#{network.id}->NXM_NX_REG1[],load:#{port_info.number}->NXM_NX_REG2[],resubmit(,#{TABLE_VIRTUAL_SRC})"
        end

        def init_instance_net hw, ip
          @port_type = PORT_TYPE_INSTANCE_NET
          queue_flow "priority=#{1}", "table=#{TABLE_MAC_ROUTE},dl_dst=#{hw}", "output:#{port_info.number}"
          queue_flow "priority=#{2}", "table=#{0},in_port=#{port_info.number},dl_src=#{hw}", "resubmit(,#{TABLE_ROUTE_DIRECTLY})"
          queue_flow "priority=#{1}", "table=#{TABLE_ROUTE_DIRECTLY},dl_dst=#{hw}", "output:#{port_info.number}"
          queue_flow "priority=#{1}", "table=#{TABLE_LOAD_DST},dl_dst=#{hw}", "drop"
        end

        def init_instance_vnet hw, ip
          @port_type = PORT_TYPE_INSTANCE_VNET

          queue_flow "priority=#{7}", "table=#{0},in_port=#{port_info.number}", "load:#{network.id}->NXM_NX_REG1[],resubmit(,#{TABLE_VIRTUAL_SRC})"
          queue_flow "priority=#{2}", "table=#{TABLE_VIRTUAL_DST},reg1=#{network.id},dl_dst=#{hw}", "output:#{port_info.number}"
        end

        def install_arp_antispoof hw, ip
          # Require correct ARP source IP/MAC from instance, and protect the instance IP from ARP spoofing.
          queue_flow "priority=#{3}", "table=#{TABLE_ARP_ANTISPOOF},arp,in_port=#{port_info.number},arp_sha=#{hw},nw_src=#{ip}", "resubmit(,#{TABLE_ARP_ROUTE})"
          queue_flow "priority=#{2}", "table=#{TABLE_ARP_ANTISPOOF},arp,arp_sha=#{hw}", "drop"
          queue_flow "priority=#{2}", "table=#{TABLE_ARP_ANTISPOOF},arp,nw_src=#{ip}", "drop"

          # Routing of ARP packets to instance.
          queue_flow "priority=#{2}", "table=#{TABLE_ARP_ROUTE},arp,dl_dst=#{hw},nw_dst=#{ip}", "output:#{port_info.number}"
        end

        def install_static_transport nw_proto, local_hw, local_ip, local_port, remote_ip
          match_type = "dl_type=0x0800,nw_proto=#{nw_proto}"

          src_match = ""
          src_match << ",nw_src=#{remote_ip}" if not remote_ip =~ /\/0$/
          src_match << ",tp_dst=#{local_port}" if local_port != 0
          dst_match = ""
          dst_match << ",nw_dst=#{remote_ip}" if not remote_ip =~ /\/0$/
          dst_match << ",tp_src=#{local_port}" if local_port != 0

          incoming_match = "table=#{TABLE_LOAD_DST},#{match_type},dl_dst=#{local_hw},nw_dst=#{local_ip}#{src_match}"
          incoming_actions = "load:#{port_info.number}->NXM_NX_REG0[],resubmit(,#{TABLE_LOAD_SRC})"
          queue_flow "priority=#{3}", incoming_match, incoming_actions

          outgoing_match = "table=#{TABLE_LOAD_SRC},#{match_type},in_port=#{port_info.number},dl_src=#{local_hw},nw_src=#{local_ip}#{dst_match}"
          outgoing_actions = "output:NXM_NX_REG0[]"
          queue_flow "priority=#{3}", outgoing_match, outgoing_actions
        end

        def install_static_d_transport nw_proto, local_hw, local_ip, remote_ip, remote_port
          match_type = "dl_type=0x0800,nw_proto=#{nw_proto}"

          src_match = ""
          src_match << ",nw_src=#{remote_ip}" if not remote_ip =~ /\/0$/
          src_match << ",tp_src=#{remote_port}" if remote_port != 0
          dst_match = ""
          dst_match << ",nw_dst=#{remote_ip}" if not remote_ip =~ /\/0$/
          dst_match << ",tp_dst=#{remote_port}" if remote_port != 0

          incoming_match = "table=#{TABLE_LOAD_DST},#{match_type},dl_dst=#{local_hw},nw_dst=#{local_ip}#{src_match}"
          incoming_actions = "load:#{port_info.number}->NXM_NX_REG0[],resubmit(,#{TABLE_LOAD_SRC})"
          queue_flow "priority=#{3}", incoming_match, incoming_actions

          outgoing_match = "table=#{TABLE_LOAD_SRC},#{match_type},in_port=#{port_info.number},dl_src=#{local_hw},nw_src=#{local_ip}#{dst_match}"
          outgoing_actions = "output:NXM_NX_REG0[]"
          queue_flow "priority=#{3}", outgoing_match, outgoing_actions
        end

        def install_static_icmp icmp_type, icmp_code, local_hw, local_ip, src_ip
          match_type = "dl_type=0x0800,nw_proto=1"
          match_type << ",icmp_type=#{icmp_type}" if icmp_type >= 0
          match_type << ",icmp_code=#{icmp_code}" if icmp_code >= 0

          src_ip_match = ""
          src_ip_match << ",nw_src=#{src_ip}" if not src_ip =~ /\/0$/

          incoming_match = "table=#{TABLE_LOAD_DST},#{match_type},dl_dst=#{local_hw},nw_dst=#{local_ip}#{src_ip_match}"
          incoming_actions = "load:#{port_info.number}->NXM_NX_REG0[],resubmit(,#{TABLE_LOAD_SRC})"
          queue_flow "priority=#{3}", incoming_match, incoming_actions

          outgoing_match = "table=#{TABLE_LOAD_SRC},#{match_type},in_port=#{port_info.number},dl_src=#{local_hw},nw_src=#{local_ip}#{src_ip_match},"
          outgoing_actions = "output:NXM_NX_REG0[]"
          queue_flow "priority=#{3}", outgoing_match, outgoing_actions
        end

        def install_local_icmp hw, ip
          match_type = "dl_type=0x0800,nw_proto=1"

          learn_outgoing_match = "priority=#{2},idle_timeout=#{60},table=#{TABLE_LOAD_DST},#{match_type},NXM_OF_IN_PORT[],NXM_OF_ETH_SRC[],NXM_OF_ETH_DST[],NXM_OF_IP_SRC[],NXM_OF_IP_DST[]"
          learn_outgoing_actions = "output:NXM_NX_REG0[]"

          learn_incoming_match = "priority=#{2},idle_timeout=#{60},table=#{TABLE_LOAD_DST},#{match_type},NXM_OF_IN_PORT[]=NXM_NX_REG0[0..15],NXM_OF_ETH_SRC[]=NXM_OF_ETH_DST[],NXM_OF_ETH_DST[]=NXM_OF_ETH_SRC[],NXM_OF_IP_SRC[]=NXM_OF_IP_DST[],NXM_OF_IP_DST[]=NXM_OF_IP_SRC[]"
          learn_incoming_actions = "output:NXM_OF_IN_PORT[]"

          actions = "learn(#{learn_outgoing_match},#{learn_outgoing_actions}),learn(#{learn_incoming_match},#{learn_incoming_actions}),output:NXM_NX_REG0[]"

          queue_flow "priority=#{1}", "table=#{TABLE_LOAD_SRC},#{match_type},in_port=#{port_info.number},dl_src=#{hw},nw_src=#{ip}", actions
        end

        def install_local_transport nw_proto, hw, ip
          case nw_proto
          when 6
            transport_name = "TCP"
            idle_timeout = 7200
          when 17
            transport_name = "UDP"
            idle_timeout = 600
          end

          match_type = "dl_type=0x0800,nw_proto=#{nw_proto}"

          learn_outgoing_match = "priority=#{2},idle_timeout=#{idle_timeout},table=#{TABLE_LOAD_DST},#{match_type},NXM_OF_IN_PORT[],NXM_OF_ETH_SRC[],NXM_OF_ETH_DST[],NXM_OF_IP_SRC[],NXM_OF_IP_DST[],NXM_OF_#{transport_name}_SRC[],NXM_OF_#{transport_name}_DST[]"
          learn_outgoing_actions = "output:NXM_NX_REG0[]"

          learn_incoming_match = "priority=#{2},idle_timeout=#{idle_timeout},table=#{TABLE_LOAD_DST},#{match_type},NXM_OF_IN_PORT[]=NXM_NX_REG0[0..15],NXM_OF_ETH_SRC[]=NXM_OF_ETH_DST[],NXM_OF_ETH_DST[]=NXM_OF_ETH_SRC[],NXM_OF_IP_SRC[]=NXM_OF_IP_DST[],NXM_OF_IP_DST[]=NXM_OF_IP_SRC[],NXM_OF_#{transport_name}_SRC[]=NXM_OF_#{transport_name}_DST[],NXM_OF_#{transport_name}_DST[]=NXM_OF_#{transport_name}_SRC[]"
          learn_incoming_actions = "output:NXM_OF_IN_PORT[]"

          actions = "learn(#{learn_outgoing_match},#{learn_outgoing_actions}),learn(#{learn_incoming_match},#{learn_incoming_actions}),output:NXM_NX_REG0[]"

          queue_flow "priority=#{1}", "table=#{TABLE_LOAD_SRC},#{match_type},in_port=#{port_info.number},dl_src=#{hw},nw_src=#{ip}", actions
        end

        def active_flows
          @active_flows ||= Array.new
        end

        def queued_flows
          @queued_flows ||= Array.new
        end

        def queue_flow prefix, match, actions
          active_flows << match
          queued_flows << ["#{prefix},#{match}", actions]
        end

      end

      #
      # Old code;
      #

      class OpenFlowController < Trema::Controller
        include Dcmgr::Logger
        include OpenFlowConstants

        attr_reader :default_ofctl
        attr_reader :switches

        def ports
          switches.first[1].ports
        end

        def local_hw
          switches.first[1].local_hw
        end

        def initialize service_openflow
          @service_openflow = service_openflow
          @default_ofctl = OvsOfctl.new service_openflow.node.manifest.config

          @switches = {}
        end

        def start
          logger.info "starting OpenFlow controller."
        end

        def switch_ready datapath_id
          logger.info "switch_ready from %#x." % datapath_id

          # We currently rely on the ovs database to figure out the
          # bridge name, as it is randomly generated each time the
          # bridge is created unless explicitly set by the user.
          bridge_name = @default_ofctl.get_bridge_name(datapath_id)
          raise "No bridge found matching: datapath_id:%016x" % datapath_id if bridge_name.nil?

          ofctl = @default_ofctl.dup
          ofctl.switch_name = bridge_name

          # There is no need to clean up the old switch, as all the
          # previous flows are removed. Just let it rebuild everything.
          #
          # This might not be optimal in cases where the switch got
          # disconnected for a short period, as Open vSwitch has the
          # ability to keep flows between sessions.
          switches[datapath_id] = OpenFlowSwitch.new(OpenFlowDatapath.new(self, datapath_id, ofctl), bridge_name)
          switches[datapath_id].switch_ready
        end

        def features_reply message
          raise "No switch found." unless switches.has_key? message.datapath_id
          switches[message.datapath_id].features_reply message
          
          @service_openflow.networks.each { |network| update_network network[1] }
        end

        def insert_port switch, port
          if port.port_info.number >= OFPP_MAX
            # Do nothing...
          elsif port.port_info.name =~ /^eth/
            @service_openflow.add_eth switch, port
          elsif port.port_info.name =~ /^vif-/
            @service_openflow.add_instance switch, port
          elsif port.port_info.name =~ /^gre-/
            @service_openflow.add_tunnel switch, port
          else
          end
        end

        def delete_port port
          port.lock.synchronize {
            return unless port.is_active
            port.is_active = false

            if not port.network.nil?
              port.network.remove_port port.port_info.number
              update_network port.network
            end

            @default_ofctl.del_flows_from_list port.active_flows
            port.active_flows.clear
            port.queued_flows.clear
            ports.delete port.port_info.number
          }
        end

        def port_status message
          raise "No switch found." unless switches.has_key? message.datapath_id
          switches[message.datapath_id].port_status message
        end

        def packet_in datapath_id, message
          raise "No switch found." unless switches.has_key? datapath_id
          switches[datapath_id].packet_in message
        end

        def vendor message
          logger.debug "vendor message from #{message.datapath_id.to_hex}."
          logger.debug "transaction_id: #{message.transaction_id.to_hex}"
          logger.debug "data: #{message.buffer.unpack('H*')}"
        end

        #
        # Public functions
        #

        def install_virtual_network network
          network.flood_flows       << ["priority=#{1},table=#{TABLE_VIRTUAL_DST},reg1=#{network.id},reg2=#{0},dl_dst=ff:ff:ff:ff:ff:ff", "", "output:<>", ""]
          network.flood_local_flows << ["priority=#{0},table=#{TABLE_VIRTUAL_DST},reg1=#{network.id},dl_dst=ff:ff:ff:ff:ff:ff", "", "output:<>", ""]

          learn_arp_match = "priority=#{1},idle_timeout=#{3600*10},table=#{TABLE_VIRTUAL_DST},reg1=#{network.id},reg2=#{0},NXM_OF_ETH_DST[]=NXM_OF_ETH_SRC[]"
          learn_arp_actions = "output:NXM_NX_REG2[]"

          network.datapath.ovs_ofctl.add_flow "priority=#{2},table=#{TABLE_VIRTUAL_SRC},reg1=#{network.id},reg2=#{0}", "resubmit\\(,#{TABLE_VIRTUAL_DST}\\)"
          network.datapath.ovs_ofctl.add_flow "priority=#{1},table=#{TABLE_VIRTUAL_SRC},reg1=#{network.id},arp", "learn\\(#{learn_arp_match},#{learn_arp_actions}\\),resubmit\\(,#{TABLE_VIRTUAL_DST}\\)"
          network.datapath.ovs_ofctl.add_flow "priority=#{0},table=#{TABLE_VIRTUAL_SRC},reg1=#{network.id}", "resubmit\\(,#{TABLE_VIRTUAL_DST}\\)"

          # Catch ARP for the DHCP server.
          network.datapath.ovs_ofctl.add_flow "priority=#{3},table=#{TABLE_VIRTUAL_DST},reg1=#{network.id},arp,nw_dst=#{network.dhcp_ip.to_s}", "controller"

          # Catch DHCP requests.
          network.datapath.ovs_ofctl.add_flow "priority=#{3},table=#{TABLE_VIRTUAL_DST},reg1=#{network.id},udp,dl_dst=#{network.dhcp_hw},nw_dst=#{network.dhcp_ip.to_s},tp_src=68,tp_dst=67", "controller"
          network.datapath.ovs_ofctl.add_flow "priority=#{3},table=#{TABLE_VIRTUAL_DST},reg1=#{network.id},udp,dl_dst=ff:ff:ff:ff:ff:ff,nw_dst=255.255.255.255,tp_src=68,tp_dst=67", "controller"

          logger.info "installed virtual network: id:#{network.id} dhcp_hw:#{network.dhcp_hw} dhcp_ip:#{network.dhcp_ip.to_s}."
        end

        def install_physical_network network
          network.flood_flows << ["priority=#{1},table=#{TABLE_MAC_ROUTE},dl_dst=FF:FF:FF:FF:FF:FF", "", "output:<>", ""]
          network.flood_flows << ["priority=#{1},table=#{TABLE_ROUTE_DIRECTLY},dl_dst=FF:FF:FF:FF:FF:FF", "", "output:<>", ""]
          network.flood_flows << ["priority=#{1},table=#{TABLE_LOAD_DST},dl_dst=FF:FF:FF:FF:FF:FF", "", "load:<>->NXM_NX_REG0[],resubmit(,#{TABLE_LOAD_SRC})", ""]
          network.flood_flows << ["priority=#{1},table=#{TABLE_ARP_ROUTE},arp,dl_dst=FF:FF:FF:FF:FF:FF,arp_tha=00:00:00:00:00:00", "", "output:<>", ""]
        end

        def update_network network
          network.datapath.ovs_ofctl.add_flows_from_list network.generate_flood_flows
        end

        def send_udp datapath_id, out_port, src_hw, src_ip, src_port, dst_hw, dst_ip, dst_port, payload
          raw_out = Racket::Racket.new
          raw_out.l2 = Racket::L2::Ethernet.new
          raw_out.l2.src_mac = src_hw
          raw_out.l2.dst_mac = dst_hw
          
          raw_out.l3 = Racket::L3::IPv4.new
          raw_out.l3.src_ip = src_ip
          raw_out.l3.dst_ip = dst_ip
          raw_out.l3.protocol = 0x11

          raw_out.l4 = Racket::L4::UDP.new
          raw_out.l4.src_port = src_port
          raw_out.l4.dst_port = dst_port
          raw_out.l4.payload = payload

          raw_out.l4.fix!(raw_out.l3.src_ip, raw_out.l3.dst_ip)

          raw_out.layers.compact.each { |l|
            logger.debug "send udp: layer:#{l.pretty}."
          }

          send_packet_out(datapath_id, :data => raw_out.pack, :actions => Trema::ActionOutput.new( :port => out_port ) )
        end

        def send_arp datapath_id, out_port, op_code, src_hw, src_ip, dst_hw, dst_ip
          raw_out = Racket::Racket.new
          raw_out.l2 = Racket::L2::Ethernet.new
          raw_out.l2.ethertype = Racket::L2::Ethernet::ETHERTYPE_ARP
          raw_out.l2.src_mac = src_hw
          raw_out.l2.dst_mac = dst_hw
          
          raw_out.l3 = Racket::L3::ARP.new
          raw_out.l3.opcode = op_code
          raw_out.l3.sha = src_hw
          raw_out.l3.spa = src_ip
          raw_out.l3.tha = dst_hw
          raw_out.l3.tpa = dst_ip

          raw_out.layers.compact.each { |l|
            logger.debug "ARP packet: layer:#{l.pretty}."
          }

          send_packet_out(datapath_id, :data => raw_out.pack, :actions => Trema::ActionOutput.new( :port => out_port ) )
        end

      end


      class OvsOfctl
        include Dcmgr::Logger
        attr_accessor :ovs_ofctl
        attr_accessor :verbose
        attr_accessor :switch_name

        def initialize config
          # TODO: Make ovs_vsctl use a real config option.
          @ovs_ofctl = config.ovs_ofctl_path
          @ovs_vsctl = config.ovs_ofctl_path.dup
          @ovs_vsctl[/ovs-ofctl/] = 'ovs-vsctl'

          @verbose = config.verbose_openflow
        end

        def get_bridge_name datapath_id
          command = "#{@ovs_vsctl} --no-heading -- --columns=name find bridge datapath_id=%016x" % datapath_id
          puts command if verbose == true
          /^"(.*)"/.match(`#{command}`)[1]
        end

        def add_flow flow_match, actions
          command = "#{@ovs_ofctl} add-flow #{switch_name} #{flow_match},actions=#{actions}"
          logger.debug "'#{command}' => #{system(command)}."
        end

        def del_flow flow_match
          command = "#{@ovs_ofctl} del-flows #{switch_name} #{flow_match}"
          logger.debug "'#{command}' => #{system(command)}."
        end

        def add_flows_from_list(flows)
          recmds = []

          eos = "__EOS_#{Isono::Util.gen_id}___"
          recmds << "#{@ovs_ofctl} add-flow #{switch_name} - <<'#{eos}'"
          flows.each { |flow|
            full_flow = "#{flow[0]},actions=#{flow[1]}"
            puts "ovs-ofctl add-flow #{switch_name} #{full_flow}" if verbose == true
            recmds << full_flow
          }
          recmds << "#{eos}"

          logger.debug("applying flow(s): #{recmds.size - 2}")
          system(recmds.join("\n"))
        end

        def del_flows_from_list(flows)
          recmds = []

          eos = "__EOS_#{Isono::Util.gen_id}___"
          recmds << "#{@ovs_ofctl} del-flows #{switch_name} - <<'#{eos}'"
          flows.each { |flow|
            puts "ovs-ofctl del-flows #{switch_name} #{flow}" if verbose == true
            recmds << flow
          }
          recmds << "#{eos}"

          logger.debug("removing flow(s): #{recmds.size - 2}")
          system(recmds.join("\n"))
        end

        def arg_in_port port_number
          case port_number
          when OpenFlowController::OFPP_LOCAL
            return "in_port=local"
          else
            return "in_port=#{port_number}" if port_number < OpenFlowController::OFPP_MAX
          end
        end

        def arg_output port_number
          case port_number
          when OpenFlowController::OFPP_LOCAL
            return "local"
          else
            return "output:#{port_number}" if port_number < OpenFlowController::OFPP_MAX
          end
        end

        def add_gre_tunnel tunnel_name, remote_ip, key
          system("#{@ovs_vsctl} add-port #{switch_name} #{tunnel_name} -- set interface #{tunnel_name} type=gre options:remote_ip=#{remote_ip} options:key=#{key}")
        end

      end

      class OpenFlowForwardingEntry
        attr_reader :mac
        attr_reader :port_no

        def initialize mac, port_no
          @mac = mac
          @port_no = port_no
        end

        def update port_no
          @port_no = port_no
        end
      end
      
      class OpenFlowForwardingDatabase
        def initialize
          @db = {}
        end

        def port_no_of mac
          dest = @db[mac]

          if dest
            dest.port_no
          else
            nil
          end
        end

        def learn mac, port_no
          entry = @db[mac]

          if entry
            entry.update port_no
          else
            @db[new_entry.mac] = ForwardingEntry.new(mac, port_no)
          end
        end
      end

    end
  end
end
