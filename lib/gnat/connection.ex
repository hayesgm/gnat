require Logger

defmodule Gnat.Connection do
  use Connection

  alias Gnat.{Proto, Buffer}
  alias Proto.{Info, Ping, Pong, Msg}

  @defaults [
    host: "localhost",
    port: 4222,
    cluster_id: "test-cluster",
    client_id: "gnat"
  ]
  def start_link(options) do
    options = Keyword.merge(@defaults, options) |> Enum.into(%{})
    Connection.start_link(__MODULE__, Enum.into(options, %{}))
  end

  def init(options) do
    {:ok, socket} = :gen_tcp.connect(
      String.to_char_list(options.host),
      options.port,
      [:binary, active: :once]
    )

    Proto.connect(
      verbose: false,
      pedantic: false,
      lang: "Elixir",
      version: "1.0",
      protocol: 1
    ) |> transmit(socket)

    Proto.ping |> transmit(socket)

    state = %{
      socket: socket,
      buffer: "",
      deliver_to: nil,
      msgs: [],
      req_res: %{},
    } |> Map.merge(options)

    {:connect, nil, state}
  end

  def connect(_info, state) do
    {:ok, state}
  end

  def terminate(_reason, state) do
    Logger.debug "Closing socket"
    :gen_tcp.close(state.socket)
  end

  def handle_info({:tcp, socket, data}, state) do
    %{ buffer: buffer } = state

    {messages, buffer} = Buffer.process(buffer <> data)

    Enum.each messages, fn message ->
      GenServer.cast(self, {:message, message})
    end

    state = %{state | buffer: buffer}

    # Allow the socket to send us the next message
    :inet.setopts(socket, active: :once)

    {:noreply, state}
  end

  def handle_cast({:message, raw_message}, state) do
    Logger.debug "<<- #{raw_message}"
    Proto.parse(raw_message) |> handle_message(state)
  end

  def handle_message(%Info{}, state) do
    {:noreply, state}
  end

  def handle_message(%Ping{}, state) do
    Proto.pong |> transmit(state.socket)
    {:noreply, state}
  end

  def handle_message(%Pong{}, state) do
    {:noreply, state}
  end

  def handle_message(%Msg{} = msg, state) do
    %{req_res: req_res} = state
    %{sid: sid} = msg

    if Map.has_key?(req_res, sid) do
      if waiter = req_res[sid] do
        GenServer.reply(waiter, {:ok, msg})
        req_res = Map.delete(req_res, sid)
        {:noreply, %{state | req_res: req_res}}
      else
        {:noreply, put_in(state, [:req_res, sid], msg)}
      end
    else
      if state.deliver_to do
        send(state.deliver_to, {:nats_msg, msg})
        {:noreply, state}
      else
        {:noreply, %{state | msgs: [msg | state.msgs]}}
      end
    end
  end

  def handle_call({:transmit, raw_message}, _from, state) do
    transmit(raw_message, state.socket)
    {:reply, :ok, state}
  end

  def handle_call({:deliver_to, dst}, _from, state) do
    Enum.each(state.msgs, fn msg -> send(dst, {:nats_msg, msg}) end)
    {:reply, :ok, %{state | deliver_to: dst, msgs: []}}
  end

  def handle_call({:request, sid}, from, state) do
    {:reply, :ok, put_in(state, [:req_res, sid], nil)}
  end

  def handle_call({:response, sid}, from, state) do
    %{req_res: req_res} = state

    if response = req_res[sid] do
      req_res = Map.delete(req_res, sid)
      {:reply, {:ok, response}, %{state | req_res: req_res}}
    else
      {:noreply, put_in(state, [:req_res, sid], from)}
    end
  end

  def handle_call(:next_msg, _from, state) do
    %{msgs: msgs} = state
    msg = List.last(msgs)
    msgs = List.delete_at(msgs, -1)
    {:reply, msg, %{state | msgs: msgs}}
  end

  defp transmit(raw_message, socket) do
    Logger.debug "->> #{raw_message}"
    :gen_tcp.send(socket, "#{raw_message}\r\n")
  end

  defp clear_req_res(state, sid) do
    %{req_res_waiters: waiters, req_res_payloads: payloads} = state
    waiters = Map.delete(waiters, sid)
    payloads = Map.delete(payloads, sid)
    %{state | req_res_waiters: waiters, req_res_payloads: payloads}
  end

end