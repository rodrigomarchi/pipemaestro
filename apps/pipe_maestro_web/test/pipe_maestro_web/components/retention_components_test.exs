defmodule PipeMaestroWeb.RetentionComponentsTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroWeb.RetentionComponents

  @mib 1_048_576

  test "format_mib/1 writes MiB as Brazilians write numbers" do
    assert RetentionComponents.format_mib(0) == "0 MiB"
    assert RetentionComponents.format_mib(1024) == "< 0,1 MiB"
    assert RetentionComponents.format_mib(600 * 1024) == "0,6 MiB"
    assert RetentionComponents.format_mib(@mib) == "1 MiB"
    assert RetentionComponents.format_mib(round(2.5 * @mib)) == "2,5 MiB"
    assert RetentionComponents.format_mib(312 * @mib + 1) == "312 MiB"
    assert RetentionComponents.format_mib(1024 * @mib) == "1.024 MiB"
    assert RetentionComponents.format_mib(1_048_576 * @mib) == "1.048.576 MiB"
  end

  test "usage_label/1: against the quota, or without one" do
    assert RetentionComponents.usage_label(%{bytes: 312 * @mib, quota_bytes: 1024 * @mib}) ==
             "312 MiB de 1.024 MiB"

    assert RetentionComponents.usage_label(%{bytes: 312 * @mib, quota_bytes: nil}) ==
             "312 MiB, sem cota"
  end

  test "the policies, in words" do
    default = %Workspace{}
    assert RetentionComponents.files_policy(default) == "conteúdo guardado sem limite de dias"

    assert RetentionComponents.events_policy(default) ==
             "completos por 30 dias após o fim do job; depois, só os metadados"

    custom = %Workspace{
      job_files_retention_days: 1,
      agent_events_retention_days: 7,
      agent_events_after_retention: :delete
    }

    assert RetentionComponents.files_policy(custom) ==
             "conteúdo guardado por 1 dia, depois só o nome"

    assert RetentionComponents.events_policy(custom) ==
             "completos por 7 dias após o fim do job; depois, apagados"
  end
end
