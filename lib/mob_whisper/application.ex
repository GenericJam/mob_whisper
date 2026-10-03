defmodule MobWhisper.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: MobWhisper.TaskSupervisor},
      MobWhisper.Server
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MobWhisper.Supervisor)
  end
end
