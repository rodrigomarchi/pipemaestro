Code.require_file("support/download_server.exs", __DIR__)
Code.require_file("support/files_server.exs", __DIR__)
Code.require_file("support/forgejo_server.exs", __DIR__)

# A job's git credential reaches git through these variables
# (PipeMaestroRunner.GitCredential); the tests set them per job, never from
# the shell that runs the suite (an agent of a runner, for one).
Enum.each(~w(GIT_CONFIG_PARAMETERS PIPEMAESTRO_GIT_CREDENTIAL_FILE), &System.delete_env/1)

ExUnit.start()
