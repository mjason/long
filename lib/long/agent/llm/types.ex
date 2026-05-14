defmodule Long.Agent.LLM.Content do
  @moduledoc """
  Helpers for the canonical Anthropic-style content block representation.
  All backends produce and consume these blocks; format conversion happens
  inside `Long.Agent.LLM.Format` when sending to OAI-style endpoints.
  """

  @type block :: map()

  def text(s) when is_binary(s), do: %{type: :text, text: s}

  def thinking(s, signature \\ "") when is_binary(s),
    do: %{type: :thinking, thinking: s, signature: signature}

  def tool_use(id, name, input) when is_binary(name) and is_map(input),
    do: %{type: :tool_use, id: id || "", name: name, input: input}

  def tool_result(tool_use_id, content) when is_binary(tool_use_id),
    do: %{type: :tool_result, tool_use_id: tool_use_id, content: content}

  def text_of(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1[:type] == :text or &1["type"] == "text"))
    |> Enum.map_join("\n", &(&1[:text] || &1["text"] || ""))
    |> String.trim()
  end

  def thinking_of(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1[:type] == :thinking or &1["type"] == "thinking"))
    |> Enum.map_join("\n", &(&1[:thinking] || &1["thinking"] || ""))
    |> String.trim()
  end

  def tool_uses_of(blocks) when is_list(blocks) do
    Enum.filter(blocks, &(&1[:type] == :tool_use or &1["type"] == "tool_use"))
  end
end

defmodule Long.Agent.LLM.Tool do
  @moduledoc """
  Wire-format tool definition. Stored in OpenAI shape because that's the
  superset; `Backend.Claude` converts to `{name, description, input_schema}`
  before sending.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }
  defstruct [:name, description: "", input_schema: %{"type" => "object", "properties" => %{}}]

  def to_openai(%__MODULE__{name: n, description: d, input_schema: s}) do
    %{"type" => "function", "function" => %{"name" => n, "description" => d, "parameters" => s}}
  end

  def to_claude(%__MODULE__{name: n, description: d, input_schema: s}) do
    %{"name" => n, "description" => d, "input_schema" => s}
  end
end

defmodule Long.Agent.LLM.Response do
  @moduledoc """
  Final structured response returned via `{:done, %Response{}}` after a stream
  is fully consumed. Mirrors GenericAgent's `MockResponse`.
  """

  @type t :: %__MODULE__{
          content: String.t(),
          thinking: String.t(),
          tool_calls: [%{id: String.t(), name: String.t(), input: map()}],
          blocks: [map()],
          stop_reason: atom(),
          model: String.t() | nil,
          usage: map()
        }

  defstruct content: "",
            thinking: "",
            tool_calls: [],
            blocks: [],
            stop_reason: :end_turn,
            model: nil,
            usage: %{}

  alias Long.Agent.LLM.Content

  def from_blocks(blocks, opts \\ []) do
    tool_uses = Content.tool_uses_of(blocks)

    %__MODULE__{
      content: Content.text_of(blocks),
      thinking: Content.thinking_of(blocks),
      tool_calls:
        Enum.map(tool_uses, fn b ->
          %{
            id: b[:id] || b["id"] || "",
            name: b[:name] || b["name"] || "",
            input: b[:input] || b["input"] || %{}
          }
        end),
      blocks: blocks,
      stop_reason: opts[:stop_reason] || if(tool_uses == [], do: :end_turn, else: :tool_use),
      model: opts[:model],
      usage: opts[:usage] || %{}
    }
  end
end

defmodule Long.Agent.LLM.URL do
  @moduledoc """
  Mirrors `llmcore.auto_make_url/2`.

      iex> Long.Agent.LLM.URL.join("http://host:2001", "chat/completions")
      "http://host:2001/v1/chat/completions"
      iex> Long.Agent.LLM.URL.join("http://host:2001/v1", "chat/completions")
      "http://host:2001/v1/chat/completions"
      iex> Long.Agent.LLM.URL.join("http://host:2001/v1/chat/completions", "chat/completions")
      "http://host:2001/v1/chat/completions"
      iex> Long.Agent.LLM.URL.join("https://api.anthropic.com$", "messages")
      "https://api.anthropic.com"
  """

  def join(base, path) when is_binary(base) and is_binary(path) do
    b = String.trim_trailing(base, "/")
    p = String.trim(path, "/")

    cond do
      String.ends_with?(b, "$") -> b |> String.trim_trailing("$") |> String.trim_trailing("/")
      String.ends_with?(b, p) -> b
      Regex.match?(~r{/v\d+(/|$)}, b) -> b <> "/" <> p
      true -> b <> "/v1/" <> p
    end
  end
end

defmodule Long.Agent.LLM.Temperature do
  @moduledoc "Provider-specific temperature normalization (`llmcore._openai_stream`)."

  def normalize(temperature, model) when is_binary(model) do
    ml = String.downcase(model)

    cond do
      String.contains?(ml, "kimi") or String.contains?(ml, "moonshot") -> 1.0
      String.contains?(ml, "minimax") -> max(0.01, min(temperature, 1.0))
      true -> temperature
    end
  end
end
