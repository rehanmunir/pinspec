# frozen_string_literal: true

module Pinspec
  # 0.1.0 is cut at M1 (spec v0.3 §13) once `pinspec analyze` is a usable
  # standalone hazard report. Everything before that is 0.0.x.
  VERSION = "0.0.1"

  # Bumping either of these regenerates artifacts rather than reinterpreting them
  # (spec v0.3 §9). Neither is live until M3.
  PROBE_VERSION      = 3
  SERIALIZER_VERSION = 3
end
