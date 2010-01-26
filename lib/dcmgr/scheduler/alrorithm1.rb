
module Dcmgr
  module PhysicalHostScheduler
    class Algorithm1
      class ArrangeHost
        include Enumerable
        
        def initialize(host)
          @host = host
          @layers = []
          @same_area_hosts = {}
        end

        def layers=(names)
          @layers = names
        end

        def area(i)
          @layers[i]
        end

        def set_same_area_hosts(area_id, hosts)
          @same_area_hosts[area_id] = hosts.select{|h| h != self}
        end

        def inspect
          @host.inspect
        end

        def same_area_hosts(area_id)
          @same_area_hosts[area_id]
        end

        def method_missing(name, *arg)
          @host.send(name, *arg)
        end

        def self.layers(tags, physical_hosts, layer_level=8)
          hosts = physical_hosts.map{|h| ArrangeHost.new(h)}
          tags.each_with_index{|tag_name, i|
            host = hosts[i]
            split_names = ((tag_name + "." * layer_level).split(".", layer_level + 1))
            host.layers=(split_names)
          }
          
          layer_areas = (0...layer_level).map{|i|
            areas = hosts.collect{|h| h.area(i)}.uniq
            areas.each{|area|
              area_hosts = hosts.select{|h| h.area(i) == area }
              area_hosts.each{|h| h.set_same_area_hosts(i, area_hosts)}
            }
            areas
          }
          
          ret = []
          layer_areas.each_with_index{|areas, id|
            area_hash = Hash.new
            areas.each{|area|
              area_hash[area] = (0...(hosts.length)).select{|host_idx|
                hosts[host_idx].area(id) == area }
            }
            ret << area_hash
          }
          [ret, hosts]
        end
      end
      
      def assign_to_instance(hosts, instance)
        Dcmgr::logger.debug "alrogithm 1 schedule instance--"
        enable_hosts = hosts.select{|ph|
          instance.need_cpus <= ph.cpus and
          instance.need_cpu_mhz <= ph.space_cpu_mhz and
          instance.need_memory <= ph.space_memory
        }
        raise NoPhysicalHostError.new("no enable physical hosts") if enable_hosts.length == 0
        
        Dcmgr::logger.debug enable_hosts.map{|h| h.uuid}.join(" / ")
        
        location_tags = enable_hosts.map{|h| h.location_tags.first.name }
        host_points = points(enable_hosts, location_tags)
        min_point = host_points.min

        enable_hosts[host_points.index{|pt| pt == min_point}]
      end
      
      private
      
      def split_layers(tag_names, i)
        layer_names = {}
        tag_names.each{|name|
          layer_name = ((name + "........").split(".", 9))[i]
          a[]
          layer_names[i][layer_name] = true
        }
        
        layer_names.keys
      end

      def find_layer_hosts(hosts, layer_name, i)
        hosts.each{|host|
          layer_name = ((name + "........").split(".", 9))[i]
        }
      end
      
      def points(hosts, location_tags)
        layers, hosts = ArrangeHost.layers(location_tags, hosts)
        host_points = Array.new(hosts.length, 0.0)

        hosts.each_with_index {|host, i|
          next unless host.instances.length > 0

          layers.length.times{|layer_id|
            host_points[i] += host.instances.length
            host.same_area_hosts(layer_id).each{|same_host|
              id = hosts.index{|h| h == same_host}
              host_points[id] += host.instances.length.to_f / 10
            }
          }
        }
        host_points
      end
    end
  end
end
