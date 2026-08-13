# frozen_string_literal: true

module Pinspec
  # 0.1.0 is the cut spec v0.3 section 13 names, at M1, once `pinspec analyze` is a
  # usable standalone hazard report. It ships later than that milestone rather than
  # earlier: M0 through M4 and the code for M5 are all in, so the first published
  # version is one that can pin, verify and score rather than only analyze. The spec
  # names no version between M1 and 1.0, and inventing one here would be a scheme
  # nothing else in the project shares.
  VERSION = "0.1.0"

  # Bumping either of these regenerates artifacts rather than reinterpreting them
  # (spec v0.3 §9).
  PROBE_VERSION      = 3
  SERIALIZER_VERSION = 3
end
