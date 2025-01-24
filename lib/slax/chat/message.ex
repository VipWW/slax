defmodule Slax.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias Slax.Accounts.User
  alias Slax.Chat.Room

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field :body, :string

    # By default assumes at the end: , foreign_key: :user_id
    belongs_to :user, User
    # By default assumes at the end: , foreign_key: :room_id
    belongs_to :room, Room

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> validate_required([:body])
  end
end
