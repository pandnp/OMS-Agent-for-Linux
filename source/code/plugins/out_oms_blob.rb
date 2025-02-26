module Fluent

  class OutputOMSBlob < BufferedOutput

    Plugin.register_output('out_oms_blob', self)
	
    # Endpoint URL ex. localhost.local/api/

    def initialize
      super
	  
      require 'base64'
      require 'digest'
      require 'json'
      require 'net/http'
      require 'net/https'
      require 'openssl'
      require 'rexml/document'
      require 'securerandom'
      require 'socket'
      require 'uri'
      require_relative 'omslog'
      require_relative 'oms_configuration'
      require_relative 'oms_common'
      require_relative 'blocklock'
      require_relative 'agent_telemetry_script'
    end

    config_param :omsadmin_conf_path, :string, :default => '/etc/opt/microsoft/omsagent/conf/omsadmin.conf'
    config_param :cert_path, :string, :default => '/etc/opt/microsoft/omsagent/certs/oms.crt'
    config_param :key_path, :string, :default => '/etc/opt/microsoft/omsagent/certs/oms.key'
    config_param :blob_uri_expiry, :string, :default => '00:10:00'
    config_param :url_suffix_template, :string, :default => "custom_data_type + '/00000000-0000-0000-0000-000000000002/' + OMS::Common.get_hostname + '/' + OMS::Configuration.agent_id + '/' + suffix + '.log'"
    config_param :proxy_conf_path, :string, :default => '/etc/opt/microsoft/omsagent/proxy.conf'
    config_param :run_in_background, :bool, :default => false

    def configure(conf)
      super
    end

    def start
      super
      @proxy_config = OMS::Configuration.get_proxy_config(@proxy_conf_path)
      @sha256 = Digest::SHA256.new
    end

    def shutdown
      super
      OMS::BackgroundJobs.instance.cleanup
    end

    ####################################################################################################
    # Methods
    ####################################################################################################

    # create a HTTP request to PUT blob
    # parameters:
    #   uri: URI. blob URI
    #   msg: string. body of the request
    #   file_path: string. file path
    # returns:
    #   HTTPRequest. blob PUT request
    def create_blob_put_request(uri, msg, request_id, file_path = nil)
      headers = {}

      headers[OMS::CaseSensitiveString.new("x-ms-meta-TimeZoneid")] = OMS::Common.get_current_timezone
      headers[OMS::CaseSensitiveString.new("x-ms-meta-ComputerName")] = OMS::Common.get_hostname
      if !file_path.nil?
        headers[OMS::CaseSensitiveString.new("x-ms-meta-FilePath")] = file_path
      end

      azure_resource_id = OMS::Configuration.azure_resource_id
      if !azure_resource_id.to_s.empty?
        headers[OMS::CaseSensitiveString.new("x-ms-AzureResourceId")] = azure_resource_id
      end
      
      azure_region = OMS::Configuration.azure_region if defined?(OMS::Configuration.azure_region)
      if !azure_region.to_s.empty?
        headers[OMS::CaseSensitiveString.new("x-ms-AzureRegion")] = azure_region
      end
      
      omscloud_id = OMS::Configuration.omscloud_id
      if !omscloud_id.to_s.empty?
        headers[OMS::CaseSensitiveString.new("x-ms-OMSCloudId")] = omscloud_id
      end

      uuid = OMS::Configuration.uuid
      if !uuid.to_s.empty?
        headers[OMS::CaseSensitiveString.new("x-ms-UUID")] = uuid
      end

      headers[OMS::CaseSensitiveString.new("X-Request-ID")] = request_id

      headers["Content-Type"] = "application/octet-stream"
      headers["Content-Length"] = msg.bytesize.to_s

      # If the request version is 2011-08-18 or newer, the ETag value will be returned
      headers[OMS::CaseSensitiveString.new("x-ms-version")] = "2016-05-31"

      req = Net::HTTP::Put.new(uri.request_uri, headers)
      req.body = msg
      return req
    rescue OMS::RetryRequestException => e
        OMS::Log.error_once("HTTP error for Request-ID: #{request_id} Error: #{e}")
        raise e.message, "Request-ID: #{request_id}"
    end # create_blob_put_request

    # get the blob JSON info from ODS
    # parameters
    #   container_type: string. ContainerType of the data
    #   data_type: string. DataTypeId of the data
    #   custom_data_type: string. CustomDataType of the CustomLog
    #   suffix: string. Suffix of the blob
    # returns:
    #   Hash. JSON from blob ODS endpoint
    def request_blob_json(container_type, data_type, custom_data_type, suffix)
      data_type_id = data_type
      if !custom_data_type.nil?
        data_type_id = "#{data_type}.#{custom_data_type}"
      end

      url_suffix = eval(url_suffix_template)

      data = {
        "ContainerType" => container_type,
        "DataTypeId" => data_type_id,
        "ExpiryDuration" => blob_uri_expiry,
        "Suffix" => url_suffix,
        "SkipScanningQueue" => true,
        "SupportWriteOnlyBlob" => true
      }

      extra_headers = {
        OMS::CaseSensitiveString.new('x-ms-client-request-retry-count') => "#{@num_errors}"
      }
      req = OMS::Common.create_ods_request(OMS::Configuration.get_blob_ods_endpoint.path, data, compress=false, extra_headers)

      ods_http = OMS::Common.create_ods_http(OMS::Configuration.get_blob_ods_endpoint, @proxy_config)
      body = OMS::Common.start_request(req, ods_http)

      # remove the BOM (Byte Order Marker)
      clean_body = body.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace, :replace => "")
      return JSON.parse(clean_body)
    end # request_blob_json

    # get the blob SAS URI and committed blocks from ODS
    # parameters
    #   container_type: string. ContainerType of the data
    #   data_type: string. DataTypeId of the data
    #   custom_data_type: string. CustomDataType of the CustomLog
    #   suffix: string. Suffix of the blob
    # returns:
    #   URI. blob SAS URI
    #   string[]. a list of committed blocks
    def get_blob_uri_and_committed_blocks(container_type, data_type, custom_data_type, suffix)
      blob_json = request_blob_json(container_type, data_type, custom_data_type, suffix)

      if blob_json.has_key?("Uri")
        blob_uri = URI.parse(blob_json["Uri"])
      else
        @log.error "JSON from BLOB does not contain a URI"
        blob_uri = nil
      end
      if blob_json.has_key?("CommittedBlockList") and !blob_json["CommittedBlockList"].nil?
        blocks_committed = blob_json["CommittedBlockList"]
      else
        blocks_committed = []
      end
      if blob_json.has_key?("Size")
        blob_size = blob_json["Size"]
      else
        blob_size = 0
      end

      return blob_uri, blocks_committed, blob_size
    end # get_blob_uri_and_committed_blocks

    # append data to the blob
    # parameters:
    #   uri: URI. blob URI
    #   msgs: string[]. messages
    #   file_path: string. file path
    def append_blob(uri, msgs, file_path, blocks_committed)
      if msgs.size == 0
        return 0
      end

      # concatenate the messages
      msg = ''
      msgs.each { |s| msg << "#{s}\r\n" if s.to_s.length > 0 }
      dataSize = msg.length

      if dataSize == 0
        return 0
      end

      # append blocks
      # if the msg is longer than 100MB (to be safe, blob limitation is 100MB), we should break it into multiple blocks
      chunk_size = 100000000
      blocks_uncommitted = []
      if msg.to_s.length <= chunk_size
        blocks_uncommitted << upload_block(uri, msg)
      else
        while msg.to_s.length > 0 do
          chunk = msg.slice!(0, chunk_size)
          blocks_uncommitted << upload_block(uri, chunk)
        end
      end

      # commit blocks
      etag = commit_blocks(uri, blocks_committed, blocks_uncommitted, file_path)
      return dataSize, etag
    end # append_blob

    # upload one block to the blob
    # parameters:
    #   uri: URI. blob URI
    #   msg: string. block content
    # returns:
    #   string. block id
    def upload_block(uri, msg)
      base64_blockid = Base64.encode64(SecureRandom.uuid)
      request_id = SecureRandom.uuid
      append_uri = URI.parse("#{uri.to_s}&comp=block&blockid=#{base64_blockid}")

      @log.debug("uploading block request_id=#{request_id}, blockid=#{base64_blockid}")
      @log.trace("blockid=#{base64_blockid} block=#{msg}")

      put_block_req = create_blob_put_request(append_uri, msg, request_id, nil)
      http = OMS::Common.create_secure_http(append_uri, @proxy_config)
      OMS::Common.start_request(put_block_req, http)

      return base64_blockid
    end # upload_block

    # commit blocks of the blob.
    # NOTE: the order of the committed and uncommitted blocks determines the sequence of the file content
    # parameters:
    #   uri: URI. blob URI
    #   blocks_committed: string[]. committed block id list, which already exist
    #   blocks_uncommitted: string[]. uncommitted block id list, which are just uploaded
    #   file_path: string. file path
    def commit_blocks(uri, blocks_committed, blocks_uncommitted, file_path)
      doc = REXML::Document.new "<BlockList />"
      blocks_committed.each { |blockid| doc.root.add_element(REXML::Element.new("Committed").add_text(blockid)) }
      blocks_uncommitted.each { |blockid| doc.root.add_element(REXML::Element.new("Uncommitted").add_text(blockid)) }

      commit_msg = doc.to_s

      blocklist_uri = URI.parse("#{uri.to_s}&comp=blocklist")
      request_id = SecureRandom.uuid
      put_blocklist_req = create_blob_put_request(blocklist_uri, commit_msg, request_id, file_path)
      http = OMS::Common.create_secure_http(blocklist_uri, @proxy_config)
      response = OMS::Common.start_request(put_blocklist_req, http, ignore404 = false, return_entire_response = true)

      headers = response.to_hash
      if headers.has_key?("etag")
        etag_quoted = headers["etag"]
        if etag_quoted.is_a?(Array)
          etag_quoted = etag_quoted[0]
        end
        etag = etag_quoted.gsub(/"/, "")
      else
        @log.error("Cannot extract ETag from BLOB response #{response}.")
        etag = ""
      end
      return etag
    end # commit_blocks

    # Notify ODS that we have completed uploading to the BLOB
    # Parameters:
    #   uri: URI. blob URI
    #   data_type: string. DataTypeId of the data
    #   custom_data_type: string. CustomDataType of the CustomLog
    #   offset_blob_size: int. Amount of data that BLOB contained before we appended to it
    #   sent_size: int. Amount of data we appended to the BLOB
    #   etag: string. ETag from the BLOB for this data
    def notify_blob_upload_complete(uri, data_type, custom_data_type, offset_blob_size, sent_size, etag)
      data_type_id = data_type
      if !custom_data_type.nil?
        data_type_id = "#{data_type}.#{custom_data_type}"
      end

      # Remove SAS token from the URL
      uri.fragment = uri.query = nil

      data = {
        # Adding timezone is important for ODS while generating _TimeReceived field
        "metadata-TimeZoneId" => OMS::Common.get_current_timezone,
        "DataType" => "BLOB_UPLOAD_NOTIFICATION",
        "IPName" => "",
        "DataItems" => [
          {
            "BlobUrl" => uri.to_s,
            "OriginalDataTypeId" => data_type_id,
            "StartOffset" => offset_blob_size,
            "FileSize" => (offset_blob_size + sent_size),
            "Etag" => etag
          }
        ]
      }

      req = OMS::Common.create_ods_request(OMS::Configuration.notify_blob_ods_endpoint.path, data, compress=false)

      ods_http = OMS::Common.create_ods_http(OMS::Configuration.notify_blob_ods_endpoint, @proxy_config)
      body = OMS::Common.start_request(req, ods_http)
    end # notify_blob_upload_complete
    
    def write_status_file(success, message)
      fn = '/var/opt/microsoft/omsagent/log/ODSIngestionBlob.status'
      status = '{ "operation": "ODSIngestionBlob", "success": "%s", "message": "%s" }' % [success, message]
      begin
        File.open(fn,'w',0664) { |file| file.write(status) }
      rescue => e
        @log.debug "Error:'#{e}'"
      end
    end

    # parse the tag to get the settings and append the message to blob
    # parameters:
    #   tag: string. the tag of the item
    #   records: string[]. an arrary of data
    def handle_record(tag, records)
      filePath = nil

      tags = tag.split('.')
      if tags.size >= 4
        # tag should have 6 parts at least:
        # tags[0]: oms
        # tags[1]: blob
        # tags[2]: container type
        # tags[3]: data type

        container_type = tags[2]
        data_type = tags[3]

        if tag.size >= 6
          # extra tags for CustomLog:
          # tags[4]: custom data type
          custom_data_type = tags[4]

          # tags[5..-1]: monitoring file path
          # concat all the rest parts with /
          filePath = tags[5..-1].join('/')

          # calculate the digest and convert it to hex
          suffix = Time.now.utc.strftime("d=%Y%m%d/#{@sha256.hexdigest(filePath)}")
        else
          custom_data_type = nil
          suffix = Time.now.utc.strftime("d=%Y%m%d/h=%H/#{SecureRandom.uuid}")
        end
      else
        raise "The tag does not have at least 4 parts #{tag}"
      end

      start = Time.now
      blob_uri, blocks_committed, blob_size = get_blob_uri_and_committed_blocks(container_type, data_type, custom_data_type, suffix)
      time = Time.now - start
      @log.debug "Success getting the BLOB information in #{time.round(3)}s"

      start = Time.now

      if @num_threads > 1
        # get a lock for the blob append to avoid storage errors when parallel threads are writing
        BlockLock.lock
        begin
          dataSize, etag = append_blob(blob_uri, records, filePath, blocks_committed)
        ensure
          BlockLock.unlock
        end
      else
        dataSize, etag = append_blob(blob_uri, records, filePath, blocks_committed)
      end

      time = Time.now - start
      @log.debug "Success sending #{dataSize} bytes of data to BLOB #{time.round(3)}s"

      start = Time.now
      notify_blob_upload_complete(blob_uri, data_type, custom_data_type, blob_size, dataSize, etag)
      time = Time.now - start
      @log.trace "Success notify the data to BLOB #{time.round(3)}s"
      write_status_file("true","Sending success")
      return OMS::Telemetry.push_qos_event(OMS::SEND_BATCH, "true", "", tag, records, records.size, time)
    rescue OMS::RetryRequestException => e
      @log.info "Encountered retryable exception. Will retry sending data later."
      @log.debug "Error:'#{e}'"
      write_status_file("false", "Retryable exception")
      # Re-raise the exception to inform the fluentd engine we want to retry sending this chunk of data later.
      # it must be generic exception, otherwise, fluentd will stuck.
      raise e.message
    rescue => e
      msg = "Unexpected exception, dropping data. Error:'#{e}'"
      OMS::Log.error_once(msg)
      write_status_file("false","Unexpected exception")
      return msg
    end # handle_record

    # This method is called when an event reaches to Fluentd.
    # Convert the event to a raw string.
    def format(tag, time, record)
      [tag, record].to_msgpack
    end

    def self_write(chunk)
      # Group records based on their datatype because OMS does not support a single request with multiple datatypes.
      datatypes = {}
      chunk.msgpack_each {|(tag, record)|
        if !datatypes.has_key?(tag)
          datatypes[tag] = []
        end
        datatypes[tag] << record['message']
      }

      ret = []
      datatypes.each do |key, records|
        ret << {'source': key, 'event': handle_record(key, records)}
      end

      ret
    end

    # This method is called every flush interval. Send the buffer chunk to OMS.
    # 'chunk' is a buffer chunk that includes multiple formatted
    # NOTE! This method is called by (out_oms_blob) plugin thread not Fluentd's main thread. So IO wait doesn't affect other plugins.
    def write(chunk)
      # Quick exit if we are missing something
      if !OMS::Configuration.load_configuration(omsadmin_conf_path, cert_path, key_path)
        raise 'Missing configuration. Make sure to onboard. Will continue to buffer data.'
      end

      if run_in_background
        OMS::BackgroundJobs.instance.run_job_and_wait { self_write(chunk) }
      else
        self_write(chunk)
      end
    end

  end # Class

end # Module

