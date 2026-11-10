Code.require_file("support/download_server.exs", __DIR__)
Code.require_file("support/files_server.exs", __DIR__)
Code.require_file("support/forgejo_server.exs", __DIR__)

# A job's git credential reaches git through these variables
# (PipeMaestroRunner.GitCredential); the tests set them per job, never from
# the shell that runs the suite (an agent of a runner, for one).
Enum.each(~w(GIT_CONFIG_PARAMETERS PIPEMAESTRO_GIT_CREDENTIAL_FILE), &System.delete_env/1)

# The agent CLI's sessions (PipeMaestroRunner.ClaudeSessions) live under
# $CLAUDE_CONFIG_DIR: the suite points it to a directory of its own, so no test
# ever reads or deletes the developer's ~/.claude.
claude_config =
  Path.join(
    System.tmp_dir!(),
    "pipemaestro-runner-test-claude-#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(claude_config)
System.put_env("CLAUDE_CONFIG_DIR", claude_config)
System.delete_env("CLAUDE_CODE_PROJECT_DIR_NAME")

ExUnit.start()
