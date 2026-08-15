defmodule HexEmpire.PushSenderStub do
  @moduledoc """
  Test double for Web Push sending: forwards every send to the test process
  registered via `Application.put_env(:hex_empire, :push_test_pid, self())`.
  """

  @spec send(map(), String.t()) :: :ok
  def send(sub, payload) do
    if pid = Application.get_env(:hex_empire, :push_test_pid) do
      Kernel.send(pid, {:push_sent, sub, Jason.decode!(payload)})
    end

    :ok
  end
end
