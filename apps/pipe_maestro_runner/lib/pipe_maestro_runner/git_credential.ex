defmodule PipeMaestroRunner.GitCredential do
  @moduledoc """
  The git credential a job brings from the control plane (ADR 0037), handed
  to git through a credential helper, never in a remote's URL.

  It is written to `<workdir>/credentials/<job_id>` (the directory `0700`,
  the file `0600`) in the form `git credential` answers, and every git the
  job runs (the runner's own and the agent's) is told, by
  `GIT_CONFIG_PARAMETERS` (`env/2`), to read it for the host. A renewed credential
  (`"job:credential"`) rewrites the file atomically; the file goes when the
  job ends, and whatever is left goes when the runner starts.
  """

  alias PipeMaestroProtocol.Job

  @file_env "PIPEMAESTRO_GIT_CREDENTIAL_FILE"
  @helper ~S|!f() { test "$1" = get && cat "$PIPEMAESTRO_GIT_CREDENTIAL_FILE"; }; f|

  @doc "Where the credential of job `job_id` is kept."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(workdir, job_id), do: Path.join([workdir, "credentials", job_id])

  @doc "Writes (or rewrites) the credential of job `job_id`; answers its path."
  @spec write(Path.t(), String.t(), map()) :: Path.t()
  def write(workdir, job_id, %{"username" => username, "password" => password}) do
    dir = Path.join(workdir, "credentials")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = path(workdir, job_id)
    tmp = path <> ".tmp"
    File.write!(tmp, "username=#{username}\npassword=#{password}\n")
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    path
  end

  @doc "Removes the credential of job `job_id`, if any."
  @spec remove(Path.t(), String.t()) :: :ok
  def remove(workdir, job_id) do
    _ = File.rm(path(workdir, job_id))
    :ok
  end

  @doc "Removes every credential left behind (a runner that stopped mid-job)."
  @spec clear(Path.t()) :: :ok
  def clear(workdir) do
    _ = File.rm_rf(Path.join(workdir, "credentials"))
    :ok
  end

  @doc """
  The variables that make git read the credential at `path` for `host` (over
  https, and http for a local host). For each, an empty helper comes first:
  it clears the helpers of the machine's own configuration, so a keychain or
  `store` helper is neither asked nor told the job's token. They go in
  `GIT_CONFIG_PARAMETERS` (what `git -c` passes on): an empty variable, as
  `GIT_CONFIG_VALUE_<n>` would need, does not survive a port's environment.
  """
  @spec env(Path.t(), String.t()) :: %{String.t() => String.t()}
  def env(path, host) do
    parameters =
      for scheme <- ["https", "http"], value <- ["", @helper], into: [] do
        quote_parameter("credential.#{scheme}://#{host}.helper") <> "=" <> quote_parameter(value)
      end

    %{@file_env => path, "GIT_CONFIG_PARAMETERS" => Enum.join(parameters, " ")}
  end

  defp quote_parameter(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  @doc """
  The job ready to run: with a `git_credential`, written under `workdir` and
  its variables merged into the job's `env`.
  """
  @spec prepare(Job.t(), Path.t()) :: Job.t()
  def prepare(%Job{git_credential: %{"host" => host} = credential} = job, workdir) do
    path = write(workdir, job.id, credential)
    %{job | env: Map.merge(job.env || %{}, env(path, host))}
  end

  def prepare(%Job{} = job, _workdir), do: job

  @doc """
  What may not show up in a stage's changes (the `no_secrets` check): the
  workspace's secrets and the password of the job's git credential.
  """
  @spec secrets(Job.t()) :: [{String.t(), String.t()}]
  def secrets(%Job{} = job) do
    credential =
      case job.git_credential do
        %{"password" => password} -> [{"git_credential", password}]
        nil -> []
      end

    Enum.reject(Map.to_list(job.env || %{}), fn {name, _value} -> git_env?(name) end) ++
      credential
  end

  @doc "Of the job's variables, those git needs for the credential, as `System.cmd/3` takes them."
  @spec git_env(Job.t() | map() | nil) :: [{String.t(), String.t()}]
  def git_env(%Job{env: env}), do: git_env(env)
  def git_env(nil), do: []

  def git_env(env) when is_map(env) do
    for {name, value} <- env, git_env?(name), do: {name, value}
  end

  defp git_env?(name), do: name == @file_env or String.starts_with?(name, "GIT_CONFIG_")
end
