# frozen_string_literal: true

require "openssl"

module Afip
  # Error of the Factura SDK API
  #
  # Carries the HTTP status and the body of the response: message, the problems by field in
  # data_errors and the rules the invoice did not meet in errors (https://afipsdk.com/docs/facturasdk/errors)
  class FacturaSDKError < StandardError
    attr_reader :status, :data, :data_errors, :errors

    def initialize(message, status = nil, data = nil)
      super(message)

      @status = status
      @data = data

      # A failed automation answers { status: "error", data: { message, data_errors, errors } }
      detail = self.class.detail_of(data)

      @data_errors = detail["data_errors"].is_a?(Hash) ? detail["data_errors"] : nil
      @errors = detail["errors"].is_a?(Array) ? detail["errors"] : nil
    end

    # Build the error from a failed response of the API
    def self.from_response(response)
      body = response.body.to_s

      data = begin
        body.empty? ? nil : JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      detail = detail_of(data)
      parts = []

      parts << detail["message"] if detail["message"]

      detail["errors"].each { |error| parts << "#{error["code"]}: #{error["message"]}" } if detail["errors"].is_a?(Array)

      parts.concat(flatten_data_errors(detail["data_errors"])) if detail["data_errors"].is_a?(Hash)

      message = if !parts.empty?
                  parts.join(" ")
                elsif data.nil? && !body.empty?
                  body
                else
                  "Factura SDK respondió #{response.code}"
                end

      new(message, response.code.to_i, data)
    end

    # Where the message, data_errors and errors live in a body: the body itself, or data when the
    # body is a failed automation
    def self.detail_of(data)
      return {} unless data.is_a?(Hash)

      return data["data"] if data["status"] == "error" && data["data"].is_a?(Hash)

      data
    end

    # { receiver: { vat_condition: "mensaje" } } -> ["receiver.vat_condition: mensaje"]
    def self.flatten_data_errors(errors, prefix = "")
      errors.flat_map do |field, value|
        path = prefix.empty? ? field.to_s : "#{prefix}.#{field}"

        value.is_a?(Hash) ? flatten_data_errors(value, path) : ["#{path}: #{value}"]
      end
    end
  end

  # SDK for Factura SDK: electronic invoicing end to end
  #
  # Issuers, certificates, invoices and webhooks of a Factura SDK project. The access token
  # (fsk_dev_… for the sandbox, fsk_prod_… for production) decides the environment.
  #
  # https://afipsdk.com/docs/facturasdk/
  class FacturaSDK
    PENDING_INVOICE_STATUSES = %w[queued processing].freeze

    REQUEST_CLASSES = {
      get: Net::HTTP::Get,
      post: Net::HTTP::Post,
      put: Net::HTTP::Put,
      delete: Net::HTTP::Delete
    }.freeze

    # api_url: base URL of the Factura SDK API. access_token: the one sent in every request
    # (the access token of Afip). environment: the one reported to the
    # API, from the token when it is a Factura SDK token. The intervals are the seconds between
    # polls and the attempts before giving up: automations (ARCA with the tax password,
    # verification) take from seconds to a couple of minutes, an invoice is authorized in seconds
    attr_accessor :afip, :api_url, :access_token, :environment,
                  :automation_interval, :automation_attempts, :invoice_interval, :invoice_attempts

    def initialize(afip)
      self.afip = afip
      self.api_url = "https://app.afipsdk.com/api/v1"
      self.access_token = afip.access_token

      self.environment = if access_token.to_s.start_with?("fsk_prod_")
                           "prod"
                         elsif access_token.to_s.start_with?("fsk_dev_")
                           "dev"
                         else
                           afip.production == true ? "prod" : "dev"
                         end

      self.automation_interval = 3
      self.automation_attempts = 60
      self.invoice_interval = 2
      self.invoice_attempts = 60
    end

    # Invoices

    # Issue an invoice
    #
    # By default Factura SDK answers right away with the invoice queued and authorizes it in ARCA
    # in the background: the result arrives at your webhook. Options: idempotency_key (identifier
    # of the sale in your system; repeating it returns the same invoice instead of issuing another
    # one) and wait (polls until the invoice is decided). With "sync": true in the data Factura SDK
    # decides it within the request
    def createInvoice(data, options = {})
      idempotency_key = option(options, :idempotency_key)
      headers = idempotency_key ? { "Idempotency-Key" => idempotency_key } : {}

      invoice = request(:post, "invoices", data, {}, headers)

      return waitForInvoice(invoice["id"]) if option(options, :wait) == true && pending?(invoice)

      invoice
    end

    # Get an invoice with its current status. With wait, waits until it reaches a final status
    def getInvoice(id, wait = false)
      return waitForInvoice(id) if wait == true

      request(:get, "invoices/#{id}")
    end

    # Wait for an invoice to be decided: approved, rejected or failed
    #
    # Polls the invoice every 2 seconds for up to 2 minutes. The invoice keeps its course in
    # Factura SDK if the wait ends; the result still arrives at your webhook
    def waitForInvoice(id)
      attempts = invoice_attempts

      while (attempts -= 1) >= 0
        invoice = request(:get, "invoices/#{id}")

        return invoice unless pending?(invoice)

        sleep(invoice_interval)
      end

      raise "Error: Waiting for too long"
    end

    # List invoices, newest first, with cursor pagination
    #
    # Filters: issuer_cuit, status, invoice_type, start, end, limit, cursor
    def getInvoices(params = {})
      request(:get, "invoices", nil, params)
    end

    # Cancel an invoice that is still queued. It never gets issued
    def cancelInvoice(id)
      request(:post, "invoices/#{id}/cancel")
    end

    # Issuers

    # Create an issuer: a tax id that invoices. It is created pending and invoices once verified
    def createIssuer(data)
      request(:post, "issuers", data)
    end

    # Get an issuer
    def getIssuer(id)
      request(:get, "issuers/#{id}")
    end

    # List issuers, with cursor pagination
    #
    # Filters: tax_id, certificate_id, status, limit, cursor
    def getIssuers(params = {})
      request(:get, "issuers", nil, params)
    end

    # Update an issuer: only the fields sent change
    def updateIssuer(id, data)
      request(:put, "issuers/#{id}", data)
    end

    # Delete an issuer. Its invoices remain
    def deleteIssuer(id)
      request(:delete, "issuers/#{id}")

      nil
    end

    # Get the data of a tax id from its registration certificate in ARCA, to create the issuer
    # without typing them
    def lookupIssuer(tax_id)
      request(:get, "issuers/lookup", nil, { "tax_id" => tax_id })
    end

    # List the sales points of a tax id in ARCA, with its tax password (tax_id, username, password)
    #
    # It is an automation: with wait returns it finished, with the sales points in data
    def getSalesPoints(data, wait = true)
      automation(request(:post, "issuers/sales-points", data), wait)
    end

    # Create in ARCA a sales point for web services for a tax id, with its tax password (tax_id,
    # username, password and optionally vat_condition, number, name, system)
    #
    # It is an automation: with wait returns it finished, with the sales point in data
    def createSalesPoint(data, wait = true)
      automation(request(:post, "issuers/sales-points/create", data), wait)
    end

    # Create a certificate for the issuer and assign it
    #
    # Uploaded (cert and key in PEM) it answers the certificate. Created in ARCA (source
    # "automation", with username and password) it is an automation: with wait returns it
    # finished, with the certificate in data
    def createIssuerCertificate(id, data, wait = true)
      automation(request(:post, "issuers/#{id}/certificate", data), wait)
    end

    # Accept in ARCA the delegation of the issuer to the owner of its certificate and authorize
    # the certificate to invoice for it, with the tax password of the certificate owner (username,
    # password)
    #
    # It is an automation: with wait returns it finished
    def createIssuerDelegation(id, data, wait = true)
      automation(request(:post, "issuers/#{id}/delegation", data), wait)
    end

    # Verify an issuer: issues a $1 invoice and the credit note that cancels it, and the issuer
    # becomes active. In production both vouchers are real
    #
    # It is an automation: with wait returns it finished, with verified, issuer, invoice and
    # credit_note in data
    def verifyIssuer(id, wait = true)
      automation(request(:post, "issuers/#{id}/verify"), wait)
    end

    # Certificates

    # Add a certificate to the project
    #
    # Uploaded (cert and key in PEM) it answers the certificate. Created in ARCA (source
    # "automation", with tax_id, username and password) it is an automation: with wait returns it
    # finished, with the certificate in data
    def createCertificate(data, wait = true)
      automation(request(:post, "certificates", data), wait)
    end

    # Get a certificate
    def getCertificate(id)
      request(:get, "certificates/#{id}")
    end

    # List certificates, with cursor pagination
    #
    # Filters: tax_id, status, limit, cursor
    def getCertificates(params = {})
      request(:get, "certificates", nil, params)
    end

    # Revoke a certificate: it no longer signs
    def revokeCertificate(id)
      request(:post, "certificates/#{id}/revoke")
    end

    # Authorize a certificate in ARCA for the electronic billing web service (wsfe), with the tax
    # password of its owner (password and optionally username)
    #
    # It is an automation: with wait returns it finished
    def authorizeCertificate(id, data, wait = true)
      automation(request(:post, "certificates/#{id}/authorize", data), wait)
    end

    # Webhooks

    # Create the webhook endpoint (url): the URL where Factura SDK posts the result of each
    # invoice. The answer brings the secret, shown only this once
    def createWebhookEndpoint(data)
      request(:post, "webhook-endpoints", data)
    end

    # Get a webhook endpoint
    def getWebhookEndpoint(id)
      request(:get, "webhook-endpoints/#{id}")
    end

    # List webhook endpoints
    #
    # Filters: status
    def getWebhookEndpoints(params = {})
      request(:get, "webhook-endpoints", nil, params)
    end

    # Update a webhook endpoint: url or status (active or inactive)
    def updateWebhookEndpoint(id, data)
      request(:put, "webhook-endpoints/#{id}", data)
    end

    # Generate a new secret for a webhook endpoint. From then on every delivery is signed with it
    def rotateWebhookEndpointSecret(id)
      request(:post, "webhook-endpoints/#{id}/rotate")
    end

    # Send a signed test event to a webhook endpoint
    def testWebhookEndpoint(id)
      request(:post, "webhook-endpoints/#{id}/test")
    end

    # List the deliveries of a webhook endpoint: what was sent, when and with what result
    #
    # Filters: status, invoice_id, limit, cursor
    def getWebhookDeliveries(id, params = {})
      request(:get, "webhook-endpoints/#{id}/deliveries", nil, params)
    end

    # Verify the signature of a webhook delivery
    #
    # The X-FacturaSDK-Signature header is "t=<timestamp>,v1=<signature>", where v1 is the
    # HMAC-SHA256 of "<timestamp>.<body>" with the secret of the endpoint. The body has to be the
    # raw one received, byte by byte (request.body.read). tolerance is how many seconds the
    # timestamp may differ from now
    def verifyWebhookSignature(signature, body, secret, tolerance = 300)
      return false unless signature.is_a?(String) && !secret.to_s.empty?

      parts = signature.split(",").each_with_object({}) do |part, hash|
        name, value = part.split("=", 2)
        hash[name] = value.to_s
      end

      return false unless parts["t"].to_s.match?(/\A\d+\z/)

      timestamp = parts["t"].to_i
      received = parts["v1"].to_s

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")

      fresh = (Time.now.to_i - timestamp).abs <= tolerance

      fresh && secure_compare(expected, received)
    end

    # Verify the signature of a webhook delivery and parse its event (event_id, type, created, data)
    #
    # Raises FacturaSDKError if the signature is not valid
    def constructWebhookEvent(body, signature, secret, tolerance = 300)
      raise FacturaSDKError, "La firma del webhook no es válida" unless verifyWebhookSignature(signature, body, secret, tolerance)

      JSON.parse(body)
    end

    # Automations

    # Get an automation. With wait, waits for it to finish
    #
    # Raises FacturaSDKError if the automation finished with an error
    def getAutomation(id, wait = false)
      return waitForAutomation(id) if wait == true

      request(:get, "automations/#{id}")
    end

    # Wait for an automation to finish. Polls it every 3 seconds for up to 3 minutes
    #
    # Raises FacturaSDKError if the automation finished with an error
    def waitForAutomation(id)
      attempts = automation_attempts

      while (attempts -= 1) >= 0
        automation = request(:get, "automations/#{id}")

        return automation if automation["status"] != "in_process"

        sleep(automation_interval)
      end

      raise "Error: Waiting for too long"
    end

    private

    # Resolve the answer of an endpoint that may start an automation: when it did (202 with
    # automation_id) and wait is set, waits for it to finish
    def automation(result, wait)
      return waitForAutomation(result["automation_id"]) if wait == true && result.is_a?(Hash) && result["automation_id"]

      result
    end

    def pending?(invoice)
      invoice.is_a?(Hash) && PENDING_INVOICE_STATUSES.include?(invoice["status"])
    end

    # An option by its symbol or string key
    def option(options, name)
      options[name] || options[name.to_s]
    end

    # Compare two strings in constant time
    def secure_compare(expected, received)
      return false unless expected.bytesize == received.bytesize

      expected.bytes.zip(received.bytes).inject(0) { |result, (left, right)| result | (left ^ right) }.zero?
    end

    # Send a request to the Factura SDK API. Raises FacturaSDKError if the API answers an error
    def request(method, path, data = nil, params = {}, headers = {})
      uri = URI("#{api_url}/#{path}")
      uri.query = URI.encode_www_form(params) unless params.nil? || params.empty?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 30

      request = REQUEST_CLASSES.fetch(method).new(uri)
      request["Content-Type"] = "application/json"
      request["sdk-version-number"] = Afip::VERSION
      request["sdk-library"] = "ruby"
      request["sdk-environment"] = environment
      request["Authorization"] = "Bearer #{access_token}" if access_token
      headers.each { |name, value| request[name] = value }
      request.body = JSON.dump(data) unless data.nil?

      response = http.request(request)

      raise FacturaSDKError.from_response(response) unless response.is_a?(Net::HTTPSuccess)

      body = response.body.to_s

      body.empty? ? nil : JSON.parse(body)
    end
  end
end
