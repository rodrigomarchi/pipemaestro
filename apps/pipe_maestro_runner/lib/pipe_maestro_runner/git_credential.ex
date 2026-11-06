defmodule PipeMaestroRunner.GitCredential do
  @moduledoc """
  The git credential a job brings from the control plane (ADR 0035), handed
  to git through a credential helper, never in a remote's URL.

  It is written to `<workdir>/credentials/<job_id>` (the directory `0700`,
  the file `0600`) in the form `git credential` answers, and every git the
  job runs (the runner's own and the agent's) is told, by `GIT_CONFIG_*`
  variables (`env/2`), to read it for the host. A renewed credential
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
  https, and http for a local host).
  """
  @spec env(Path.t(), String.t()) :: %{String.t() => String.t()}
  def env(path, host) do
    %{
      @file_env => path,
      "GIT_CONFIG_COUNT" => "2",
      "GIT_CONFIG_KEY_0" => "credential.https://#{host}.helper",
      "GIT_CONFIG_VALUE_0" => @helper,
      "GIT_CONFIG_KEY_1" => "credential.http://#{host}.helper",
      "GIT_CONFIG_VALUE_1" => @helper
    }
  end

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

  @doc "Of the job's variables, those git needs for the credential, as `System.cmd/3` takes them."
  @spec git_env(Job.t() | map() | nil) :: [{String.t(), String.t()}]
  def git_env(%Job{env: env}), do: git_env(env)
  def git_env(nil), do: []

  def git_env(env) when is_map(env) do
    for {name, value} <- env,
        name == @file_env or String.starts_with?(name, "GIT_CONFIG_"),
        do: {name, value}
  end
end
