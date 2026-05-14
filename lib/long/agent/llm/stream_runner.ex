defmodule Long.Agent.LLM.StreamRunner do
  @moduledoc """
  Bridges a streaming `Req` HTTP POST into a `Stream`. The HTTP call runs in a
  Task; raw chunks are forwarded to the calling process via messages, then
  parsed by a caller-supplied `parser_fn` into tagged events.

  `parser_fn` shape:

      parser_fn(buffer :: binary, state) :: {events :: [event], new_state, leftover_buffer}

  The stream terminates after a `{:done, _}` event is emitted, or when the
  underlying Task signals completion.
  """

  require Logger

  @recv_timeout 120_000

  def stream(req_opts, init_state, parser_fn, opts \\ []) do
    receive_timeout = opts[:receive_timeout] || @recv_timeout

    Stream.resource(
      fn -> start_stream(req_opts, init_state) end,
      fn s -> read_step(s, parser_fn, receive_timeout) end,
      fn s -> Task.shutdown(s.task, :brutal_kill) end
    )
  end

  defp start_stream(req_opts, init_state) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        try do
          run_request(req_opts, parent, ref)
        rescue
          e ->
            send(parent, {ref, :error, e})
            :ok
        catch
          kind, reason ->
            send(parent, {ref, :error, {kind, reason}})
            :ok
        end
      end)

    %{state: init_state, buffer: "", ref: ref, task: task, halted?: false}
  end

  defp run_request(req_opts, parent, ref) do
    into_fn = fn
      {:data, chunk}, acc ->
        send(parent, {ref, :chunk, chunk})
        {:cont, acc}

      :done, acc ->
        send(parent, {ref, :http_done})
        {:cont, acc}
    end

    case Req.request(Keyword.put(req_opts, :into, into_fn)) do
      {:ok, %Req.Response{status: status}} when status >= 400 ->
        send(parent, {ref, :http_error, {:status, status}})

      {:ok, _resp} ->
        send(parent, {ref, :http_done})

      {:error, exception} ->
        send(parent, {ref, :error, exception})
    end
  end

  defp read_step(%{halted?: true} = s, _parser, _timeout), do: {:halt, s}

  defp read_step(s, parser, timeout) do
    receive do
      {ref, :chunk, chunk} when ref == s.ref ->
        {events, new_state, leftover} = parser.(s.buffer <> chunk, s.state)

        halted? =
          Enum.any?(events, &match?({:done, _}, &1)) or
            Enum.any?(events, &match?({:error, _}, &1))

        {events, %{s | state: new_state, buffer: leftover, halted?: halted?}}

      {ref, :http_done} when ref == s.ref ->
        # flush any final events from accumulated state
        {events, _, _} = parser.(s.buffer, s.state)

        events =
          if Enum.any?(events, &match?({:done, _}, &1)) do
            events
          else
            events ++ [{:done, default_done(s.state)}]
          end

        {events, %{s | halted?: true}}

      {ref, :http_error, info} when ref == s.ref ->
        {[{:error, info}], %{s | halted?: true}}

      {ref, :error, e} when ref == s.ref ->
        {[{:error, e}], %{s | halted?: true}}
    after
      timeout ->
        {[{:error, :receive_timeout}], %{s | halted?: true}}
    end
  end

  defp default_done(%{blocks: blocks} = state) when is_list(blocks),
    do: Long.Agent.LLM.Response.from_blocks(blocks, Map.get(state, :response_opts, []))

  defp default_done(_), do: %Long.Agent.LLM.Response{}
end
