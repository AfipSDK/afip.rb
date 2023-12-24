# frozen_string_literal: true

module Afip
  class AfipConfiguration
    @production = false

    attr_accessor :CUIT, :cert, :key, :production, :access_token
  end
end
