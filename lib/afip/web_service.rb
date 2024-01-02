# frozen_string_literal: true

module Afip
  class WebService
    # Configurable options
    attr_accessor :soapv12, :WSDL, :URL, :WSDL_TEST, :URL_TEST, :afip, :options

    def initialize(afip, options = {})
      self.afip = afip
      self.options = options

      self.WSDL = options[:WSDL] if options.key?(:WSDL)
      self.URL = options[:URL] if options.key?(:URL)
      self.WSDL_TEST = options[:WSDL_TEST] if options.key?(:WSDL_TEST)
      self.URL_TEST = options[:URL_TEST] if options.key?(:URL_TEST)

      return unless options.key?(:generic) && options[:generic] == true

      raise "service field is required in options" unless options.key?(:service)

      options[:soapV1_2] = options.key?(:soapV1_2) ? options[:soapV1_2] : false

      self.soapv12 = options[:soapV1_2]
    end

    # Gets token authorization for an AFIP Web Service
    #
    # If force is true it forces to create a new TA
    def getTokenAuthorization(force = false)
      afip.getServiceTA(options[:service], force)
    end

    # Sends request to AFIP servers
    def executeRequest(method, params = {})
      url = URI("https://app.afipsdk.com/api/v1/afip/requests")

      https = Net::HTTP.new(url.host, url.port)
      https.use_ssl = true

      request = Net::HTTP::Post.new(url)
      request["Content-Type"] = "application/json"
      request["sdk-version-number"] = Afip::VERSION
      request["sdk-library"] = "ruby"
      request["sdk-environment"] = afip.production == true ? "prod" : "dev"
      request["Authorization"] = "Bearer #{afip.access_token}" if afip.access_token

      data = {
        "method": method,
        "params": params,
        "environment": afip.production == true ? "prod" : "dev",
        "wsid": options[:service],
        "url": afip.production == true ? self.URL : self.URL_TEST,
        "wsdl": afip.production == true ? self.WSDL : self.WSDL_TEST,
        "soap_v_1_2": soapv12
      }

      request.body = JSON.dump(data)
      response = https.request(request)

      unless response.is_a? Net::HTTPSuccess
        begin
          raise JSON.parse(response.read_body)
        rescue
          raise response.read_body
        end
      end

      JSON.parse(response.read_body)
    end
  end
end
