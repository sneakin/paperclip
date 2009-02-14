module Paperclip
  module Storage
    # Adds :webdav as a storage option. An example use would be:
    #     has_attached_file :photo, :storage => :webdav, :webdav_url => "http://asset_host/shared", :styles => {
    #       :small => '64x64>',
    #       :medium => '128x128>',
    #       :large => '256x256>'
    #     }
    module Webdav
      def self.extended(base)
        base.instance_eval do
          @webdav_url = URI.parse(@options[:webdav_url])
          @username = @options[:username]
          @password = @options[:password]
          @url  = ":webdav_url"
          @path = ":attachment/:id/:style/:basename.:extension"
        end
        base.class.interpolations[:webdav_url] = lambda do |attachment, style|
          "#{attachment.webdav_url}/#{attachment.path(style)}"
        end
      end
      
      attr_reader :webdav_url
      
      def exists?(style = default_style)
        return false unless original_filename

        resp = make_request(Net::HTTP::Get.new(style_path(style)))
        case resp
          when Net::HTTPSuccess then true
          else false
        end
      end
      
      # Returns representation of the data of the file assigned to the given
      # style, in the format most representative of the current storage.
      def to_file style = default_style
        return @queued_for_write[style] if @queued_for_write[style]
        
        resp = make_request(Net::HTTP::Get.new(style_path(style)))
        content_type = resp.content_type
        size = resp.content_length
        
        io = StringIO.new(resp.body)
        io.instance_eval <<-EOT
          def content_type
            "#{content_type}"
          end
        EOT

        io
      end
      alias_method :to_io, :to_file

      def flush_writes #:nodoc:
        logger.info("[paperclip] Writing files for #{name}")
        @queued_for_write.each do |style, file|
          mkdir_p(File.dirname(path(style)))
          logger.info("[paperclip] -> #{path(style)}")
          
          if exists?(path(style))
            req = Net::HTTP::Post.new(style_path(style))
          else
            req = Net::HTTP::Put.new(style_path(style))
          end

          req['Transfer-Encoding'] = 'chunked'
          req.body_stream = file
          
          result = make_request(req)
          logger.info("[paperclip] -> #{path(style)} -> #{result.class}")
        end
        @queued_for_write = {}
      end

      def flush_deletes #:nodoc:
        logger.info("[paperclip] Deleting files for #{name}")
        @queued_for_delete.each do |path|
          logger.info("[paperclip] -> #{webdav_path(path)}")
          resp = make_request(Net::HTTP::Delete.new(webdav_path(path)))
          logger.info("[paperclip]    -> #{resp.inspect}")
        end
        @queued_for_delete = []
      end
      
      protected

      def host
        @webdav_url.host
      end
      
      def port
        @webdav_url.port || 80
      end
      
      def protocol
        @webdav_url.protocol || 'http'
      end
      
      def base_path
        @webdav_url.path
      end
      
      def webdav_path(path)
        base_path + "/" + path
      end

      def style_path(style)
        webdav_path(path(style))
      end
      
      def connection
        @connection ||= Net::HTTP.new(host, port)
        @connection
      end
      
      def make_request(request)
        request.basic_auth(@username, @password) if @username
        connection.request(request)
      end
      
      def mkdir_p(path)
        logger.info("[paperclip] -> Making collection #{path}")
        parts = path.split("/")
        full_path = []
        
        parts.each { |part|
          full_path << part

          logger.info("[paperclip]   -> #{full_path.join("/")}")
          resp = make_request(Net::HTTP::Mkcol.new(webdav_path(full_path.join("/"))))
          
          unless resp.kind_of?(Net::HTTPSuccess) || resp.kind_of?(Net::HTTPRedirection)
            raise RuntimeError.new("Failed to create #{full_path.join("/")}")
          end
        }
      end
    end
  end
end
