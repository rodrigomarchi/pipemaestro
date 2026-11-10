defmodule PipeMaestroRunner.ClaudeSessions do
  @moduledoc """
  The agent CLI's sessions of a task, on the runner's machine (ADR 0053).

  The `claude` CLI keeps what a run leaves behind in a directory of its own
  per working directory: `<root>/<name>`, where `root` is
  `$CLAUDE_CONFIG_DIR/projects` (or `~/.claude/projects`, `projects_root/1`)
  and `name` comes from the run's cwd (`dir_name/1`). A task's stages run in
  its worktree (`<workdir>/worktrees/<task_id>`, `PipeMaestroRunner.Workspace`),
  so a task's sessions have a directory apart from every other task's. They
  go with the worktree (`remove/3`, from `PipeMaestroRunner.JobRunner`) and
  count in the space the worktrees take (`PipeMaestroRunner.Disk`).

  ## The CLI's layout (read in `claude` 2.1.319)

    * `name` is the cwd's real path (symlinks resolved, Unicode NFC) with
      every UTF-16 unit outside `[A-Za-z0-9]` turned into `-`. A name over
      200 characters keeps the first 200, plus `-` and the base-36 absolute
      value of the path's 32-bit Java-style string hash.
    * With `CLAUDE_CONFIG_DIR` set, `CLAUDE_CODE_PROJECT_DIR_NAME` replaces
      `name` for every cwd: the directory is then shared, and nothing in it
      is removed (`project_dir_override?/1`).
    * The directory holds `<session_id>.jsonl` (the transcript, each line
      with the `cwd` of the agent's shell at the time, the worktree or under
      it) and `<session_id>/` (tool results, subagents' transcripts), even
      for runs with `--no-session-persistence`. It may hold other things
      too, such as the CLI's `memory/`, which stay.

  ## What goes

  Only the entries of the directory with the exact name of the worktree's
  cwd, named after a session id: `<uuid>.jsonl` files and `<uuid>/`
  directories (never through a link). Before any of them goes, every
  `cwd` in their transcripts (`<uuid>.jsonl` and `<uuid>/subagents/*.jsonl`)
  must be the worktree or under it: two cwds that make the same name are
  told apart there. The directory itself goes only when left empty.

  ## When the CLI's sessions are not where they should be

  A task whose jobs kept a session (`persist_session` or
  `resume_session_id`) is marked (`mark/2`). When such a task's worktree
  goes and its directory is missing, has no transcript, or is shared by a
  fixed name, `clean/4` says so (the CLI's layout changed, or a job set its
  own `CLAUDE_CONFIG_DIR`); the runner logs it as the
  `claude_sessions_not_found` event. A transcript of another cwd is told
  for any task. A task never marked tells nothing.
  """

  @type env :: %{optional(String.t()) => String.t()}
  @type reason :: :not_found | :no_transcript | :cwd_mismatch | :shared_project_dir

  @name_limit 200
  @max_links 40
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @fixed_name ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @marker_suffix ".claude-sessions"

  @doc """
  Where the CLI keeps the directories of its sessions, given the
  environment it runs with: `$CLAUDE_CONFIG_DIR/projects`, or
  `~/.claude/projects` when it is unset or empty.
  """
  @spec projects_root(env()) :: Path.t()
  def projects_root(env \\ System.get_env()) do
    config =
      case Map.get(env, "CLAUDE_CONFIG_DIR") do
        dir when dir in [nil, ""] -> Path.join(System.user_home!(), ".claude")
        dir -> dir
      end

    config |> Path.join("projects") |> nfc()
  end

  @doc """
  Whether the CLI puts every cwd's sessions in one fixed directory
  (`CLAUDE_CODE_PROJECT_DIR_NAME`, honored only with `CLAUDE_CONFIG_DIR`).
  """
  @spec project_dir_override?(env()) :: boolean()
  def project_dir_override?(env) do
    Map.get(env, "CLAUDE_CONFIG_DIR") not in [nil, ""] and
      is_binary(env["CLAUDE_CODE_PROJECT_DIR_NAME"]) and
      Regex.match?(@fixed_name, env["CLAUDE_CODE_PROJECT_DIR_NAME"])
  end

  @doc "The name of the CLI's directory for `cwd`, a real path."
  @spec dir_name(Path.t()) :: String.t()
  def dir_name(cwd) do
    units = utf16_units(cwd)
    name = for unit <- units, into: "", do: if(alnum?(unit), do: <<unit>>, else: "-")

    if byte_size(name) <= @name_limit,
      do: name,
      else: binary_part(name, 0, @name_limit) <> "-" <> hash36(units)
  end

  @doc "The CLI's directory for `cwd` under `root`."
  @spec project_dir(Path.t(), Path.t()) :: Path.t()
  def project_dir(root, cwd), do: Path.join(root, dir_name(cwd))

  @doc """
  `path`, absolute, with every symlink along it resolved and in Unicode NFC,
  as the CLI sees its cwd. The parts that do not exist stay as they are.
  """
  @spec real_path(Path.t()) :: Path.t()
  def real_path(path), do: path |> Path.expand() |> resolve(0) |> nfc()

  @doc """
  The real path of task `task_id`'s worktree under `workdir`: its parent
  resolved, so it holds with the worktree already gone.
  """
  @spec task_cwd(Path.t(), String.t()) :: Path.t()
  def task_cwd(workdir, task_id),
    do: Path.join(real_path(Path.join(workdir, "worktrees")), task_id)

  @doc "Marks task `task_id` as one whose jobs kept a session."
  @spec mark(Path.t(), String.t()) :: :ok
  def mark(workdir, task_id) do
    path = marker(workdir, task_id)
    File.mkdir_p!(Path.dirname(path))
    File.touch!(path)
  end

  @doc "Whether task `task_id` kept a session (`mark/2`)."
  @spec marked?(Path.t(), String.t()) :: boolean()
  def marked?(workdir, task_id), do: File.regular?(marker(workdir, task_id))

  @doc "Drops task `task_id`'s mark. Dropping one that is not there is fine."
  @spec forget(Path.t(), String.t()) :: :ok
  def forget(workdir, task_id) do
    case File.rm(marker(workdir, task_id)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "remove file", path: marker(workdir, task_id)
    end
  end

  defp marker(workdir, task_id),
    do: Path.join([workdir, "worktrees", task_id <> @marker_suffix])

  @doc "How many bytes `remove/3` would free for `cwd` under `root`."
  @spec bytes(Path.t(), Path.t()) :: non_neg_integer()
  def bytes(root, cwd) do
    root |> project_dir(cwd) |> sessions() |> Enum.map(&size/1) |> Enum.sum()
  end

  @doc "Whether `cwd`'s directory under `root` has a session's transcript."
  @spec transcript?(Path.t(), Path.t()) :: boolean()
  def transcript?(root, cwd) do
    root |> project_dir(cwd) |> sessions() |> Enum.any?(&String.ends_with?(&1, ".jsonl"))
  end

  @doc """
  Removes `cwd`'s sessions under `root` (see the moduledoc for what goes),
  returning the bytes freed. `env` is the CLI's environment, for a fixed
  project directory name.
  """
  @spec remove(Path.t(), Path.t(), env()) :: {:ok, non_neg_integer()} | {:error, reason()}
  def remove(root, cwd, env \\ System.get_env()) do
    dir = project_dir(root, cwd)

    cond do
      project_dir_override?(env) ->
        {:error, :shared_project_dir}

      not File.dir?(dir) ->
        {:error, :not_found}

      true ->
        entries = sessions(dir)

        if Enum.all?(transcripts(entries), &own_transcript?(&1, cwd)) do
          freed = entries |> Enum.map(&size/1) |> Enum.sum()
          Enum.each(entries, &File.rm_rf!/1)
          # Gone only when nothing else (the CLI's memory, say) is left in it.
          _left = File.rmdir(dir)
          {:ok, freed}
        else
          {:error, :cwd_mismatch}
        end
    end
  end

  @doc """
  Removes the sessions of a task's worktree, `cwd`, and tells whether they
  were where they should be: `{:unexpected, reason, bytes}` when not, by the
  rule in the moduledoc (`kept?` is whether the task was marked).
  """
  @spec clean(Path.t(), Path.t(), boolean(), env()) ::
          {:ok, non_neg_integer()} | {:unexpected, reason(), non_neg_integer()}
  def clean(root, cwd, kept?, env \\ System.get_env()) do
    transcript? = transcript?(root, cwd)

    case remove(root, cwd, env) do
      {:ok, bytes} when kept? and not transcript? -> {:unexpected, :no_transcript, bytes}
      {:ok, bytes} -> {:ok, bytes}
      {:error, :cwd_mismatch} -> {:unexpected, :cwd_mismatch, 0}
      {:error, reason} when kept? -> {:unexpected, reason, 0}
      {:error, _reason} -> {:ok, 0}
    end
  end

  # The entries named after a session: `<uuid>.jsonl` files and `<uuid>/`
  # directories, never a link.
  defp sessions(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, path = Path.join(dir, name), session?(name, path), do: path

      {:error, _reason} ->
        []
    end
  end

  defp session?(name, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        uuid?(Path.rootname(name, ".jsonl")) and Path.extname(name) == ".jsonl"

      {:ok, %File.Stat{type: :directory}} ->
        uuid?(name)

      _other ->
        false
    end
  end

  defp uuid?(name), do: Regex.match?(@uuid, name)

  defp transcripts(entries) do
    Enum.flat_map(entries, fn entry ->
      if String.ends_with?(entry, ".jsonl"), do: [entry], else: subagent_transcripts(entry)
    end)
  end

  defp subagent_transcripts(session_dir) do
    dir = Path.join(session_dir, "subagents")

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            String.ends_with?(name, ".jsonl"),
            path = Path.join(dir, name),
            match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)),
            do: path

      {:error, _reason} ->
        []
    end
  end

  defp own_transcript?(path, cwd) do
    path
    |> File.stream!()
    |> Stream.filter(&String.contains?(&1, ~s("cwd")))
    |> Enum.all?(fn line -> own_line?(line, cwd) end)
  end

  defp own_line?(line, cwd) do
    case JSON.decode(line) do
      {:ok, %{"cwd" => line_cwd}} when is_binary(line_cwd) ->
        line_cwd == cwd or String.starts_with?(line_cwd, cwd <> "/")

      {:ok, %{"cwd" => _other}} ->
        false

      # "cwd" only inside some text of the line, not a key of it.
      {:ok, _no_cwd} ->
        true

      {:error, _reason} ->
        false
    end
  end

  defp size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> names |> Enum.map(&size(Path.join(path, &1))) |> Enum.sum()
          {:error, _reason} -> 0
        end

      {:ok, %File.Stat{size: size}} ->
        size

      {:error, _reason} ->
        0
    end
  end

  defp resolve(path, links) do
    [first | parts] = Path.split(path)
    resolve_parts(first, parts, links)
  end

  defp resolve_parts(resolved, [], _links), do: resolved

  defp resolve_parts(resolved, [part | rest], links) do
    candidate = Path.join(resolved, part)

    case :file.read_link_all(candidate) do
      {:ok, target} when links < @max_links ->
        target = target |> IO.chardata_to_string() |> Path.expand(resolved)
        resolve_parts(resolve(target, links + 1), rest, links + 1)

      _not_a_link ->
        resolve_parts(candidate, rest, links)
    end
  end

  defp utf16_units(string) do
    for <<unit::16 <- :unicode.characters_to_binary(string, :utf8, :utf16)>>, do: unit
  end

  defp alnum?(unit), do: unit in ?a..?z or unit in ?A..?Z or unit in ?0..?9

  # JavaScript's `(h << 5) - h + unit | 0` over the UTF-16 units, as a
  # signed 32-bit integer; the CLI prints its absolute value in base 36.
  defp hash36(units) do
    units
    |> Enum.reduce(0, fn unit, hash -> int32(hash * 31 + unit) end)
    |> abs()
    |> Integer.to_string(36)
    |> String.downcase()
  end

  defp int32(value) do
    <<signed::signed-32>> = <<value::32>>
    signed
  end

  defp nfc(path), do: :unicode.characters_to_nfc_binary(path)
end
