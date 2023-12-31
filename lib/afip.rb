# frozen_string_literal: true

require "forwardable"
require "uri"
require "json"
require "net/http"

require_relative "afip/version"
require_relative "afip/web_service"
require_relative "afip/electronic_billing"
require_relative "afip/register_inscription_proof"
require_relative "afip/register_scope_ten"
require_relative "afip/register_scope_thirteen"

# AfipSDK is the easyest way to connect with AFIP
module Afip
  def self.new(options)
    Afip::Instance.new(options)
  end

  class Instance
    attr_accessor :CUIT,
                  :cert,
                  :key,
                  :production,
                  :access_token,
                  :ElectronicBilling,
                  :RegisterInscriptionProof,
                  :RegisterScopeTen,
                  :RegisterScopeThirteen

    def initialize(options)
      raise "CUIT field is required in options" unless options.key?(:CUIT)

      self.CUIT = options[:CUIT]
      self.production = options.key?(:production) ? options[:production] : false
      self.cert = options[:cert]
      self.key = options[:key]
      self.access_token = options[:access_token]

      self.ElectronicBilling = Afip::WebServices::ElectronicBilling.new(self)
      self.RegisterInscriptionProof = Afip::WebServices::RegisterInscriptionProof.new(self)
      self.RegisterScopeTen = Afip::WebServices::RegisterScopeTen.new(self)
      self.RegisterScopeThirteen = Afip::WebServices::RegisterScopeThirteen.new(self)
    end

    # Gets token authorization for an AFIP Web Service
    #
    # If force is true it forces to create a new TA
    def getServiceTA(service, force = false)
      url = URI("https://app.afipsdk.com/api/v1/afip/auth")

      https = Net::HTTP.new(url.host, url.port)
      https.use_ssl = true

      request = Net::HTTP::Post.new(url)
      request["Content-Type"] = "application/json"
      request["sdk-version-number"] = Afip::VERSION
      request["sdk-library"] = "ruby"
      request["sdk-environment"] = production == true ? "prod" : "dev"
      request["Authorization"] = "Bearer #{access_token}" if access_token

      data = {
        "environment": production == true ? "prod" : "dev",
        "tax_id": self.CUIT,
        "wsid": service,
        "force_create": force
      }

      data["cert"] = cert if cert
      data["key"] = key if key

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

    # Get last request and last response XML
    def getLastRequestXML
      url = URI("https://app.afipsdk.com/api/v1/afip/requests/last-xml")

      https = Net::HTTP.new(url.host, url.port)
      https.use_ssl = true

      request = Net::HTTP::Get.new(url)
      request["sdk-version-number"] = Afip::VERSION
      request["sdk-library"] = "ruby"
      request["sdk-environment"] = production == true ? "prod" : "dev"
      request["Authorization"] = "Bearer #{access_token}" if access_token

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

    # Create generic Web Service
    def webService(service, options = {})
      options[:service] = service
      options[:generic] = true

      Afip::WebService.new(self, options)
    end
  end
end
