defmodule Seer do
  @moduledoc """
  Anti-sybil and request gating for Tor hidden services.

  Seer provides PoW challenges, per-circuit rate limiting, adaptive
  difficulty scaling, Tor circuit extraction, and escalating penalties.
  The consumer defines its operation types and limits; Seer enforces
  them.

  ## Components

  * `Seer.Challenge`: Hashcash-style PoW generation and verification
  * `Seer.NonceStore`: ETS-backed nonce lifecycle tracking
  * `Seer.Difficulty`: adaptive difficulty scaling via EMA
  * `Seer.RateLimiter`: per-circuit and global sliding window rate limits
  * `Seer.Circuit`: Tor circuit ID extraction from connections
  * `Seer.Escalation`: graduated penalty escalation for abuse
  """
end
