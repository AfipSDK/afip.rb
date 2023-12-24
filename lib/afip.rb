# frozen_string_literal: true

require "forwardable"
require "uri"
require "json"
require "net/http"

require_relative "afip/version"
require_relative "afip/config"
require_relative "afip/web_service"
require_relative "afip/electronic_billing"

# AfipSDK is the easyest way to connect with AFIP
module Afip
  @config = Afip::AfipConfiguration.new

  @ElectronicBilling = Afip::WebServices::ElectronicBilling.new(self)

  class << self
    extend Forwardable

    attr_reader :ElectronicBilling, :config

    # User configurable options
    def_delegators :@config, :CUIT, :CUIT=
    def_delegators :@config, :cert, :cert=
    def_delegators :@config, :key, :key=
    def_delegators :@config, :production, :production=
    def_delegators :@config, :access_token, :access_token=
  end

  # Gets token authorization for an AFIP Web Service
  #
  # If force is true it forces to create a new TA
  def self.getServiceTA(service, force = false)
    url = URI("https://app.afipsdk.com/api/v1/afip/auth")

    https = Net::HTTP.new(url.host, url.port)
    https.use_ssl = true

    request = Net::HTTP::Post.new(url)
    request["Content-Type"] = "application/json"
    request["sdk-version-number"] = Afip::VERSION
    request["sdk-library"] = "ruby"
    request["sdk-environment"] = @config.production == true ? "prod" : "dev"
    request["Authorization"] = "Bearer #{@config.access_token}" if @config.access_token

    data = {
      "environment": @config.production == true ? "prod" : "dev",
      "tax_id": @config.CUIT,
      "wsid": service,
      "force_create": force
    }

    data["cert"] = @config.cert if @config.cert
    data["key"] = @config.key if @config.key

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
  def self.getLastRequestXML
    url = URI("https://app.afipsdk.com/api/v1/afip/requests/last-xml")

    https = Net::HTTP.new(url.host, url.port)
    https.use_ssl = true

    request = Net::HTTP::Get.new(url)
    request["sdk-version-number"] = Afip::VERSION
    request["sdk-library"] = "ruby"
    request["sdk-environment"] = @config.production == true ? "prod" : "dev"
    request["Authorization"] = "Bearer #{@config.access_token}" if @config.access_token

    data["cert"] = @config.cert if @config.cert
    data["key"] = @config.key if @config.key

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
  def self.webService(service, options = {})
    options[:service] = service
    options[:generic] = true

    Afip::WebService.new(self, options)
  end
end
