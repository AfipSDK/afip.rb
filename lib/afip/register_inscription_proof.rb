# frozen_string_literal: true

module Afip
  module WebServices
    class RegisterInscriptionProof < Afip::WebService
      @soapv12 = false
      @WSDL = "https://aws.afip.gov.ar/sr-padron/webservices/personaServiceA5?WSDL"
      @URL = "https://aws.afip.gov.ar/sr-padron/webservices/personaServiceA5"
      @WSDL_TEST = "https://awshomo.afip.gov.ar/sr-padron/webservices/personaServiceA5?WSDL"
      @URL_TEST = "https://awshomo.afip.gov.ar/sr-padron/webservices/personaServiceA5"

      def initialize(afip)
        super(afip, { "service": "ws_sr_constancia_inscripcion" })
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

        executeRequest("getPersona_v2", params)
      end

      # Asks to web service for taxpayers details
      def getTaxpayersDetails(identifiers)
        # Get token and sign
        ta = getTokenAuthorization

        # Prepare params
        params = {
          "token": ta["token"],
          "sign": ta["sign"],
          "cuitRepresentada": afip.CUIT,
          "idPersona": identifiers
        }

        executeRequest("getPersonaList_v2", params)["persona"]
      end

      # Asks to web service for servers status
      def getServerStatus
        executeRequest("dummy")
      end

      # Send request to AFIP servers
      def executeRequest(operation, params = {})
        results = super(operation, params)

        if operation == "getPersona_v2"
          results["personaReturn"]
        elsif operation == "getPersonaList_v2"
          results["personaListReturn"]
        else
          results["return"]
        end
      end
    end
  end
end
