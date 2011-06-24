# -*- coding: utf-8 -*-

require 'rexml/document'

module Dcmgr::Drivers
  class SnapshotStorage
    include Dcmgr::Helpers::CliHelper
 
    def initialize(bucket)
      @env = []
      @bucket = bucket
    end

    def setenv(key, value)
      @env.push("#{key}=#{value}")
    end

    def download
    end

    def upload
    end

    def delete
    end

    def check
    end
    
    def execute(cmd, args)
      script_root_path = File.join(File.expand_path('.'), 'script')
      script = File.join(script_root_path, 'storage_service')
      cmd = "/usr/bin/env #{@env.join(' ')} %s " + cmd
      args = [script] + args
      res = sh(cmd, args)
      
      if res[:stdout] != ''
        doc = REXML::Document.new res[:stdout]
        code = REXML::XPath.match( doc, "//Error/Code/text()" ).to_s
        message = REXML::XPath.match( doc, "//Error/Message/text()" ).to_s
        bucket_name = REXML::XPath.match( doc, "//Error/BucketName/text()" ).to_s
        request_id = REXML::XPath.match( doc, "//Error/RequestId/text()" ).to_s
        host_id = REXML::XPath.match( doc, "//Error/HostId/text()" ).to_s
        error_message = ["Snapshot execute error: ",cmd, code, message, bucket_name, request_id, host_id].join(',')
        raise error_message
      else
        res
      end
    end
  end
end
