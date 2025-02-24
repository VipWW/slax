defmodule SlaxWeb.ChatRoomLive do
  use SlaxWeb, :live_view

  alias Slax.Accounts
  alias Slax.Accounts.User
  alias Slax.Chat
  alias Slax.Chat.{Message, Room}
  alias SlaxWeb.ChatRoomLive.ThreadComponent
  alias SlaxWeb.OnlineUsers

  import SlaxWeb.ChatComponents
  import SlaxWeb.UserComponents

  attr :active, :boolean, required: true
  attr :room, Room, required: true
  attr :unread_count, :integer, required: true

  defp room_link(assigns) do
    ~H"""
    <.link
      class={[
        "flex items-center h-8 text-sm pl-8 pr-3",
        (@active && "bg-slate-300") || "hover:bg-slate-300"
      ]}
      patch={~p"/rooms/#{@room}"}
    >
      <.icon name="hero-hashtag" class="h-4 w-4" />
      <span class={["ml-2 leading-none", @active && "font-bold"]}>{@room.name}</span>
      <.unread_message_counter count={@unread_count} />
    </.link>
    """
  end

  attr :dom_id, :string, required: true
  attr :text, :string, required: true
  attr :on_click, JS, required: true

  defp toggler(assigns) do
    ~H"""
    <button id={@dom_id} phx-click={@on_click} class="flex items-center grow">
      <.icon id={@dom_id <> "-chevron-down"} name="hero-chevron-down" class="h-4 w-4" />
      <.icon
        id={@dom_id <> "-chevron-right"}
        name="hero-chevron-right"
        class="h-4 w-4"
        style="display:none;"
      />
      <span class="ml-2 leading-none font-medium text-sm">{@text}</span>
    </button>
    """
  end

  defp toggle_rooms() do
    JS.toggle(to: "#rooms-toggler-chevron-down")
    |> JS.toggle(to: "#rooms-toggler-chevron-right")
    |> JS.toggle(to: "#rooms-list")
  end

  defp toggle_users() do
    JS.toggle(to: "#users-toggler-chevron-down")
    |> JS.toggle(to: "#users-toggler-chevron-right")
    |> JS.toggle(to: "#users-list")
  end

  attr :count, :integer, required: true

  defp unread_message_counter(assigns) do
    ~H"""
    <span
      :if={@count > 0}
      class="flex items-center justify-center bg-blue-500 rounded-full font-medium h-5 px-2 ml-auto text-xs text-white"
    >
      {@count}
    </span>
    """
  end

  attr :user, User, required: true
  attr :online, :boolean, default: false

  defp user(assigns) do
    ~H"""
    <.link class="flex items-center h-8 hover:bg-gray-300 text-sm pl-8 pr-3" href="#">
      <div class="flex justify-center w-4">
        <%= if @online do %>
          <span class="w-2 h-2 rounded-full bg-blue-500"></span>
        <% else %>
          <span class="w-2 h-2 rounded-full border-2 border-gray-500"></span>
        <% end %>
      </div>
      <span class="ml-2 leading-none">{@user.username}</span>
    </.link>
    """
  end

  defp format_date(%Date{} = date) do
    today = Date.utc_today()

    case Date.diff(today, date) do
      0 ->
        "Today"

      1 ->
        "Yesterday"

      _ ->
        format_str = "%A, %B %e#{ordinal(date.day)}#{if today.year != date.year, do: " %Y"}"
        Timex.format!(date, format_str, :strftime)
    end
  end

  defp ordinal(day) do
    cond do
      rem(day, 10) == 1 and day != 11 -> "st"
      rem(day, 10) == 2 and day != 12 -> "nd"
      rem(day, 10) == 3 and day != 13 -> "rd"
      true -> "th"
    end
  end

  def mount(_params, _session, socket) do
    rooms = Chat.list_joined_rooms_with_unread_counts(socket.assigns.current_user)
    users = Accounts.list_users()

    # will be nil during initial render as there is no socket connection yet
    timezone = get_connect_params(socket)["timezone"]

    if connected?(socket) do
      OnlineUsers.track(self(), socket.assigns.current_user)
    end

    OnlineUsers.subscribe()

    Accounts.subscribe_to_user_avatars()

    Enum.each(rooms, fn {chat, _} -> Chat.subscribe_to_room(chat) end)

    socket
    |> assign(
      rooms: rooms,
      timezone: timezone,
      users: users,
      online_users: OnlineUsers.list()
    )
    |> stream_configure(:messages,
      dom_id: fn
        %Message{id: id} -> "messages-#{id}"
        :unread_marker -> "messages-unread-marker"
        %Date{} = date -> to_string(date)
      end
    )
    |> ok()
  end

  def handle_params(params, _uri, socket) do
    room =
      case Map.fetch(params, "id") do
        {:ok, id} ->
          Chat.get_room!(id)

        :error ->
          Chat.get_first_room!()
      end

    page = Chat.list_messages_in_room(room)

    last_read_id = Chat.get_last_read_id(room, socket.assigns.current_user)

    Chat.update_last_read_id(room, socket.assigns.current_user)

    socket
    |> assign(
      room: room,
      last_read_id: last_read_id,
      joined?: Chat.joined?(room, socket.assigns.current_user),
      hide_topic?: false,
      page_title: "#" <> room.name
    )
    |> stream(:messages, [], reset: true)
    |> stream_message_page(page)
    |> assign_message_form(Chat.change_message(%Message{}))
    |> push_event("reset_pagination", %{can_load_more: !is_nil(page.metadata.after)})
    |> push_event("scroll_messages_to_bottom", %{})
    |> update(:rooms, fn rooms ->
      room_id = room.id

      Enum.map(rooms, fn
        {%Room{id: ^room_id} = room, _} -> {room, 0}
        other -> other
      end)
    end)
    |> noreply()
  end

  defp stream_message_page(socket, %Paginator.Page{} = page) do
    last_read_id = socket.assigns.last_read_id

    messages =
      page.entries
      |> Enum.reverse()
      |> insert_date_dividers(socket.assigns.timezone)
      |> maybe_insert_unread_marker(last_read_id)
      |> Enum.reverse()

    socket
    |> stream(:messages, messages, at: 0)
    |> assign(:message_cursor, page.metadata.after)
  end

  defp insert_date_dividers(messages, nil), do: messages

  defp insert_date_dividers(messages, timezone) do
    messages
    |> Enum.group_by(fn message ->
      message.inserted_at
      |> DateTime.shift_zone!(timezone)
      |> DateTime.to_date()
    end)
    |> Enum.sort_by(fn {date, _msgs} -> date end, &(Date.compare(&1, &2) != :gt))
    |> Enum.flat_map(fn {date, messages} -> [date | messages] end)
  end

  defp maybe_insert_unread_marker(messages, nil), do: messages

  defp maybe_insert_unread_marker(messages, last_read_id) do
    {read, unread} =
      Enum.split_while(messages, fn
        %Message{} = message -> message.id <= last_read_id
        _ -> true
      end)

    if unread == [] do
      read
    else
      read ++ [:unread_marker | unread]
    end
  end

  defp assign_message_form(socket, changeset) do
    assign(socket, :new_message_form, to_form(changeset))
  end

  def handle_event("show-profile", %{"user-id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)
    {:noreply, assign(socket, profile: user, thread: nil)}
  end

  def handle_event("close-profile", _, socket) do
    {:noreply, assign(socket, :profile, nil)}
  end

  def handle_event("close-thread", _, socket) do
    {:noreply, assign(socket, :thread, nil)}
  end

  def handle_event("show-thread", %{"id" => message_id}, socket) do
    message = Chat.get_message!(message_id)

    socket |> assign(profile: nil, thread: message) |> noreply()
  end

  def handle_event("toggle-topic", _params, socket) do
    {:noreply, socket |> update(:hide_topic?, &(!&1))}
  end

  def handle_event("validate-message", %{"message" => message_params}, socket) do
    changeset = Chat.change_message(%Message{}, message_params)

    {:noreply, assign_message_form(socket, changeset)}
  end

  def handle_event("submit-message", %{"message" => message_params}, socket) do
    %{current_user: current_user, room: room} = socket.assigns

    socket =
      if Chat.joined?(room, current_user) do
        case Chat.create_message(room, message_params, current_user) do
          {:ok, _message} ->
            assign_message_form(socket, Chat.change_message(%Message{}))

          {:error, changeset} ->
            assign_message_form(socket, changeset)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("delete-message", %{"id" => id, "type" => "Message"}, socket) do
    Chat.delete_message_by_id(id, socket.assigns.current_user)

    {:noreply, socket}
  end

  def handle_event("delete-message", %{"id" => id, "type" => "Reply"}, socket) do
    Chat.delete_reply_by_id(id, socket.assigns.current_user)

    {:noreply, socket}
  end

  def handle_event("add-reaction", %{"emoji" => emoji, "message_id" => message_id}, socket) do
    message = Chat.get_message!(message_id)

    Chat.add_reaction(emoji, message, socket.assigns.current_user)

    {:noreply, socket}
  end

  def handle_event("remove-reaction", %{"message_id" => message, "emoji" => emoji}, socket) do
    message = Chat.get_message!(message)

    Chat.remove_reaction(emoji, message, socket.assigns.current_user)

    {:noreply, socket}
  end

  def handle_event("join-room", _, socket) do
    current_user = socket.assigns.current_user
    Chat.join_room!(socket.assigns.room, current_user)
    Chat.subscribe_to_room(socket.assigns.room)

    socket =
      assign(socket,
        joined?: true,
        rooms: Chat.list_joined_rooms_with_unread_counts(current_user)
      )

    {:noreply, socket}
  end

  def handle_event("load-more-messages", _, socket) do
    page =
      Chat.list_messages_in_room(
        socket.assigns.room,
        after: socket.assigns.message_cursor
      )

    socket
    |> stream_message_page(page)
    |> reply(%{can_load_more: !is_nil(page.metadata.after)})
  end

  def handle_info({:added_reaction, reaction}, socket) do
    message = Chat.get_message!(reaction.message_id)

    socket
    |> refresh_message(message)
    |> noreply()
  end

  def handle_info({:removed_reaction, reaction}, socket) do
    message = Chat.get_message!(reaction.message_id)

    socket
    |> refresh_message(message)
    |> noreply()
  end

  def handle_info({:new_message, message}, socket) do
    room = socket.assigns.room

    socket =
      cond do
        message.room_id == room.id ->
          Chat.update_last_read_id(room, socket.assigns.current_user)

          socket
          |> stream_insert(:messages, message)
          |> push_event("scroll_messages_to_bottom", %{})

        message.user_id != socket.assigns.current_user.id ->
          update(socket, :rooms, fn rooms ->
            Enum.map(rooms, fn
              {%Room{id: id} = room, count} when id == message.room_id -> {room, count + 1}
              other -> other
            end)
          end)

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:message_deleted, message}, socket) do
    {:noreply, stream_delete(socket, :messages, message)}
  end

  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    online_users = OnlineUsers.update(socket.assigns.online_users, diff)

    {:noreply, assign(socket, online_users: online_users)}
  end

  def handle_info({:updated_avatar, user}, socket) do
    socket
    |> maybe_update_profile(user)
    |> maybe_update_current_user(user)
    |> push_event("update_avatar", %{user_id: user.id, avatar_path: user.avatar_path})
    |> noreply()
  end

  def handle_info({:deleted_reply, message}, socket) do
    socket
    |> refresh_message(message)
    |> noreply()
  end

  def handle_info({:new_reply, message}, socket) do
    if socket.assigns[:thread] && socket.assigns.thread.id == message.id do
      push_event(socket, "scroll_thread_to_bottom", %{})
    else
      socket
    end
    |> refresh_message(message)
    |> noreply()
  end

  defp refresh_message(socket, message) do
    if message.room_id == socket.assigns.room.id do
      socket = stream_insert(socket, :messages, message)

      if socket.assigns[:thread] && socket.assigns.thread.id == message.id do
        assign(socket, :thread, message)
      else
        socket
      end
    else
      socket
    end
  end

  defp maybe_update_profile(socket, user) do
    if socket.assigns[:profile] && socket.assigns.profile.id == user.id do
      assign(socket, :profile, user)
    else
      socket
    end
  end

  defp maybe_update_current_user(socket, user) do
    if socket.assigns.current_user.id == user.id do
      assign(socket, :current_user, user)
    else
      socket
    end
  end
end
