# frozen_string_literal: true

module Afip
  module WebServices
    class RegisterScopeThirteen < Afip::WebService
      @soapv12 = false
      @WSDL = "https://aws.afip.gov.ar/sr-padron/webservices/personaServiceA13?WSDL"
      @URL = "https://aws.afip.gov.ar/sr-padron/webservices/personaServiceA13"
      @WSDL_TEST = "https://awshomo.afip.gov.ar/sr-padron/webservices/personaServiceA13?WSDL"
      @URL_TEST = "https://awshomo.afip.gov.ar/sr-padron/webservices/personaServiceA13"

      def initialize(afip)
        super(afip, { "service": "ws_sr_padron_a13" })
      end

      # Asks to web service for taxpayer details
      def getTaxpayerDetails(identifier)
        # Get token and sign
        ta = getTokenAuthorization

        # Prepare params
        params = {
          "token": ta["token"],
          "sign": ta["sign"],
          "cuitRepresentada": afip.CUIT,
          "idPersona": identifier
        }

        executeRequest("getPersona", params)
      end

      # Asks to web service for tax id by document number
      def getTaxIDByDocument(document_number)
        # Get token and sign
        ta = getTokenAuthorization

        # Prepare params
        params = {
          "token": ta["token"],
          "sign": ta["sign"],
          "cuitRepresentada": afip.CUIT,
          "documento": document_number
        }

        executeRequest("getIdPersonaListByDocumento", params)["idPersona"]
      end

      # Asks to web service for servers status
      def getServerStatus
        executeRequest("dummy")
      end

      # Send request to AFIP servers
      def executeRequest(operation, params = {})
        results = super(operation, params)

        if operation == "getPersona"
          results["personaReturn"]
        elsif operation == "getIdPersonaListByDocumento"
          results["idPersonaListReturn"]
        else
          results["return"]
        end
      end
    end
  end
end
