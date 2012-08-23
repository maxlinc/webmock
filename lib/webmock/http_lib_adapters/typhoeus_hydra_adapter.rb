begin
  require 'typhoeus'
rescue LoadError
  # typhoeus not found
end

if defined?(Typhoeus)
  WebMock::VersionChecker.new('Typhoeus', Typhoeus::VERSION, '0.3.2').check_version!

  module WebMock
    module HttpLibAdapters
      class TyphoeusAdapter < HttpLibAdapter
        adapter_for :typhoeus

        def self.enable!
          @disabled = false
          add_after_request_callback
          ::Typhoeus::Config.block_connection = true
        end

        def self.disable!
          @disabled = true
          remove_after_request_callback
          ::Typhoeus::Config.block_connection = false
        end

        def self.disabled?
          !!@disabled
        end

        def self.add_after_request_callback
          unless Typhoeus.on_complete.include?(AFTER_REQUEST_CALLBACK)
            Typhoeus.on_complete << AFTER_REQUEST_CALLBACK
          end
        end

        def self.remove_after_request_callback
          Typhoeus.on_complete.delete_if {|v| v == AFTER_REQUEST_CALLBACK }
        end

        def self.build_request_signature(req)
          uri = WebMock::Util::URI.heuristic_parse(req.url)
          uri.path = uri.normalized_path.gsub("[^:]//","/")
          if req.options[:userpwd]
            uri.user, uri.password = req.options[:userpwd].split(':')
          end

          body = req.options[:body]

          if req.params && req.method == :post
            body = request_body_for_post_request_with_params(req)
          end

          request_signature = WebMock::RequestSignature.new(
            req.options[:method],
            uri.to_s,
            :body => body,
            :headers => req.options[:headers]
          )

          req.instance_variable_set(:@__webmock_request_signature, request_signature)

          request_signature
        end

        def self.request_body_for_post_request_with_params(req)
          params = req.params
          form = Typhoeus::Form.new(params)
          form.process!
          form.to_s
        end

        def self.build_webmock_response(typhoeus_response)
          webmock_response = WebMock::Response.new
          webmock_response.status = [typhoeus_response.code, typhoeus_response.status_message]
          webmock_response.body = typhoeus_response.body
          webmock_response.headers = typhoeus_response.header
          webmock_response
        end

        def self.stub_typhoeus(request_signature, webmock_response, typhoeus)
          response = if webmock_response.should_timeout
            ::Typhoeus::Response.new(
              :code         => 0,
              :status_message => "",
              :body         => "",
              :header => {},
              :return_code => 28
            )
          else
            ::Typhoeus::Response.new(
              :code         => webmock_response.status[0],
              :status_message => webmock_response.status[1],
              :body         => webmock_response.body,
              :header => webmock_response.headers
            )
          end

          Typhoeus.stub(
            nil,
            :method => request_signature.method,
          ).stubbed_from(:webmock).and_return(response)
        end

        def self.request_hash(request_signature)
          hash = {}

          hash[:body]    = request_signature.body
          hash[:headers] = request_signature.headers

          hash
        end

        AFTER_REQUEST_CALLBACK = Proc.new do |response|
          request = response.request
          request_signature = request.instance_variable_get(:@__webmock_request_signature)
          webmock_response =
            ::WebMock::HttpLibAdapters::TyphoeusAdapter.
              build_webmock_response(response)
          if response.mock
            WebMock::CallbackRegistry.invoke_callbacks(
              {:lib => :typhoeus},
              request_signature,
              webmock_response
            )
          else
            WebMock::CallbackRegistry.invoke_callbacks(
              {:lib => :typhoeus, :real_request => true},
              request_signature,
              webmock_response
            )
          end
        end
      end
    end
  end


  module Typhoeus
    class Hydra
      def queue_with_webmock(request)
        self.clear_webmock_stubs

        if WebMock::HttpLibAdapters::TyphoeusAdapter.disabled?
          return queue_without_webmock(request)
        end

        request_signature =
         ::WebMock::HttpLibAdapters::TyphoeusAdapter.build_request_signature(request)

        ::WebMock::RequestRegistry.instance.requested_signatures.put(request_signature)

        if webmock_response = ::WebMock::StubRegistry.instance.response_for_request(request_signature)
          ::WebMock::HttpLibAdapters::TyphoeusAdapter.
            stub_typhoeus(request_signature, webmock_response, self)
          webmock_response.raise_error_if_any
        elsif !WebMock.net_connect_allowed?(request_signature.uri)
          raise WebMock::NetConnectNotAllowedError.new(request_signature)
        end
        queue_without_webmock(request)
      end

      alias_method :queue_without_webmock, :queue
      alias_method :queue, :queue_with_webmock

      def clear_webmock_stubs
        Typhoeus::Expectation.all.delete_if {|e|
          e.from == :webmock
        }
      end
    end
  end
end
