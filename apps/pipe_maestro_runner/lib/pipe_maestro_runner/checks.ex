defmodule PipeMaestroRunner.Checks do
  @moduledoc """
  The platform's checks of a task's worktree after the agent
  (`PipeMaestroProtocol.Job` `checks`), run before the gates.

  They verify what the delivery relies on, whatever the agent did, without
  changing anything: the runner never fixes the worktree itself. A check that
  fails says why in a `"message"` written for the agent, who gets it as the
  feedback of its next attempt. Each result has the shape of a gate's
  (`PipeMaestroRunner.Gates`), plus `"platform" => true`, `"id"` and
  `"message"`.

  - `"branch"` — HEAD is on the task's branch (`"branch"`).
  - `"no_operation"` — no merge, rebase, cherry-pick or revert under way, and
    no file with unresolved conflicts.
  - `"contains_origin"` — the branch holds what origin has of it (`"branch"`),
    so the push is a fast-forward.
  - `"clean"` — nothing left uncommitted, but the paths the setup copied
    (`:exclude`) and the task's artifacts folder (`"artifacts"`).
  - `"artifact_committed"` — the stage's artifact (`"path"`) is committed as
    it is on disk, so the pull request shows it and another agent can go on.
  - `"no_artifacts"` — the task's artifacts folder (`"path"`) is no longer in
    HEAD: the last stage takes it out of the branch.
  - `"no_secrets"` — no value of the job's secrets (`:env`) in what the
    branch adds since the default branch, nor in uncommitted files. A message
    names the secret and the file, never the value.
  """

  alias PipeMaestroRunner.{Changes, RepoState}

  @min_secret_bytes 8
  @listed 20

  @doc """
  Runs `checks` in the worktree `dir`. Options: `:env` (the job's secrets)
  and `:exclude` (the paths the setup copied).
  """
  @spec run(Path.t(), [map()], keyword()) :: [map()]
  def run(dir, checks, opts \\ []) do
    Enum.map(checks, fn %{"id" => id} = check ->
      started = System.monotonic_time(:millisecond)
      message = check(id, dir, check, opts)

      %{
        "id" => id,
        "platform" => true,
        "command" => label(id),
        "expect" => "pass",
        "exit_code" => if(message, do: 1, else: 0),
        "output" => message || "",
        "message" => message,
        "passed" => is_nil(message),
        "duration_ms" => System.monotonic_time(:millisecond) - started
      }
    end)
  end

  @doc "What check `id` verifies, in a few words."
  @spec label(String.t()) :: String.t()
  def label("branch"), do: "plataforma: o trabalho está na branch da tarefa"
  def label("no_operation"), do: "plataforma: nenhum merge, rebase ou conflito pela metade"
  def label("contains_origin"), do: "plataforma: a branch contém o que está no origin"
  def label("clean"), do: "plataforma: nada ficou sem commit"
  def label("artifact_committed"), do: "plataforma: o artefato da etapa está commitado"
  def label("no_artifacts"), do: "plataforma: os artefatos saíram da branch"
  def label("no_secrets"), do: "plataforma: nenhum segredo nas mudanças"

  # Each check: nil when it holds, the message for the agent otherwise.
  defp check("branch", dir, %{"branch" => branch}, _opts) do
    case RepoState.current_branch(dir) do
      ^branch ->
        nil

      nil ->
        "O HEAD está solto (detached), não na branch da tarefa `#{branch}`. Leve os commits desta etapa para `#{branch}` e termine nela."

      other ->
        "O HEAD está na branch `#{other}`, não na da tarefa, `#{branch}`. Leve o trabalho para `#{branch}` e termine nela."
    end
  end

  defp check("no_operation", dir, _check, _opts) do
    case {RepoState.operation(dir), RepoState.conflicted(dir)} do
      {nil, []} ->
        nil

      {operation, files} ->
        [
          operation && "Ficou #{operation} em andamento.",
          files != [] && "Arquivos com conflito não resolvido: #{list(files)}.",
          "Conclua ou aborte a operação e resolva os conflitos antes de terminar."
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
    end
  end

  defp check("contains_origin", dir, %{"branch" => branch}, _opts) do
    RepoState.fetch(dir, branch)

    case RepoState.state(dir, branch) do
      %{remote: false} ->
        nil

      %{behind: 0} ->
        nil

      %{behind: behind} ->
        "A branch não contém #{behind} commit(s) que estão no origin em `#{branch}` (veja `git log HEAD..origin/#{branch}`). Integre-os com merge, sem reescrever o que já está no origin."
    end
  end

  defp check("clean", dir, check, opts) do
    exclude = Keyword.get(opts, :exclude, []) ++ List.wrap(check["artifacts"])
    pathspec = Changes.pathspec(dir, exclude)

    case git(dir, ["status", "--porcelain", "--untracked-files=all" | pathspec]) do
      {:ok, ""} ->
        nil

      {:ok, out} ->
        files = out |> String.split("\n", trim: true) |> Enum.map(&String.slice(&1, 3..-1//1))

        "Ficaram mudanças sem commit: #{list(files)}. Faça commit do que é trabalho da tarefa; apague, ou ponha no .gitignore, o que não é."

      {:error, output} ->
        "Não foi possível ler o estado do worktree: #{output}"
    end
  end

  defp check("artifact_committed", dir, %{"path" => path}, _opts) do
    tracked? = match?({:ok, out} when out != "", git(dir, ["ls-files", "--", path]))
    unchanged? = match?({:ok, _}, git(dir, ["diff", "--quiet", "HEAD", "--", path]))

    if not File.exists?(Path.join(dir, path)) or (tracked? and unchanged?),
      do: nil,
      else:
        "O artefato desta etapa (`#{path}`) não está commitado como está no disco. Faça commit dele: é por ele que o PR mostra o andamento e outro agente pode continuar."
  end

  defp check("no_artifacts", dir, %{"path" => path}, _opts) do
    case git(dir, ["ls-tree", "-r", "--name-only", "HEAD", "--", path]) do
      {:ok, ""} ->
        nil

      {:ok, _files} ->
        "Os artefatos da tarefa (`#{path}`) ainda estão na branch. Esta é a última etapa: tire-os da branch sem apagar do disco (`git rm -r --cached #{path}`) e faça commit. Eles ficam guardados na plataforma."

      {:error, _no_head} ->
        nil
    end
  end

  defp check("no_secrets", dir, _check, opts) do
    secrets =
      for {name, value} <- Keyword.get(opts, :env, []),
          is_binary(value) and byte_size(value) >= @min_secret_bytes,
          do: {name, value}

    found =
      for {file, text} <- added_text(dir),
          {name, value} <- secrets,
          String.contains?(text, value),
          do: "`#{name}` em `#{file}`"

    if found == [],
      do: nil,
      else:
        "Há segredos do workspace nas mudanças: #{Enum.join(Enum.uniq(found), ", ")}. Tire-os dos arquivos e dos commits desta tarefa que ainda não estão no origin; a plataforma não envia um segredo."
  end

  # What the branch adds since the default branch, plus what is not committed
  # yet, per file: only added lines and untracked files' contents.
  defp added_text(dir) do
    base =
      with {:ok, ref} <- git(dir, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]),
           {:ok, sha} <- git(dir, ["merge-base", "HEAD", String.trim(ref)]) do
        String.trim(sha)
      else
        _no_default -> nil
      end

    committed = if base, do: diff_added(dir, [base, "HEAD"]), else: []
    uncommitted = diff_added(dir, ["HEAD"])

    untracked =
      case git(dir, ["ls-files", "--others", "--exclude-standard"]) do
        {:ok, out} ->
          for file <- String.split(out, "\n", trim: true),
              {:ok, text} <- [File.read(Path.join(dir, file))],
              do: {file, text}

        {:error, _} ->
          []
      end

    committed ++ uncommitted ++ untracked
  end

  defp diff_added(dir, refs) do
    case git(dir, ["diff", "--no-color", "--no-ext-diff", "-U0" | refs]) do
      {:ok, out} -> out |> String.split(~r/^diff --git /m, trim: true) |> Enum.map(&added_lines/1)
      {:error, _} -> []
    end
  end

  # One file's part of a diff: its path and the lines it adds.
  defp added_lines(chunk) do
    [header | lines] = String.split(chunk, "\n")
    file = header |> String.split(" b/", parts: 2) |> List.last()
    added = for "+" <> line <- lines, not String.starts_with?(line, "++"), do: line
    {file, Enum.join(added, "\n")}
  end

  defp list(files) do
    shown = files |> Enum.take(@listed) |> Enum.map_join(", ", &"`#{&1}`")
    if length(files) > @listed, do: shown <> " e mais #{length(files) - @listed}", else: shown
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
