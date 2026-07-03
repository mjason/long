defmodule Long.ErrorTrackerIgnorer do
  @moduledoc """
  Keeps transport/network noise out of the `/errors` dashboard — failures that
  aren't application bugs and aren't actionable:

    * **Bandit transport-level exits** — a browser closed the tab mid-response,
      or a slow/gone client dropped the socket. Surfaced as
      `Bandit.TransportError` ("Unrecoverable error: timeout/closed").

    * **Transient outbound network failures on LLM streaming** — a DNS blip or
      connection reset/timeout, surfaced as a `Finch.TransportError` wrapped in
      `ReqLLM.Error.API.Stream`. These self-resolve on retry (`LLMCall` already
      only reports the *final* failure); a genuine, persistent outage shows up
      as the bot not answering, not as an /errors entry to chase.

  API-level LLM errors (rate limits, auth, bad requests) are NOT ignored — only
  the transport layer is.
  """
  @behaviour ErrorTracker.Ignorer

  @impl true
  def ignore?(%ErrorTracker.Error{kind: kind, reason: reason}, _context),
    do: transport_noise?(to_string(kind), to_string(reason))

  def ignore?(_error, _context), do: false

  defp transport_noise?("Elixir.Bandit.TransportError", _reason), do: true
  defp transport_noise?("Elixir.Bandit.HTTPTransport." <> _, _reason), do: true

  # Only the network-transport flavour of a stream failure (nxdomain, closed,
  # reset, timeout) — not HTTP-status/API errors, which lack "TransportError".
  defp transport_noise?("Elixir.ReqLLM.Error.API.Stream", reason),
    do: String.contains?(reason, "TransportError")

  defp transport_noise?(_kind, _reason), do: false
end
