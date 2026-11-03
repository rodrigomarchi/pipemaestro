defmodule ClaudeControlPlane.Pipelines.Yaml do
  @moduledoc """
  A pipeline as YAML, to keep in a repository, review or move to another
  workspace. Prompts and other multi-line texts are block literals (`|`),
  so they read as written; single-line texts are double-quoted; MCP servers,
  agents and output schemas are JSON objects (valid YAML). Gates, rules and
  tool rules are lists in the form's one-per-line syntax (`! comando` for a
  gate that must fail, `campo == valor` for a rule).

  `from_yaml/1` reads that back into attributes for
  `ClaudeControlPlane.Pipelines.create_pipeline/2`.
  """

  alias ClaudeControlPlane.Pipelines.{Pipeline, Stage}

  @doc "The pipeline as YAML."
  @spec to_yaml(Pipeline.t()) :: String.t()
  def to_yaml(%Pipeline{} = pipeline) do
    top = [
      {"name", pipeline.name},
      {"description", pipeline.description},
      {"system_prompt", pipeline.system_prompt},
      {"max_task_cost_usd", decimal(pipeline.max_task_cost_usd)},
      {"delivery", if(pipeline.delivery == "none", do: nil, else: pipeline.delivery)},
      {"mcp_config", pipeline.mcp_config},
      {"agents", pipeline.agents}
    ]

    stages = Enum.map_join(pipeline.stages, "", &stage_yaml/1)
    fields(top, 0) <> "stages:\n" <> stages
  end

  defp stage_yaml(%Stage{} = stage) do
    lines =
      fields(
        [
          {"key", stage.key},
          {"name", stage.name},
          {"prompt", stage.prompt},
          {"max_attempts", stage.max_attempts},
          {"pause_after", stage.pause_after},
          {"model", stage.model},
          {"max_budget_usd", decimal(stage.max_budget_usd)},
          {"timeout_minutes", stage.timeout_minutes},
          {"permission_profile", stage.permission_profile},
          {"agent", stage.agent},
          {"group", stage.group},
          {"allowed_tools", stage.allowed_tools},
          {"denied_tools", stage.denied_tools},
          {"gates", lines_of(Stage.gates_text(stage))},
          {"rules", lines_of(Stage.rules_text(stage))},
          {"output_schema", stage.output_schema}
        ],
        4
      )

    # The first field opens the list item.
    "  - " <> String.trim_leading(lines)
  end

  defp lines_of(""), do: []
  defp lines_of(text), do: String.split(text, "\n")

  defp decimal(nil), do: nil
  defp decimal(value), do: Decimal.to_string(value)

  defp fields(pairs, indent) do
    pairs
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Enum.map_join("", fn {key, value} -> field(key, value, indent) end)
  end

  defp field(key, value, indent) do
    pad = String.duplicate(" ", indent)

    cond do
      is_binary(value) and String.contains?(value, "\n") ->
        "#{pad}#{key}: #{block(value, indent + 2)}"

      is_list(value) ->
        "#{pad}#{key}:\n" <> Enum.map_join(value, "", &"#{pad}  - #{Jason.encode!(&1)}\n")

      true ->
        # Strings, numbers, booleans and maps (JSON is YAML).
        "#{pad}#{key}: #{Jason.encode!(value)}\n"
    end
  end

  # A block literal keeps the text as it is: `|` keeps its final newline, `|-`
  # leaves it out; an explicit indentation says where the text begins when
  # its first line starts with spaces.
  defp block(text, indent) do
    chomp = if String.ends_with?(text, "\n"), do: "", else: "-"
    lines = text |> String.trim_trailing("\n") |> String.split("\n")
    indicator = if String.starts_with?(hd(lines), " "), do: "2", else: ""
    pad = String.duplicate(" ", indent)

    body =
      Enum.map_join(lines, "\n", fn
        "" -> ""
        line -> pad <> line
      end)

    "|#{indicator}#{chomp}\n#{body}\n"
  end

  @doc """
  Attributes for a new pipeline from YAML written by `to_yaml/1` (or by hand
  in the same shape).
  """
  @spec from_yaml(String.t()) :: {:ok, map()} | {:error, String.t()}
  def from_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = map} -> {:ok, attrs(map)}
      {:ok, _other} -> {:error, "precisa ser um pipeline: um mapa com name e stages"}
      {:error, error} -> {:error, "YAML inválido: #{Exception.message(error)}"}
    end
  end

  defp attrs(map) do
    map
    |> Map.take(~w(name description system_prompt max_task_cost_usd delivery))
    |> put_json(map, "mcp_config")
    |> put_json(map, "agents")
    |> Map.put("stages", Enum.map(List.wrap(map["stages"]), &stage_attrs/1))
  end

  defp stage_attrs(%{} = stage) do
    stage
    |> Map.take(
      ~w(key name prompt max_attempts pause_after model max_budget_usd timeout_minutes permission_profile agent group)
    )
    |> put_lines(stage, "allowed_tools")
    |> put_lines(stage, "denied_tools")
    |> put_lines(stage, "gates")
    |> put_lines(stage, "rules")
    |> put_json(stage, "output_schema")
  end

  defp stage_attrs(_other), do: %{}

  # Lists go to the form's one-per-line texts, objects to its JSON texts, so
  # the changeset validates them as it does a form's.
  defp put_lines(attrs, source, key) do
    case source[key] do
      lines when is_list(lines) -> Map.put(attrs, key <> "_text", Enum.join(lines, "\n"))
      _absent -> attrs
    end
  end

  defp put_json(attrs, source, key) do
    case source[key] do
      nil -> attrs
      value -> Map.put(attrs, key <> "_json", Jason.encode!(value))
    end
  end
end
