# Seer

Anti-sybil and request gating for Tor hidden services.

PoW challenges, per-circuit rate limiting, adaptive difficulty scaling, Tor circuit extraction, and escalating penalties. Products configure their operation types and limits — Seer handles enforcement.

## Installation

Add `seer` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:seer, path: "../seer"}
  ]
end
```

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                              seer                               │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │  Challenge   │  │  NonceStore  │  │    Difficulty        │   │
│  │  (Hashcash)  │  │    (ETS)     │  │  (adaptive EMA)      │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ RateLimiter  │  │  Escalation  │  │  Circuit.Extractor   │   │
│  │(sliding win) │  │ (penalties)  │  │  (Tor circuit ID)    │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Modules

| Module | Purpose |
|--------|---------|
| `Seer.Challenge` | Hashcash-style PoW generation and verification |
| `Seer.NonceStore` | ETS-backed nonce lifecycle tracking |
| `Seer.Difficulty` | Adaptive difficulty scaling via exponential moving average |
| `Seer.RateLimiter` | Per-circuit and global sliding window rate limits |
| `Seer.Escalation` | Graduated penalty escalation for abusive circuits |
| `Seer.Circuit.Extractor` | Tor circuit ID extraction from Plug connections |

## Usage

### PoW Challenges

```elixir
alias Seer.Challenge

# Generate a challenge
challenge = Challenge.generate(20)

# Return 402 with challenge headers
headers = Challenge.format_headers(challenge)

# Verify a submitted solution
:ok = Challenge.verify(nonce, solution, 20)
```

### Adaptive Difficulty

```elixir
alias Seer.Difficulty

Difficulty.start_link(
  min_difficulty: 12,
  max_difficulty: 28,
  low_threshold: 10
)

# Lock-free read from :persistent_term
Difficulty.current()       # 12

# Record requests — difficulty scales with throughput
Difficulty.record_request()
Difficulty.stats()         # %{difficulty: 16, ema_rate: 45.2, ...}
```

### Rate Limiting

```elixir
alias Seer.RateLimiter

RateLimiter.start_link(
  limits: %{
    read: {100, 60},      # 100 requests per 60 seconds
    write: {10, 300},      # 10 per 5 minutes
    expensive: {5, 300}    # 5 per 5 minutes
  }
)

# Check rate limit for a circuit
:ok = RateLimiter.check(circuit_id, :write)
{:error, :rate_limited} = RateLimiter.check(circuit_id, :write)  # after 10 requests

# Apply penalty multiplier (divides max_requests)
RateLimiter.apply_multiplier(circuit_id, 3, expires_at)
```

### Tor Circuit Extraction

```elixir
alias Seer.Circuit.Extractor

# Extract hashed circuit ID from Plug.Conn
{:ok, circuit_hash} = Extractor.extract(conn)

# Strategies (in order):
# 1. X-Tor-Circuit header (localhost only, prevents spoofing)
# 2. Peer address fallback (ip:port)
```

### Escalation

```elixir
alias Seer.Escalation

# Record abuse — applies exponentially increasing penalties
Escalation.record(circuit_id)   # 3x rate limit
Escalation.record(circuit_id)   # 9x
Escalation.record(circuit_id)   # 27x
Escalation.record(circuit_id)   # 81x (capped)

Escalation.status(circuit_id)   # {:escalated, 81}
Escalation.banned?(circuit_id)  # true

# Reset (admin action)
Escalation.reset(circuit_id)
```

## Architecture

- **Hashcash PoW** — SHA256(nonce + solution) with leading zero bit check, constant-time verification
- **Sliding window** — two-bucket rate limiting with fractional previous bucket interpolation
- **EMA scaling** — difficulty adjusts based on exponential moving average of request throughput
- **Anti-oscillation** — difficulty drops at most 2 bits per tick to prevent flapping
- **Privacy-first** — escalation state is ETS-only, no disk persistence, no circuit IDs logged
- **Tor-aware** — circuit extraction trusted only from localhost (SOCKS header spoofing prevention)

## Development

### Pre-commit Hook

```bash
git config core.hooksPath hooks
```

### Testing

```bash
# Run all tests
mix test

# Unit tests (pure functions)
mix test test/unit/

# Integration tests (stateful GenServers)
mix test test/integration/

# Check code style
mix credo --strict

# Type checking
mix dialyzer
```

## Dependencies

```elixir
defp deps do
  [
    {:plug, "~> 1.16"},
    {:jason, "~> 1.4"}
  ]
end
```

## License

MIT
