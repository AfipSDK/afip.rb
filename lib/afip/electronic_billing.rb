# frozen_string_literal: true

module Afip
  module WebServices
    class ElectronicBilling < Afip::WebService
      @soapv12 = true
      @WSDL = "https://servicios1.afip.gov.ar/wsfev1/service.asmx?WSDL"
      @URL = "https://servicios1.afip.gov.ar/wsfev1/service.asmx"
      @WSDL_TEST = "https://wswhomo.afip.gov.ar/wsfev1/service.asmx?WSDL"
      @URL_TEST = "https://wswhomo.afip.gov.ar/wsfev1/service.asmx"

      def initialize(afip)
        super(afip, { "service": "wsfe" })
      end

      # Create PDF
      def createPDF(data)
        url = URI("https://app.afipsdk.com/api/v1/pdfs")

        https = Net::HTTP.new(url.host, url.port)
        https.use_ssl = true

        request = Net::HTTP::Post.new(url)
        request["Content-Type"] = "application/json"
        request["sdk-version-number"] = afip::VERSION
        request["sdk-library"] = "ruby"
        request["sdk-environment"] = afip.production == true ? "prod" : "dev"
        request["Authorization"] = "Bearer #{afip.access_token}" if afip.access_token

        request.body = JSON.dump(data)
        response = https.request(request)

        unless response.is_a? Net::HTTPSuccess
          begin
            raise JSON.parse(response.read_body)
          rescue
            raise response.read_body
          end
        end

        response_data = JSON.parse(response.read_body)

        { "file" => response_data["file"], "file_name" => response_data["file_name"] }
      end

      # Gets last voucher number
      def getLastVoucher(sales_point, type)
        req = {
          "PtoVta": sales_point,
          "CbteTipo": type
        }

        executeRequest("FECompUltimoAutorizado", req)["CbteNro"]
      end

      # Create a voucher from AFIP
      def createVoucher(data, return_response = false)
        # Reassign data to avoid modify te original object
        data = JSON.parse(data.to_json)

        req = {
          "FeCAEReq": {
            "FeCabReq": {
              "CantReg": data["CbteHasta"] - data["CbteDesde"] + 1,
              "PtoVta": data["PtoVta"],
              "CbteTipo": data["CbteTipo"]
            },
            "FeDetReq": {
              "FECAEDetRequest": data
            }
          }
        }

        data.delete("CantReg")
        data.delete("PtoVta")
        data.delete("CbteTipo")

        data["Tributos"] = { "Tributo": data["Tributos"] } if data["Tributos"]
        data["Iva"] = { "AlicIva": data["Iva"] } if data["Iva"]
        data["CbtesAsoc"] = { "CbteAsoc": data["CbtesAsoc"] } if data["CbtesAsoc"]
        data["Compradores"] = { "Comprador": data["Compradores"] } if data["Compradores"]
        data["Opcionales"] = { "Opcional": data["Opcionales"] } if data["Opcionales"]

        results = executeRequest("FECAESolicitar", req)

        if return_response == true
          results
        else
          if results["FeDetResp"]["FECAEDetResponse"].is_a?(Array)
            results["FeDetResp"]["FECAEDetResponse"] = results["FeDetResp"]["FECAEDetResponse"][0]
          end

          {
            "CAE" => results["FeDetResp"]["FECAEDetResponse"]["CAE"],
            "CAEFchVto" => formatDate(results["FeDetResp"]["FECAEDetResponse"]["CAEFchVto"])
          }
        end
      end

      # Create next voucher from AFIP
      def createNextVoucher(data)
        # Stringify keys
        data = JSON.parse(data.to_json)

        lastVoucher = getLastVoucher(data["PtoVta"], data["CbteTipo"])

        voucherNumber = lastVoucher + 1

        data["CbteDesde"] = voucherNumber
        data["CbteHasta"] = voucherNumber

        res = createVoucher(data)

        res["voucherNumber"] = voucherNumber

        res
      end

      # Get complete voucher information
      def getVoucherInfo(number, sales_point, type)
        req = {
          "FeCompConsReq": {
            "CbteNro": number,
            "PtoVta": sales_point,
            "CbteTipo": type
          }
        }

        executeRequest("FECompConsultar", req)
      end

      # Create CAEA
      def createCAEA(period, fortnight)
        req = {
          "Periodo": period,
          "Orden": fortnight
        }

        executeRequest("FECAEASolicitar", req)["ResultGet"]
      end

      # Get CAEA
      def getCAEA(period, fortnight)
        req = {
          "Periodo": period,
          "Orden": fortnight
        }

        executeRequest("FECAEAConsultar", req)["ResultGet"]
      end

      # Asks to AFIP Servers for available sales points
      def getSalesPoints
        executeRequest("FEParamGetPtosVenta")["ResultGet"]["PtoVenta"]
      end

      # Asks to AFIP Servers for available voucher types
      def getVoucherTypes
        executeRequest("FEParamGetTiposCbte")["ResultGet"]["CbteTipo"]
      end

      # Asks to AFIP Servers for voucher concepts availables
      def getConceptTypes
        executeRequest("FEParamGetTiposConcepto")["ResultGet"]["ConceptoTipo"]
      end

      # Asks to AFIP Servers for document types availables
      def getDocumentTypes
        executeRequest("FEParamGetTiposDoc")["ResultGet"]["DocTipo"]
      end

      # Asks to AFIP Servers for available aliquotes
      def getAliquotTypes
        executeRequest("FEParamGetTiposIva")["ResultGet"]["IvaTipo"]
      end

      # Asks to AFIP Servers for available currencies
      def getCurrenciesTypes
        executeRequest("FEParamGetTiposMonedas")["ResultGet"]["Moneda"]
      end

      # Asks to AFIP Servers for available voucher optional data
      def getOptionsTypes
        executeRequest("FEParamGetTiposOpcional")["ResultGet"]["OpcionalTipo"]
      end

      # Asks to AFIP Servers for available tax types
      def getTaxTypes
        executeRequest("FEParamGetTiposTributos")["ResultGet"]["TributoTipo"]
      end

      # Asks to web service for servers status
      def getServerStatus
        executeRequest("FEDummy")
      end

      # Change date from AFIP used format (yyyymmdd) to yyyy-mm-dd
      def formatDate(date)
        m = /(?<year>\d{4})(?<month>\d{2})(?<day>\d{2})/.match(date.to_s)

        "#{m[:year]}-#{m[:month]}-#{m[:day]}"
      end

      # Sends request to AFIP servers
      def executeRequest(operation, params = {})
        params.merge!(getWSInitialRequest(operation))

        results = super(operation, params)

        checkErrors(operation, results)

        results["#{operation}Result"]
      end

      # Prepare default request parameters for most operations
      def getWSInitialRequest(operation)
        if operation == "FEDummy"
          {}
        else
          ta = afip.getServiceTA("wsfe")

          {
            "Auth": {
              "Token": ta["token"],
              "Sign": ta["sign"],
              "Cuit": afip.CUIT
            }
          }
        end
      end

      # Check if occurs an error on Web Service request
      def checkErrors(operation, results)
        res = results["#{operation}Result"]

        if operation == "FECAESolicitar" && res["FeDetResp"]
          if res["FeDetResp"]["FECAEDetResponse"].is_a?(Array)
            res["FeDetResp"]["FECAEDetResponse"] = res["FeDetResp"]["FECAEDetResponse"][0]
          end

          if res["FeDetResp"]["FECAEDetResponse"]["Observaciones"] && res["FeDetResp"]["FECAEDetResponse"]["Resultado"] != "A"
            res["Errors"] = { "Err" => res["FeDetResp"]["FECAEDetResponse"]["Observaciones"]["Obs"] }
          end
        end

        return unless res["Errors"]

        err = res["Errors"]["Err"].is_a?(Array) ? res["Errors"]["Err"][0] : res["Errors"]["Err"]

        raise "(#{err["Code"]}) #{err["Msg"]}"
      end

      private :checkErrors
    end
  end
end
